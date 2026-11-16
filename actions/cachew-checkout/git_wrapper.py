# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0

"""Try downstream Git reads once through cachew, falling back to upstream.

Any failed cache read is retried once against upstream. Only failures of the
cache endpoint itself (connection, TLS, 3xx/5xx, stall, deadline) remove the
job's cache rewrite; answers about one repository or ref (401/403/404, missing
ref, `ls-remote --exit-code` finding nothing) keep caching on for later reads.
Reads whose effective URL is not the cache (other hosts, token-in-URL or SSH
remotes, a promisor origin pinned upstream) run unchanged and never affect it.
After a clone or fetch, partial-clone remotes are pinned upstream the same way,
since Git's lazy fetches do not pass through this wrapper.
"""

import math
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent))
from checkout import (  # noqa: E402
    DEFAULT_FETCH_TIMEOUT_SECONDS,
    HARD_DEADLINE_SECONDS,
    MAX_DEADLINE_SECONDS,
    MAX_FETCH_TIMEOUT_SECONDS,
    TLS_OVERRIDES,
    transport_error,
)
from session import pin_promisor_remotes, read_state, remove_cache_keys, remove_managed  # noqa: E402

OPTIONS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
CLONE_OPTIONS_WITH_VALUE = {
    "-o",
    "--origin",
    "-b",
    "--branch",
    "-u",
    "--upload-pack",
    "--reference",
    "--reference-if-able",
    "--separate-git-dir",
    "--depth",
    "--shallow-since",
    "--shallow-exclude",
    "-c",
    "--config",
    "--server-option",
    "-j",
    "--jobs",
    "--filter",
    "--template",
    "--bundle-uri",
    "--ref-format",
    "--revision",
}
READ_OPTIONS_WITH_VALUE = {
    "clone": CLONE_OPTIONS_WITH_VALUE,
    "fetch": {
        "--depth",
        "--deepen",
        "--shallow-since",
        "--shallow-exclude",
        "--upload-pack",
        "--refmap",
        "-o",
        "--server-option",
        "--filter",
        "-j",
        "--jobs",
        "--negotiation-tip",
        "--recurse-submodules-default",
        "--submodule-prefix",
    },
    "ls-remote": {"--upload-pack", "--sort", "-o", "--server-option"},
}
NETWORK_COMMANDS = ("clone", "fetch", "ls-remote", "push", "pull", "submodule", "remote")
# Git itself gives up on an alias loop; this only bounds the lookups.
MAX_ALIAS_DEPTH = 10
SHELL_ALIAS = object()
TERMINATE_GRACE_SECONDS = 10
STDERR_TAIL_BYTES = 65536


def command_index(arguments):
    index = 0
    while index < len(arguments):
        arg = arguments[index]
        if arg in OPTIONS_WITH_VALUE:
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            return index
    return None


def resolve_alias(real_git, arguments, index, environ):
    """Expand Git aliases as Git will, so routing sees the command that really runs
    (`alias.up = fetch`, `alias.pu = push`). Returns the expanded arguments and the
    command's index, or SHELL_ALIAS for a `!` alias, whose commands cannot be known."""

    def output(*args):
        result = subprocess.run(
            [real_git, *arguments[:index], *args], env=environ, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
        return result.stdout.decode(errors="replace") if result.returncode == 0 else None

    commands = None
    for _ in range(MAX_ALIAS_DEPTH):
        word = arguments[index]
        if word in NETWORK_COMMANDS:
            break
        expansion = output("config", "--get", f"alias.{word}")
        if not expansion or not expansion.strip():
            break
        if commands is None:
            # Git ignores an alias that has the name of one of its commands.
            listed = output("--list-cmds=builtins,main,others")
            if listed is None:
                break
            commands = set(listed.split())
        if word in commands:
            break
        expansion = expansion.strip()
        if expansion.startswith("!"):
            return SHELL_ALIAS
        try:
            words = shlex.split(expansion)
        except ValueError:
            break
        if not words:
            break
        arguments = [*arguments[:index], *words, *arguments[index + 1 :]]
        # An alias may itself start with options (`-c key=value fetch`).
        index = command_index(arguments)
        if index is None:
            break
    return arguments, index


class UpstreamView:
    """A private copy of the job's global configuration without the cache rewrite.

    Also used once the session is disabled: until every rewrite is removed
    (a concurrent disable, or a locked file), the recorded keys are still there."""

    def __init__(self, real_git, environ, session, state):
        self.path = None
        self.environ = environ
        if not state.get("managed"):
            return
        descriptor, name = tempfile.mkstemp(dir=session, prefix="upstream-view-", suffix=".config")
        self.path = Path(name)
        with os.fdopen(descriptor, "wb") as target, (session / "global.config").open("rb") as source:
            shutil.copyfileobj(source, target)
        remove_managed(real_git, self.path, state, environ, rewrites_only=True)
        self.environ = dict(environ, GIT_CONFIG_GLOBAL=str(self.path))

    def __enter__(self):
        return self.environ

    def __exit__(self, *_):
        if self.path:
            self.path.unlink(missing_ok=True)


def direct_network_operation(real_git, arguments, index, environ):
    """Avoid Git's internal recursive clone retries and keep pushes upstream."""
    command = arguments[index]
    tail = arguments[index + 1 :]
    # Every remote subcommand that can reach a remote (update, prune, show,
    # add -f, set-head --auto) goes upstream; the local ones are unaffected.
    if command in ("push", "pull", "submodule", "remote"):
        return True
    # A retry could not replay the refspecs the cache attempt consumed from stdin.
    if command == "fetch" and "--stdin" in tail:
        return True
    recursive = [arg for arg in tail if arg.startswith(("--recursive", "--recurse-submodules"))]
    # For clone, --recurse-submodules=<value> is a pathspec, not a boolean:
    # `--recurse-submodules=false` still runs the recursive submodule update
    # (for paths matching "false") and records submodule.active=false. So any
    # spelling makes a clone recursive; only other commands take false/no/0.
    if (command == "clone" and recursive) or any(
        arg.split("=", 1)[-1].lower() not in ("false", "no", "0") for arg in recursive
    ):
        return True
    if any(arg.lower() in ("submodule.recurse=true", "fetch.recursesubmodules=true") for arg in arguments):
        return True
    if command == "fetch" and not any(arg in ("--no-recurse-submodules", "--recurse-submodules=false") for arg in tail):
        # An ordinary fetch may recurse implicitly into initialized submodules.
        # Let upstream handle that operation; the checkout action seeds its
        # requested recursive submodules through cachew with explicit fetches.
        result = subprocess.run(
            [real_git, *arguments[:index], "rev-parse", "--path-format=absolute", "--git-path", "modules"],
            env=environ,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        path = result.stdout.decode(errors="replace").strip()
        if result.returncode or not Path(path).is_absolute() or Path(path).is_dir():
            return True
    return False


def working_directory(arguments, index):
    directory = Path.cwd()
    position = 0
    while position < index:
        if arguments[position] == "-C":
            directory = directory / arguments[position + 1]
            position += 2
        elif arguments[position] in OPTIONS_WITH_VALUE:
            position += 2
        else:
            position += 1
    return directory


def clone_destination(arguments, index):
    """Where `git clone` will create its repository, or None if unknown."""
    positional = []
    bare = False
    position = index + 1
    while position < len(arguments):
        arg = arguments[position]
        if arg == "--":
            positional.extend(arguments[position + 1 :])
            break
        if arg in CLONE_OPTIONS_WITH_VALUE:
            position += 2
            continue
        if arg in ("--bare", "--mirror"):
            bare = True
        if not arg.startswith("-"):
            positional.append(arg)
        position += 1
    if not positional:
        return None
    if len(positional) > 1:
        name = positional[1]
    else:
        name = positional[0].rstrip("/")
        name = name.removesuffix("/.git").removesuffix(".git")
        name = name.replace(":", "/").rsplit("/", 1)[-1]
        if not name:
            return None
        if bare:
            # Git names a bare or mirror clone <humanish>.git.
            name += ".git"
    return working_directory(arguments, index) / name


def option_value(arguments, name):
    """The last value of `name <value>` or `name=<value>` in arguments, or None."""
    value = None
    for position, arg in enumerate(arguments):
        if arg == "--":
            break
        if arg == name and position + 1 < len(arguments):
            value = arguments[position + 1]
        elif arg.startswith(name + "="):
            value = arg[len(name) + 1 :]
    return value


class CloneTarget:
    """Remove what a failed cache clone left behind before the upstream retry:
    its destination and, with `--separate-git-dir` or a separate work tree
    (`--work-tree`, GIT_WORK_TREE), the second directory Git creates."""

    def __init__(self, arguments, index, environ):
        self.path = clone_destination(arguments, index) if arguments[index] == "clone" else None
        self.created = {}
        if not self.path:
            return
        directory = working_directory(arguments, index)
        extra = (
            option_value(arguments[index + 1 :], "--separate-git-dir"),
            option_value(arguments[:index], "--work-tree") or environ.get("GIT_WORK_TREE"),
        )
        for path in (self.path, *(directory / value for value in extra if value)):
            existed = path.exists()
            self.created[path] = (existed, existed and path.is_dir() and not any(path.iterdir()))

    def reset(self):
        for path, (existed, was_empty) in self.created.items():
            if not path.exists() or path.is_symlink():
                continue
            if not existed:
                shutil.rmtree(path, ignore_errors=True)
            elif was_empty:
                for child in path.iterdir():
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child, ignore_errors=True)
                    else:
                        child.unlink(missing_ok=True)


def seconds(environ, name, default, maximum):
    try:
        value = float(environ.get(name, default))
        if not math.isfinite(value) or not 0 < value <= maximum:
            raise ValueError
        return value
    except ValueError:
        return float(default)


def repository_argument(arguments, index):
    """The repository a read names, "" for the default remote, or None if unsure."""
    command = arguments[index]
    tail = arguments[index + 1 :]
    if command == "fetch" and any(arg in ("--all", "--multiple") for arg in tail):
        return None
    with_value = READ_OPTIONS_WITH_VALUE[command]
    position = 0
    while position < len(tail):
        arg = tail[position]
        if arg == "--":
            return tail[position + 1] if position + 1 < len(tail) else None
        if arg in with_value:
            position += 2
        elif arg.startswith("-"):
            position += 1
        else:
            return arg
    return None if command == "clone" else ""


def fetch_remotes(real_git, arguments, index, environ):
    """The remotes a fetch of several reads (--all, --multiple, or a
    remotes.<group> name with more than one member; Git fetches a one-member
    group's name as a remote), or None for a fetch of one repository."""
    tail = arguments[index + 1 :]

    def words(*args):
        result = subprocess.run(
            [real_git, *arguments[:index], *args], env=environ, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
        return result.stdout.decode(errors="replace").split() if result.returncode == 0 else []

    if "--all" in tail:
        return words("remote")
    names, position = [], 0
    while position < len(tail):
        if tail[position] in READ_OPTIONS_WITH_VALUE["fetch"]:
            position += 2
            continue
        if not tail[position].startswith("-"):
            names.append(tail[position])
        position += 1
    if "--multiple" not in tail:
        if not names or len(words("config", "--get-all", f"remotes.{names[0]}")) < 2:
            return None
        names = names[:1]
    return [remote for name in names for remote in words("config", "--get-all", f"remotes.{name}") or [name]]


def reaches_cache(real_git, arguments, index, environ, cache, repository=""):
    """Whether the read's effective URL is the cache. Unknown counts as the cache,
    so only reads that provably go elsewhere skip the cache attempt."""
    repository = repository or repository_argument(arguments, index)
    if repository is None or not cache:
        return True
    result = subprocess.run(
        [real_git, *arguments[:index], "ls-remote", "--get-url", *([repository] if repository else [])],
        env=environ,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode:
        return True
    return result.stdout.decode(errors="replace").strip().startswith(cache.rstrip("/") + "/git/")


def cache_attempt(real_git, arguments, environ, index):
    """Run once through the cache. Returns (exit status, stderr tail)."""
    stall = seconds(environ, "CACHEW_GIT_FETCH_TIMEOUT", DEFAULT_FETCH_TIMEOUT_SECONDS, MAX_FETCH_TIMEOUT_SECONDS)
    deadline = seconds(environ, "CACHEW_HARD_DEADLINE", HARD_DEADLINE_SECONDS, MAX_DEADLINE_SECONDS)

    def terminate(process):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            # Let clone remove its partially created destination before fallback.
            process.wait(timeout=TERMINATE_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()

    command = [
        real_git,
        *arguments[:index],
        "-c",
        "http.followRedirects=false",
        "-c",
        "credential.helper=",
        # Abandon a stalled transfer, never a slow but progressing one.
        "-c",
        "http.lowSpeedLimit=1000",
        "-c",
        f"http.lowSpeedTime={max(1, math.ceil(stall))}",
        *arguments[index:],
    ]
    # transport_error matches Git's English messages.
    cache_env = dict(environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/bin/false", LC_ALL="C", LANGUAGE="")
    for name in TLS_OVERRIDES:
        cache_env.pop(name, None)
    tail = bytearray()

    def relay(stream):
        output = sys.stderr.buffer
        for chunk in iter(lambda: stream.read1(8192), b""):
            output.write(chunk)
            output.flush()
            tail.extend(chunk)
            del tail[:-STDERR_TAIL_BYTES]

    with subprocess.Popen(command, env=cache_env, stderr=subprocess.PIPE, start_new_session=True) as process:
        reader = threading.Thread(target=relay, args=(process.stderr,), daemon=True)
        reader.start()
        try:
            status = process.wait(timeout=deadline)
        except subprocess.TimeoutExpired:
            terminate(process)
            status = 124
        except BaseException:
            if process.poll() is None:
                terminate(process)
            raise
        reader.join(timeout=5)
    return status, bytes(tail)


def run(arguments, environ):
    real_git = environ["CACHEW_REAL_GIT"]
    session = Path(environ["CACHEW_SESSION_DIR"])
    index = command_index(arguments)
    if index is None:
        return subprocess.call([real_git, *arguments], env=environ)
    owned_config = Path(environ.get("GIT_CONFIG_GLOBAL", "")).resolve() == (session / "global.config").resolve()
    if not owned_config:
        return subprocess.call([real_git, *arguments], env=environ)
    try:
        state = read_state(session)
    except (OSError, ValueError):
        # A missing session must not prevent Git from running after the runner empties RUNNER_TEMP.
        return subprocess.call([real_git, *arguments], env=environ)
    command = arguments[index]
    target = CloneTarget(arguments, index, environ)

    def done(result):
        # However the clone or fetch went, later lazy fetches would use the rewrite.
        # Pins only remotes the rewrite still reaches, so it is a no-op without one.
        location = ["-C", str(target.path)] if command == "clone" and target.path else arguments[:index]
        if result == 0 and command in ("clone", "fetch"):
            pin_promisor_remotes(real_git, location, environ, state.get("cache"))
        return result

    if (session / "cache-disabled").exists():
        if state.get("managed"):
            # The disable could not remove every key (the file was locked, or a
            # concurrent disable is midway). Try again: Git's own lazy fetches
            # read the job file, not the upstream view, and would follow a
            # leftover rewrite to the failed cache with no retry.
            state = remove_cache_keys(real_git, session, state, environ)
        with UpstreamView(real_git, environ, session, state) as upstream:
            return done(subprocess.call([real_git, *arguments], env=upstream))
    if not state.get("active"):
        return subprocess.call([real_git, *arguments], env=environ)

    resolved = resolve_alias(real_git, arguments, index, environ)
    if resolved is SHELL_ALIAS:
        # Git runs a shell alias's commands itself, past this wrapper, so they get
        # no cache attempt and no retry: its reads and pushes all go upstream.
        with UpstreamView(real_git, environ, session, state) as upstream:
            return subprocess.call([real_git, *arguments], env=upstream)
    if resolved[1] is None:
        return subprocess.call([real_git, *arguments], env=environ)
    if resolved[0] != arguments:
        # Run the expansion, which is what Git would run: every check below then
        # reads the same command line that executes.
        arguments, index = resolved
        command = arguments[index]
        target = CloneTarget(arguments, index, environ)

    if command in NETWORK_COMMANDS and direct_network_operation(
        real_git, arguments, index, environ
    ):
        with UpstreamView(real_git, environ, session, state) as upstream:
            return done(subprocess.call([real_git, *arguments], env=upstream))
    if command not in ("clone", "fetch", "ls-remote"):
        return subprocess.call([real_git, *arguments], env=environ)
    remotes = fetch_remotes(real_git, arguments, index, environ) if command == "fetch" else None
    if remotes is None and not reaches_cache(real_git, arguments, index, environ, state.get("cache")):
        return subprocess.call([real_git, *arguments], env=environ)
    if remotes is not None and not all(
        reaches_cache(real_git, arguments, index, environ, state.get("cache"), remote) for remote in remotes
    ):
        # One remote's failure could not be told from the cache's, so a fetch that
        # also reads elsewhere goes upstream once, without the cache rewrite.
        with UpstreamView(real_git, environ, session, state) as upstream:
            return done(subprocess.call([real_git, *arguments], env=upstream))
    result, errors = cache_attempt(real_git, arguments, environ, index)
    if result == 0 or result < 0:
        return done(result)
    target.reset()
    if result == 124 or transport_error(errors):
        state = remove_cache_keys(real_git, session, state, environ)
        print("Cachew is unavailable; removed the job's cache rewrite and retrying upstream once.", file=sys.stderr)
    else:
        print("Cachew read did not succeed; retrying this operation upstream once.", file=sys.stderr)
    with UpstreamView(real_git, environ, session, state) as upstream:
        return done(subprocess.call([real_git, *arguments], env=upstream))


def main():
    def stop(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    result = run(sys.argv[1:], dict(os.environ))
    return 128 - result if result < 0 else result


if __name__ == "__main__":
    sys.exit(main())

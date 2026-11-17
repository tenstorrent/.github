# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0

"""Migrate a repository's checkouts to cachew-checkout and verify its pins.

Run from inside the consumer repository (or pass --root). The pin and any
excluded paths come from that repository's .github/cachew-checkout.json:

    {"action_sha": "<full commit of tenstorrent/.github>",
     "exclude": ["vendored/tree/"]}

Modes:
  --write        migrate: actions/checkout v7.0.1 steps and pins to any other
                 commit (or to the action's old tt-metal location) become
                 tenstorrent/.github/actions/cachew-checkout@<action_sha>.
                 With --action-sha, the new pin is saved to the config first.
  --check        exit 1 if any file still needs --write.
  --verify-pins  exit 1 unless every reference pins exactly action_sha.

With no paths, --write and --check inspect every tracked .yml/.yaml under a
.github/actions or .github/workflows directory. --verify-pins also reads every
tracked action.yml/action.yaml, wherever a composite action lives, and accepts
only a reference written as a plain or quoted value on its own `uses:` line,
since that is the only form whose ref it can read exactly.

Only checkouts of the exact version the action forwards to (actions/checkout
v7.0.1, by commit or tag) are migrated, so no step changes checkout version. Left
as plain actions/checkout on purpose:
  * steps with a trailing `# cachew: keep` comment;
  * jobs whose runs-on is a literal GitHub-hosted label (ubuntu-*, windows-*,
    macos-*), where cachew is a no-op; --write turns cachew pins there back
    into actions/checkout;
  * gh-aw generated lock files (*.lock.yml) and their .md sources, which pin
    their own checkout version and run on GitHub-hosted runners;
  * paths under a configured "exclude" prefix (e.g. vendored trees whose
    workflows run in another repository).
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


ACTION_REPO = "tenstorrent/.github/actions/cachew-checkout"
# Where the action lived before it moved to tenstorrent/.github. --write repins
# these; --verify-pins rejects them.
LEGACY_REPO = "tenstorrent/tt-metal/.github/actions/cachew-checkout"
# The actions/checkout commit action.yml forwards to (checked by the tests).
FORWARDED_CHECKOUT = "3d3c42e5aac5ba805825da76410c181273ba90b1"
MIGRATABLE_REFS = (FORWARDED_CHECKOUT, "v7.0.1")
CONFIG = Path(".github/cachew-checkout.json")
SHA = re.compile(r"[0-9a-f]{40}")

CHECKOUT = re.compile(
    r"(?m)^(?P<prefix>[ \t]*(?:-[ \t]+)?uses:[ \t]*)(?P<quote>['\"]?)"
    r"(?:actions/checkout@(?:"
    + "|".join(map(re.escape, MIGRATABLE_REFS))
    + r")|(?i:"
    + re.escape(ACTION_REPO)
    + "|"
    + re.escape(LEGACY_REPO)
    + r")@[0-9a-f]{40})"
    r"(?P=quote)(?:[ \t]*#[^\n]*)?[ \t]*$"
)
# Any mention of the action with a ref, wherever it appears in a file. GitHub
# resolves owner and repository names in any case, so a reference spelled
# Tenstorrent/.GitHub/... is held to the pin as well.
ANY_PIN = re.compile(
    r"(?P<repo>(?i:" + re.escape(ACTION_REPO) + "|" + re.escape(LEGACY_REPO) + r"))"
    r"(?P<subpath>/[\w./-]+)?@(?P<ref>[^\s'\"#]+)"
)
# A decoded uses: value naming the action. The ref is everything after the @, so
# a branch, short SHA or padded SHA is compared as written, and so is a SHA
# followed by more characters (`<sha>#x`, `<sha>'x`): Git allows those in branch
# names, so they are mutable refs that only look like the pin.
PIN_VALUE = re.compile(
    r"(?P<repo>(?i:" + re.escape(ACTION_REPO) + "|" + re.escape(LEGACY_REPO) + r"))"
    r"(?P<subpath>/[^@]*)?@(?P<ref>.*)",
    re.DOTALL,
)
# A uses: key in block style (`uses:` or `- uses:`) or inside a flow mapping
# (`{uses: ...}`), its key optionally quoted.
USES_KEY = re.compile(r"""(?m)(?:^[ \t]*(?:-[ \t]+)?|(?P<flow>[{,])[ \t]*)(?P<q>['"]?)uses(?P=q)[ \t]*:(?=[ \t\r\n]|$)""")
PLAIN_CHECKOUT = f"actions/checkout@{FORWARDED_CHECKOUT} # v7.0.1"
HOSTED_LABEL = re.compile(r"(?:ubuntu|windows|macos)-[\w.-]+")
TOP_LEVEL = re.compile(r"^(?P<key>[\w-]+):")
JOB = re.compile(r"^  [\w-]+:[ \t]*(?:#.*)?$")
RUNS_ON = re.compile(r"^    runs-on:[ \t]*(?P<quote>['\"]?)(?P<label>[^'\"#\s]+)(?P=quote)[ \t]*(?:#.*)?$")


class ConfigError(Exception):
    pass


def load_config(root, path=None):
    """{"action_sha": str, "exclude": [str]} from the consumer's config file."""
    file = Path(path) if path else root / CONFIG
    try:
        data = json.loads(file.read_text())
    except FileNotFoundError:
        raise ConfigError(f"{file} not found; create it with an action_sha (see --help)")
    except json.JSONDecodeError as error:
        raise ConfigError(f"{file}: invalid JSON: {error}")
    sha = data.get("action_sha", "")
    if not isinstance(sha, str) or not SHA.fullmatch(sha):
        raise ConfigError(f"{file}: action_sha must be a full 40-character commit SHA, got {sha!r}")
    exclude = data.get("exclude", [])
    if not isinstance(exclude, list) or not all(isinstance(p, str) and p for p in exclude):
        raise ConfigError(f"{file}: exclude must be a list of path prefixes")
    return {"action_sha": sha, "exclude": tuple(exclude), "file": file, "data": data}


def save_sha(config, sha):
    config["data"]["action_sha"] = sha
    config["file"].write_text(json.dumps(config["data"], indent=2) + "\n")
    config["action_sha"] = sha


def repository_root(start=None):
    start = start or Path.cwd()
    return Path(subprocess.check_output(["git", "-C", str(start), "rev-parse", "--show-toplevel"], text=True).strip())


def excluded(path, prefixes=()):
    relative = path.as_posix()
    if relative.startswith(tuple(prefixes)) or relative.endswith(".lock.yml"):
        return True
    return path.suffix == ".md"


def hosted_jobs(text):
    """Character ranges of the workflow jobs whose runs-on is a literal GitHub-hosted label."""
    spans, start, hosted, in_jobs, offset = [], None, False, False, 0

    def close(end):
        if start is not None and hosted:
            spans.append((start, end))

    for line in text.splitlines(keepends=True):
        top = TOP_LEVEL.match(line)
        if top:
            close(offset)
            start, hosted, in_jobs = None, False, top["key"] == "jobs"
        elif in_jobs and JOB.match(line):
            close(offset)
            start, hosted = offset, False
        elif start is not None:
            runs_on = RUNS_ON.match(line)
            if runs_on:
                hosted = bool(HOSTED_LABEL.fullmatch(runs_on["label"]))
        offset += len(line)
    close(offset)
    return spans


def rewrite(text, action_sha):
    if not SHA.fullmatch(action_sha):
        raise ValueError(f"action_sha must be a full commit SHA, got {action_sha!r}")
    action = f"{ACTION_REPO}@{action_sha}"
    hosted = hosted_jobs(text)

    def replace(match):
        if "cachew: keep" in match[0]:
            return match[0]
        if any(start <= match.start() < end for start, end in hosted):
            return f"{match['prefix']}{PLAIN_CHECKOUT}" if "cachew-checkout@" in match[0].lower() else match[0]
        return f"{match['prefix']}{action} # cachew checkout"

    return CHECKOUT.sub(replace, text)


def migrate_file(path, action_sha, write=False, root=None, exclude=()):
    root = root or repository_root()
    path = Path(path)
    absolute = path if path.is_absolute() else root / path
    relative = absolute.resolve().relative_to(root.resolve())
    if excluded(relative, exclude):
        return False
    before = absolute.read_text()
    after = rewrite(before, action_sha)
    if before == after:
        return False
    if write:
        absolute.write_text(after)
    return True


def tracked_consumers(root, exclude=()):
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    for value in paths:
        path = Path(value)
        if not value or value.startswith(tuple(exclude)):
            continue
        parts = path.parts
        if ".github" not in parts:
            continue
        github = parts.index(".github")
        if len(parts) <= github + 1 or parts[github + 1] not in ("actions", "workflows"):
            continue
        if path.suffix in (".yml", ".yaml"):
            yield path


def pinned_files(root, exclude=()):
    """Every file whose uses: lines GitHub runs: the migrated workflow and action
    directories, and composite actions (action.yml/action.yaml) anywhere."""
    paths = set(tracked_consumers(root, exclude))
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    for value in tracked:
        if value and not value.startswith(tuple(exclude)) and Path(value).name in ("action.yml", "action.yaml"):
            paths.add(Path(value))
    return sorted(paths)


def uses_values(text):
    """(start, end, value, problem) for each uses: value in YAML text. value is
    decoded when it is a plain, single-quoted, or escape-free double-quoted scalar
    on the key's own line; otherwise problem says why it cannot be read exactly."""
    for key in USES_KEY.finditer(text):
        start = key.end()
        while start < len(text) and text[start] in " \t":
            start += 1
        line_end = text.find("\n", start)
        line_end = len(text) if line_end < 0 else line_end
        line = text[start:line_end].rstrip("\r")
        if not line or line.startswith("#"):
            yield start, start, None, "its value is not on the uses: line"
        elif line[0] in "|>&*!{[":
            yield start, start, None, "its value is not a plain or quoted scalar"
        elif line[0] == "'":
            match = re.match(r"'((?:[^']|'')*)'", line)
            if not match:
                yield start, start, None, "its quoted value does not end on the uses: line"
            else:
                yield start, start + match.end(), match[1].replace("''", "'"), None
        elif line[0] == '"':
            match = re.match(r'"((?:[^"\\]|\\.)*)"', line)
            if not match:
                yield start, start, None, "its quoted value does not end on the uses: line"
            elif "\\" in match[1]:
                yield start, start, None, "its quoted value contains escape sequences"
            else:
                yield start, start + match.end(), match[1], None
        else:
            # A plain scalar ends at a comment (` #`) and, in a flow mapping, at , or }.
            end = re.search(r"[ \t]#" + (r"|[,}]" if key["flow"] else ""), line)
            value = line[: end.start() if end else len(line)].rstrip()
            yield start, start + len(value), value, None


def verify_pins(root, action_sha, exclude=()):
    """Every reference pins exactly action_sha in tenstorrent/.github: no other
    commit, no reference to the old tt-metal location, no subdirectory.
    Whether action_sha exists there is for the caller's CI to check."""
    problems = []
    pins = {}
    for path in pinned_files(root, exclude):
        # Files --write leaves alone (gh-aw lock files) are not held to its pin.
        if excluded(path, exclude):
            continue
        text = (root / path).read_text()
        read = []
        for start, end, value, problem in uses_values(text):
            line = text.count("\n", 0, start) + 1
            if problem:
                problems.append(f"{path}:{line}: a uses: entry cannot be verified: {problem}; write it as one plain line")
                continue
            match = PIN_VALUE.fullmatch(value)
            if not match:
                continue
            read.append((start, end))
            if match["repo"].lower() == LEGACY_REPO.lower():
                problems.append(f"{path}:{line} references {value}; the action moved to {ACTION_REPO} (run --write)")
                continue
            if match["subpath"]:
                problems.append(f"{path}:{line} references {value}; reference the action itself, not a subdirectory")
            pins.setdefault(match["ref"], []).append(path.as_posix())
        # A mention the uses: values above do not account for (a comment, an
        # anchor, a multi-line value) could still be what GitHub runs.
        for match in ANY_PIN.finditer(text):
            if not any(start <= match.start() < end for start, end in read):
                line = text.count("\n", 0, match.start()) + 1
                problems.append(f"{path}:{line} mentions {match[0]} outside a uses: value it can verify")
    if set(pins) - {action_sha}:
        problems.append(f"references pin {sorted(pins)}, expected only action_sha {action_sha}")
    for problem in problems:
        print(problem)
    print("Pins verified." if not problems else f"{len(problems)} pin problem(s).")
    return 1 if problems else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--verify-pins", action="store_true")
    parser.add_argument("--root", type=Path, help="consumer repository (default: the Git repository containing the current directory)")
    parser.add_argument("--config", type=Path, help=f"config file (default: <root>/{CONFIG})")
    parser.add_argument("--action-sha", help="pin to use instead of the config's; saved to the config with --write")
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args(argv)
    root = repository_root(args.root)
    try:
        config = load_config(root, args.config)
    except ConfigError as error:
        print(error, file=sys.stderr)
        return 2
    if args.action_sha:
        if not SHA.fullmatch(args.action_sha):
            print(f"--action-sha must be a full 40-character commit SHA, got {args.action_sha!r}", file=sys.stderr)
            return 2
        if args.write:
            save_sha(config, args.action_sha)
        else:
            config["action_sha"] = args.action_sha
    sha, exclude = config["action_sha"], config["exclude"]
    if args.verify_pins:
        return verify_pins(root, sha, exclude)
    candidates = args.paths or tracked_consumers(root, exclude)
    changed = [path for path in candidates if migrate_file(path, sha, args.write, root, exclude)]
    for path in changed:
        print(f"{'Migrated' if args.write else 'Needs cachew migration:'} {path}")
    print(f"{len(changed)} file(s) {'updated' if args.write else 'need migration'}.")
    return 1 if changed and args.check else 0


if __name__ == "__main__":
    sys.exit(main())

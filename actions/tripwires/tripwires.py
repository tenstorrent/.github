#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
"""Tripwires for GitHub Actions: checks that stop a step on a value that only
makes sense as an attack.

A tripwire is not input validation. Validation refuses a value the action does
not support, and may fall back or explain how to correct it. A tripwire fires
on a value that no supported configuration produces: an option where a ref
belongs, a path that leaves the workspace, a host with shell metacharacters, a
secret on its way to an origin nobody trusts. There is no fallback, and the
report never repeats the value, which could itself carry workflow commands.

Two groups:

  code injection       no_option, single_line, shell_safe, relative_path,
                       inside, origin (its host check), plain_path
  secret exfiltration  trusted_origin, untrusted_event, oidc_request_url,
                       oidc_claims, and the reporting helpers: mask, report,
                       write_output
  both                 hostile_environment

Use it in one of three ways, all with the same checks:

  import     sys.path.insert(0, <this directory>); import tripwires
  command    python3 tripwires.py --title my-action <<'EOF'
             no-option IN_REF
             inside    IN_PATH
             EOF
  step       uses: tenstorrent/.github/actions/tripwires@<sha>   (action.yml)

Standard library only. Python 3.9 or newer.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import sys
import urllib.parse
import uuid


class Violation(Exception):
    """A tripwire fired. The message is built from fixed text and the caller's
    own label for the value (`what`), never from the value."""


class Unsupported(ValueError):
    """A URL that is not an attack but is not a plain origin either."""


# ── Reporting ────────────────────────────────────────────────────────────────


def escape_data(text):
    """The message of a workflow command: the characters that end or change it."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(text):
    """A property of a workflow command, such as an annotation title."""
    return escape_data(text).replace(":", "%3A").replace(",", "%2C")


def mask(value):
    """A GitHub workflow command that hides value wherever the log would show it."""
    if value:
        print("::add-mask::" + escape_data(value), flush=True)


# The end of every tripwire annotation's title. It is a contract: alerting
# outside the job (README.md, "Alerting") finds a tripped tripwire by it, so it
# never changes and nothing else uses it.
ANNOTATION_SUFFIX = ": possible security compromise attempt"
# The title suffix when the checks could not run at all (no interpreter, a
# check line that is wrong, an error in this file). Also a contract: the shell
# fallbacks of the actions print it as text, since they have no Python.
CANNOT_RUN_SUFFIX = ": tripwires could not run"


def report(title, error, consequence="The step was stopped."):
    """A GitHub error annotation for a Violation. title names the action;
    consequence says what did not happen (for example, that there was no fallback)."""
    print(
        f"::error title={escape_property(title)}{ANNOTATION_SUFFIX}::"
        + escape_data(
            f"{error}. {consequence} "
            "If this input is intentional, it is not supported; otherwise treat the workflow run as hostile."
        ),
        flush=True,
    )


def write_output(name, value, path=None):
    """Append one step output (or, with path=GITHUB_ENV, one variable) with a
    random delimiter: a value can never end its own entry or start another."""
    path = path or os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    delimiter = f"tripwires_{uuid.uuid4().hex}"
    with open(path, "a") as stream:
        stream.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")


# ── Code injection ───────────────────────────────────────────────────────────


def no_option(value, what="value", reader="a command-line option"):
    """A value that becomes a command argument must not start with '-'."""
    if value.startswith("-"):
        raise Violation(f"{what} starts with '-' and would be read as {reader}")
    return value


def single_line(value, what="value"):
    """A value written to GITHUB_ENV, GITHUB_OUTPUT, an HTTP header or a
    configuration file must hold no line break or other control character."""
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise Violation(f"{what} contains a line break or control character and could inject a line or a command")
    return value


# shlex.quote's definition of a word the shell reads as itself.
SHELL_UNSAFE = re.compile(r"[^\w@%+=:,./-]", re.ASCII)


def shell_safe(value, what="value"):
    """A name or identifier that reaches shell text (an `eval`, an `ssh`
    command line, `git submodule foreach`) must hold no shell metacharacters.
    Not for free text: quotes and spaces fire it."""
    if SHELL_UNSAFE.search(value):
        raise Violation(f"{what} contains shell metacharacters")
    return value


def relative_path(value, what="path", forbidden=()):
    """A path below some directory, as written: not absolute, no '..', no
    backslash, no control characters, and none of the forbidden components
    (for example '.git')."""
    parts = value.split("/")
    if (
        value.startswith("/")
        or ".." in parts
        or any(name in parts for name in forbidden)
        or "\\" in value
        or any(ord(c) < 32 for c in value)
    ):
        raise Violation(f"{what} escapes its directory or contains control characters")
    return value


def inside(base, path, what="path", where="its directory"):
    """The resolved location of path below base. Existing symlinks are followed
    first, so a link that points out of base fires too."""
    base = Path(base).resolve()
    target = (base / path).resolve()
    if target != base and base not in target.parents:
        raise Violation(f"{what} is outside {where}")
    return target


def plain_path(value, what="URL path"):
    """A URL path made of plain segments: no query, fragment, percent-encoding
    or anything else a second parser could read as a different request."""
    if not re.fullmatch(r"[\w./-]*", value, re.ASCII):
        raise Violation(f"{what} carries a query, encoded segment or other request smuggling")
    return value


def as_parsed(value):
    """A URL as every parser reads it: tabs and line breaks dropped, then C0
    controls and spaces trimmed from both ends."""
    return re.sub(r"[\t\n\r]", "", value).strip("".join(map(chr, range(0x21))))


# The authority of a URL as written: after the scheme and its slashes, up to the
# first character that ends it for any of Python, Git or a WHATWG parser.
AUTHORITY = re.compile(r"[^:/?#\\]*:[/\\]*([^/?#\\]*)")
METACHARACTER_FREE_HOST = re.compile(r"[A-Za-z0-9.:\[\]-]*")
# DNS names and IP literals: no quotes, spaces or shell metacharacters.
HOST = re.compile(r"(?P<name>[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|\[[0-9A-Fa-f:.]{2,45}\])(?::(?P<port>[0-9]{1,5}))?")


def origin(value, what="URL", loopback_http=False):
    """The origin a server URL names, as a browser's URL.origin spells it: lower
    case and no default port.

    Violation when the host, read as written or as parsed, holds anything but
    DNS and IP-literal characters: such a host exists to break out of a shell
    command or a configuration key. A URL Python's parser rejects (a malformed
    IPv6 literal, a character NFKC maps to a delimiter) is still read as written.

    Unsupported when the URL is harmless but more than an origin: not HTTPS, or
    with userinfo, a path, a query or a fragment. loopback_http also accepts
    plain HTTP to this machine, for test fixtures only."""
    written = as_parsed(value)
    authority = AUTHORITY.match(written)
    hosts = [authority[1].rpartition("@")[2]] if authority else []
    try:
        url = urllib.parse.urlsplit(value)
    except ValueError:
        url = None
    else:
        hosts.append(url.netloc.rpartition("@")[2])
    if any(not METACHARACTER_FREE_HOST.fullmatch(host) for host in hosts):
        raise Violation(f"{what} host contains shell or configuration metacharacters")
    if url is None:
        raise Unsupported("unsupported URL")
    local_http = loopback_http and url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost", "::1")
    if (
        (url.scheme != "https" and not local_http)
        or not url.netloc
        or url.username
        or url.password
        or url.path not in ("", "/")
        or url.query
        or url.fragment
    ):
        raise Unsupported("unsupported URL")
    host = HOST.fullmatch(url.netloc)
    if not host:
        raise Unsupported("unsupported URL")
    name, port = host["name"].lower(), host["port"]
    if port is not None:
        if int(port) > 65535:
            raise Unsupported("unsupported URL")
        if int(port) != (443 if url.scheme == "https" else 80):
            name = f"{name}:{int(port)}"
    return f"{url.scheme}://{name}"


# ── Secret exfiltration ──────────────────────────────────────────────────────


def trusted_origin(value, trusted, what="URL", secret="a secret", loopback_http=False):
    """The origin of value when it is one of the trusted origins. Anything else
    is a place a secret must not go: another host, plain HTTP, or a spelling
    (userinfo, a path) that hides where the request ends up."""
    allowed = {origin(entry, "trusted origin", loopback_http) for entry in trusted}
    try:
        found = origin(value, what, loopback_http)
    except Unsupported:
        found = None
    if found not in allowed:
        raise Violation(f"{what} is not a trusted origin and would have received {secret}")
    return found


# Events that run with the base repository's secrets and write token while code
# or data from outside (a fork's pull request, another workflow's run) steers them.
UNTRUSTED_EVENTS = ("pull_request_target", "workflow_run")


def untrusted_event(event, refused=UNTRUSTED_EVENTS):
    """A step that handles a secret must not run on an event outside code controls."""
    if event in refused:
        raise Violation(f"the workflow runs on {event}, where code from outside the repository can reach the job's secrets")
    return event


# GitHub's OIDC issuer and the hosts of its token request endpoint (github.com).
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
OIDC_REQUEST_HOSTS = (".actions.githubusercontent.com",)


def oidc_request_url(value, what="ACTIONS_ID_TOKEN_REQUEST_URL", hosts=OIDC_REQUEST_HOSTS):
    """The URL a job asks for its OIDC token, with the request token as bearer.
    It must be HTTPS on one of GitHub's hosts (a name, or a suffix that starts
    with '.'): anywhere else receives the request token."""
    try:
        url = urllib.parse.urlsplit(value)
        host = (url.hostname or "").lower()
        port = url.port
    except ValueError:
        url = host = port = None
    trusted = host and any(host.endswith(name) if name.startswith(".") else host == name for name in hosts)
    if url is None or url.scheme != "https" or url.username or url.password or port not in (None, 443) or not trusted:
        raise Violation(f"{what} is not a GitHub OIDC endpoint and would have received the OIDC request token")
    return value


JWT_FORM = re.compile(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")


def _unique_members(pairs):
    members = dict(pairs)
    if len(members) != len(pairs):
        # Two members with one name: one parser reads the first, another the last.
        raise ValueError("duplicate member")
    return members


def _jwt_object(segment):
    # validate=True: a character outside the alphabet is an error, not skipped.
    data = base64.b64decode(segment + "=" * (-len(segment) % 4), altchars=b"-_", validate=True)
    value = json.loads(data, object_pairs_hook=_unique_members)
    if not isinstance(value, dict):
        raise ValueError("not an object")
    return value


def oidc_claims(token, audience, repository, what="OIDC token", issuer=OIDC_ISSUER):
    """The claims of a job's OIDC token, when they are the ones this job asked
    for: GitHub's issuer, the requested audience and no other, this repository.
    Any other token was swapped in on the way, and must not be sent on.

    Nothing is verified cryptographically: the receiver does that. The form is
    strict, so that this parser and the receiver's cannot read two different
    tokens: exactly three base64url parts, a header and a payload that are JSON
    objects, no member named twice. A token in any other form returns None,
    since it names no one and no receiver takes it."""
    if not isinstance(token, str) or not JWT_FORM.fullmatch(token):
        return None
    header, payload, _ = token.split(".")
    try:
        _jwt_object(header)
        claims = _jwt_object(payload)
    except (ValueError, RecursionError):
        return None
    audiences = claims.get("aud")
    audiences = audiences if isinstance(audiences, list) else [audiences]
    claimed = claims.get("repository")
    if (
        claims.get("iss") != issuer
        or not audiences
        or any(not isinstance(name, str) or name != audience for name in audiences)
        or not isinstance(claimed, str)
        or claimed.lower() != repository.lower()
    ):
        raise Violation(f"{what} does not have the issuer, audience and repository this job asked for")
    return claims


FALSE_VALUES = ("0", "false", "no", "off")

# Variables that name the certificates a client trusts: curl, OpenSSL (and with
# it Python and Git), Git, Node, Python requests.
TRUST_STORES = (
    "CURL_CA_BUNDLE",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "GIT_SSL_CAINFO",
    "GIT_SSL_CAPATH",
    "NODE_EXTRA_CA_CERTS",
    "REQUESTS_CA_BUNDLE",
)


def below(root, place):
    """Whether place is root or below it. root has every link followed; place
    is read as written, with every link followed, and in its directory with
    every link followed: another spelling of root (/proc/self/cwd, a link) is
    still root. A relative place is read from root."""
    place = os.path.join(root, place)
    return any(
        os.path.splitdrive(spelling)[0] == os.path.splitdrive(root)[0] and os.path.commonpath([root, spelling]) == root
        for spelling in (
            os.path.abspath(place),
            os.path.realpath(place),
            os.path.join(os.path.realpath(os.path.dirname(place)), os.path.basename(place)),
        )
    )


def environment_violations(environ, commands=(), posix=None):
    """Every Violation in an environment that an earlier, less trusted step of
    the job can have prepared (GITHUB_ENV, GITHUB_PATH) to run code in a later
    step or to make it print or leak its secrets. Names only: no value is
    reported.

    commands names the programs that carry the caller's secrets (curl, jq): the
    first of each on PATH must not be inside GITHUB_WORKSPACE, where a pull
    request places files. posix (default: this system) says whether an empty or
    relative PATH entry means the current directory, as it does to a POSIX
    shell."""
    found = []

    def fire(message):
        found.append(Violation(message))

    if environ.get("BASH_ENV"):
        fire("BASH_ENV is set, so every bash script of the job first runs the file it names")
    for name in ("LD_PRELOAD", "LD_AUDIT", "DYLD_INSERT_LIBRARIES"):
        if environ.get(name):
            fire(f"{name} is set, so every program of the job first loads the library it names")
    # Whatever its name: a script finds its own directory, a tool or its exit
    # through commands, and any of them can be the function.
    if any(key.startswith("BASH_FUNC_") for key in environ):
        fire("an exported shell function can replace a command in every bash script of the job")
    if any(option in ("xtrace", "verbose") for option in environ.get("SHELLOPTS", "").split(":")):
        fire("SHELLOPTS turns on tracing in every bash script, which prints secrets before they are masked")
    if "$(" in environ.get("PS4", "") or "`" in environ.get("PS4", ""):
        fire("PS4 holds a command, which bash runs for every traced line")
    if environ.get("GIT_TRACE_REDACT", "").strip().lower() in FALSE_VALUES:
        fire("GIT_TRACE_REDACT is off, so Git traces print credentials")
    if environ.get("NODE_TLS_REJECT_UNAUTHORIZED", "").strip() == "0":
        fire("NODE_TLS_REJECT_UNAUTHORIZED is 0, so Node sends secrets to servers it has not verified")
    path = environ.get("PATH", "")
    if (os.name == "posix" if posix is None else posix) and path:
        if any(not entry or not entry.startswith("/") for entry in path.split(":")):
            fire("PATH has an empty or relative entry, so commands are looked up in the current directory")
    workspace = environ.get("GITHUB_WORKSPACE", "")
    if not workspace:
        return found
    root = os.path.realpath(workspace)
    # A certificate file in the workspace makes every client trust the server
    # of whoever wrote the file. One anywhere else (a runner behind a proxy
    # that inspects TLS) is the runner's own and passes.
    for name in TRUST_STORES:
        if any(place and below(root, place) for place in environ.get(name, "").split(os.pathsep)):
            fire(
                f"{name} names certificates inside the workspace, where a pull request can place them, "
                "so a request that carries a secret would trust any server"
            )
    for command in commands if path else ():
        program = shutil.which(command, path=path)
        if program and below(root, program):
            fire(f"the first {command} on PATH is inside the workspace, where a pull request can place it")
    return found


def hostile_environment(environ, commands=()):
    """Raise the first of environment_violations(environ, commands), if any."""
    for violation in environment_violations(environ, commands):
        raise violation


# ── Command line ─────────────────────────────────────────────────────────────

# The whitespace JavaScript's String.prototype.trim strips, as core.getInput
# does: a value is checked as the action that receives it reads it.
INPUT_WHITESPACE = (
    "\t\n\v\f\r   " + "".join(map(chr, range(0x2000, 0x200B))) + "    　﻿"
)


COMMAND_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*")


class SpecError(Exception):
    """The list of checks is wrong. The command fails closed on it."""


def _inside(value, label, arguments, environ):
    if len(arguments) > 1:
        raise SpecError("inside takes at most one base variable")
    base_name = arguments[0] if arguments else "GITHUB_WORKSPACE"
    if not environ.get(base_name):
        raise SpecError(f"inside needs the environment variable {base_name}")
    inside(environ[base_name], value, label, f"the directory in {base_name}")


def _trusted_origin(value, label, arguments, environ):
    if not arguments:
        raise SpecError("trusted-origin needs at least one origin")
    try:
        trusted_origin(value, arguments, label)
    except Unsupported:
        raise SpecError("trusted-origin takes plain HTTPS origins, such as https://example.com") from None


def _oidc_request_url(value, label, arguments, environ):
    oidc_request_url(value, label, tuple(arguments) or OIDC_REQUEST_HOSTS)


def _oidc_claims(value, label, arguments, environ):
    if not 1 <= len(arguments) <= 2:
        raise SpecError("oidc-claims takes the audience and at most one repository variable")
    repository_name = arguments[1] if len(arguments) > 1 else "GITHUB_REPOSITORY"
    if not environ.get(repository_name):
        raise SpecError(f"oidc-claims needs the environment variable {repository_name}")
    # A token that cannot be decoded names no job. The command has no later
    # step to refuse it, so it does not pass here.
    if oidc_claims(value, arguments[0], environ[repository_name], label) is None:
        raise Violation(f"{label} is not a token that GitHub issues and must not be sent on")


def _origin(value, label, arguments, environ):
    try:
        origin(value, label)
    except Unsupported:
        pass


# check name -> (function(value, label, arguments, environ), accepts arguments)
CHECKS = {
    "no-option": (lambda value, label, arguments, environ: no_option(value, label), False),
    "single-line": (lambda value, label, arguments, environ: single_line(value, label), False),
    "shell-safe": (lambda value, label, arguments, environ: shell_safe(value, label), False),
    "relative-path": (lambda value, label, arguments, environ: relative_path(value, label, arguments), True),
    "inside": (_inside, True),
    "plain-path": (lambda value, label, arguments, environ: plain_path(value, label), False),
    "url-host": (_origin, False),
    "trusted-origin": (_trusted_origin, True),
    "oidc-url": (_oidc_request_url, True),
    "oidc-claims": (_oidc_claims, True),
}


def run_checks(spec, values, environ):
    """Run every check in spec and return the Violations, in order.

    One check per line: `<check> <name>[=<label>] [argument ...]`; `#` starts a
    comment. name is a key of values (a JSON object of inputs) or else an
    environment variable; label, one word, is what a report calls the value
    (default: name), so `IN_REF=ref` reads the variable and reports `ref`. The
    value is trimmed as an action input is, and an empty value passes: the input
    was not given. `event [name ...]` takes no value and checks
    GITHUB_EVENT_NAME; `environment [command ...]` takes none and checks the
    whole environment, and where PATH finds each named command."""
    violations = []
    for number, line in enumerate(spec.splitlines(), 1):
        words = line.split("#", 1)[0].split()
        if not words:
            continue
        check, arguments = words[0], words[1:]
        try:
            if check == "event":
                untrusted_event(environ.get("GITHUB_EVENT_NAME", ""), tuple(arguments) or UNTRUSTED_EVENTS)
                continue
            if check == "environment":
                if not all(COMMAND_NAME.fullmatch(argument) for argument in arguments):
                    raise SpecError("environment takes command names, such as curl")
                violations.extend(environment_violations(environ, arguments))
                continue
            if check not in CHECKS:
                raise SpecError(f"unknown check {check}")
            function, takes_arguments = CHECKS[check]
            if not arguments:
                raise SpecError(f"{check} needs the name of a value")
            (name, _, label), arguments = arguments[0].partition("="), arguments[1:]
            if not name:
                raise SpecError(f"{check} needs the name of a value")
            if arguments and not takes_arguments:
                raise SpecError(f"{check} takes only the name of a value")
            if name in values:
                value = values[name]
            elif name in environ:
                value = environ[name]
            else:
                raise SpecError(f"no value named {name}")
            if not isinstance(value, str):
                # toJSON(inputs) gives booleans and numbers for typed inputs.
                value = json.dumps(value)
            value = value.strip(INPUT_WHITESPACE)
            if value:
                function(value, label or name, arguments, environ)
        except Violation as error:
            violations.append(error)
        except SpecError as error:
            raise SpecError(f"line {number}: {error}") from None
    return violations


def main(argv=None, environ=None):
    environ = os.environ if environ is None else environ
    parser = argparse.ArgumentParser(description="Run tripwire checks; exit 1 when one fires, 2 when the checks cannot run.")
    parser.add_argument("--title", default="tripwires", help="name of the calling action, for the error annotation")
    parser.add_argument(
        "--consequence", default="The step was stopped.", help="one sentence on what did not happen, for the annotation"
    )
    parser.add_argument("--checks-env", help="environment variable holding the checks (default: read them from stdin)")
    parser.add_argument("--values-env", help="environment variable holding a JSON object of values, such as toJSON(inputs)")
    options = parser.parse_args(argv)
    title = options.title or "tripwires"
    try:
        spec = environ.get(options.checks_env, "") if options.checks_env else sys.stdin.read()
        values = {}
        if options.values_env and environ.get(options.values_env, "").strip():
            try:
                values = json.loads(environ[options.values_env])
            except ValueError:
                values = None
            if not isinstance(values, dict):
                raise SpecError("values is not a JSON object")
        if not any(line.split("#", 1)[0].strip() for line in spec.splitlines()):
            raise SpecError("no checks given")
        violations = run_checks(spec, values, environ)
    except SpecError as error:
        # Fail closed: a check that cannot run protects nothing.
        print(f"::error title={escape_property(title)}{CANNOT_RUN_SUFFIX}::" + escape_data(str(error)), flush=True)
        return 2
    except Exception as error:  # noqa: BLE001
        # An error in the checks themselves also fails closed, with the same
        # title. Only the type is printed: a message could hold a value.
        print(
            f"::error title={escape_property(title)}{CANNOT_RUN_SUFFIX}::"
            + escape_data(f"internal error in the checks ({type(error).__name__}). {options.consequence}"),
            flush=True,
        )
        return 2
    for violation in violations:
        report(title, violation, options.consequence)
    if environ.get("GITHUB_OUTPUT"):
        write_output("security-violation", str(bool(violations)).lower(), environ["GITHUB_OUTPUT"])
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())

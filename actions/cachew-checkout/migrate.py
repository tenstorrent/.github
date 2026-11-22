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
  * `uses:` lines inside a block scalar (a `run: |` script that writes another
    workflow, say): they are text, not steps of this file. A pin to the action
    there is still moved to action_sha, never turned back into actions/checkout;
  * steps with a trailing `# cachew: keep` comment;
  * jobs whose runs-on is a literal GitHub-hosted label (ubuntu-*, windows-*,
    macos-*, in any case) or a list of only such labels, where cachew is a
    no-op; --write turns cachew pins there back into actions/checkout;
  * gh-aw generated lock files (*.lock.yml) and their .md sources, which pin
    their own checkout version and run on GitHub-hosted runners. --verify-pins
    still holds a lock file's pins to this action to action_sha, since GitHub
    runs it: set the pin in the .md source and recompile;
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
    r"(?:(?i:actions/checkout)@(?:"
    + "|".join(map(re.escape, MIGRATABLE_REFS))
    + r")|(?i:"
    + re.escape(ACTION_REPO)
    + "|"
    + re.escape(LEGACY_REPO)
    + r")@[0-9a-f]{40})"
    r"(?P=quote)(?:[ \t]+#[^\n]*)?[ \t]*$"
)
# Any mention of the action with a ref, wherever it appears in a file and however
# its path is spelled: one word that starts at the owner, names the action and
# ends in @<ref>. GitHub resolves owner and repository names in any case, so a
# reference spelled Tenstorrent/.GitHub/... is held to the pin as well.
ANY_PIN = re.compile(r"(?i:tenstorrent[/\\][^\s@'\"#]*cachew-checkout)[^\s@'\"#]*@[^\s'\"#]+")
# The action's directory in each repository it has lived in, in lower case.
ACTION_PATHS = {
    tuple(repo.lower().split("/")[:2]): tuple(repo.lower().split("/")[2:]) for repo in (ACTION_REPO, LEGACY_REPO)
}
# Escape sequences of a double-quoted YAML scalar that can spell a character of
# the action's name or its @: \xNN, \uNNNN, \UNNNNNNNN, an escaped line break
# (which joins two lines) and an escaped / or \.
ESCAPE = re.compile(r"\\(?:x([0-9A-Fa-f]{2})|u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8})|(\r?\n[ \t]*)|([/\\]))")
# A uses: key in block style (`uses:` or `- uses:`) or inside a flow mapping
# (`{uses: ...}`), its key optionally quoted.
USES_KEY = re.compile(r"""(?m)(?:^[ \t]*(?:-[ \t]+)?|(?P<flow>[{,])[ \t]*)(?P<q>['"]?)uses(?P=q)[ \t]*:(?=[ \t\r\n]|$)""")
PLAIN_CHECKOUT = f"actions/checkout@{FORWARDED_CHECKOUT} # v7.0.1"
# GitHub matches runner labels in any case.
HOSTED_LABEL = re.compile(r"(?i:ubuntu|windows|macos)-[\w.-]+")
TOP_LEVEL = re.compile(r"^(?P<quote>['\"]?)(?P<key>[\w-]+)(?P=quote)[ \t]*:")
# A job's runs-on key, with the value on its line (empty before a block sequence).
RUNS_ON = re.compile(r"(?P<quote>['\"]?)runs-on(?P=quote)[ \t]*:(?:[ \t]+(?P<value>.*))?")
TRAILING_COMMENT = re.compile(r"(?:^|[ \t]+)#.*$")


# A line whose value is a block scalar: `key: |`, `- >-`, `key: !!str |2`, with
# an optional comment. Its content is every following line indented more deeply.
BLOCK_SCALAR = re.compile(r"(?:^[ \t]*|[:\-][ \t]+)(?:[!&]\S*[ \t]+)*[|>](?:[+-][1-9]?|[1-9][+-]?)?[ \t]*(?:#.*)?$")
# The start of a line that holds block sequence entries: `- `, `- - `.
ENTRIES = re.compile(r"[ \t]*(?:-[ \t]+)*")
ITEM_SCALAR = re.compile(r"(?:[!&]\S*[ \t]+)*[|>]")
# Where a node starts on a line: after white space and any tags and anchors.
NODE_START = re.compile(r"[ \t]*(?:[!&]\S*[ \t]+)*")
# A plain key and the `: ` after it; the `:` that follows a quoted key.
PLAIN_KEY = re.compile(r"[^\s#'\"{\[|>][^#]*?:(?:[ \t]+|$)")
KEY_END = re.compile(r"[ \t]*:(?:[ \t]+|$)")
# In a flow collection, a quote that starts a node, and a comment.
FLOW_QUOTE = re.compile(r"(?:^|[{\[,:])[ \t]*(?P<quote>['\"])")
COMMENT = re.compile(r"(?:^|[ \t])#")


def lines(text):
    """The lines of a file, each with its line feed. Not str.splitlines, which
    also splits at form feed, U+0085, U+2028 and others that YAML keeps in a line."""
    return re.findall(r"[^\n]*\n|[^\n]+", text)


class ConfigError(Exception):
    pass


def load_config(root, path=None):
    """{"action_sha": str, "exclude": [str]} from the consumer's config file."""
    file = Path(path) if path else root / CONFIG
    try:
        data = json.loads(file.read_text())
    except FileNotFoundError:
        raise ConfigError(f"{file} not found; create it with an action_sha (see --help)")
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ConfigError(f"{file}: invalid JSON: {error}")
    except OSError as error:
        raise ConfigError(f"{file}: cannot be read: {error}")
    if not isinstance(data, dict):
        raise ConfigError(f"{file}: must be a JSON object with an action_sha")
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
    if relative.startswith(tuple(prefixes)) or generated(path):
        return True
    return path.suffix.lower() == ".md"


def generated(path):
    """A gh-aw lock file, which gh-aw writes from its .md source."""
    return path.name.lower().endswith(".lock.yml")


def scalar(text):
    """A label as written: without its comment and its quotes."""
    text = TRAILING_COMMENT.sub("", text).strip()
    return text[1:-1] if len(text) > 1 and text[0] in "'\"" and text[-1] == text[0] else text


def hosted_jobs(text):
    """Character ranges of the workflow jobs whose runs-on is one or more literal
    GitHub-hosted labels: a scalar, a flow sequence (`[ubuntu-latest]`) or a block
    sequence of them. Jobs and their keys are found by their indentation, whatever
    its width; any key at the jobs' indentation starts a job, however it is
    written (quoted, anchored), since a job that is not seen would take the next
    job's runs-on."""
    spans, start, labels, in_jobs, offset = [], None, None, False, 0
    job_indent = key_indent = None
    listing = False

    def close(end):
        if start is not None and labels and all(HOSTED_LABEL.fullmatch(label) for label in labels):
            spans.append((start, end))

    for line in lines(text):
        content = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        top = TOP_LEVEL.match(line)
        if top:
            close(offset)
            start, labels, in_jobs, job_indent = None, None, top["key"] == "jobs", None
        elif not in_jobs or not content or content.startswith("#") or not indent:
            pass
        elif job_indent is None or indent == job_indent:
            close(offset)
            start, labels, job_indent, key_indent, listing = offset, None, indent, None, False
        elif start is not None and indent > job_indent:
            if key_indent is None:
                key_indent = indent
            if listing and indent >= key_indent and (content == "-" or content.startswith("- ")):
                labels.append(scalar(content[1:]))
            elif indent == key_indent:
                listing = False
                runs_on = RUNS_ON.fullmatch(content)
                if runs_on:
                    value = TRAILING_COMMENT.sub("", runs_on["value"] or "").strip()
                    if not value:
                        labels, listing = [], True
                    elif value.startswith("[") and value.endswith("]"):
                        labels = [scalar(item) for item in value[1:-1].split(",")]
                    else:
                        labels = [scalar(value)]
        offset += len(line)
    close(offset)
    return spans


def quote_end(text, at, quote):
    """The index after the quote that closes a quoted scalar whose content starts
    at `at`, or -1 if the scalar goes on past this line."""
    while at < len(text):
        if text[at] == "\\" and quote == '"':
            at += 2
        elif text[at] != quote:
            at += 1
        elif quote == "'" and text[at + 1 : at + 2] == "'":
            at += 2
        else:
            return at + 1
    return -1


def open_quote(text, at=0, state=None):
    """(quote, flow) for the quoted scalar still open at the end of a line, or
    None. `state` is that of a scalar already open where the line starts.

    A quote opens a scalar only where a node starts: after the `- ` entries, after
    a key's `: `, and in a flow collection after `{`, `[`, `,` or `:`. Anywhere
    else it is a character of a plain scalar."""
    quote, flow = state or (None, False)
    key_seen = False
    while True:
        if quote:
            at = quote_end(text, at, quote)
            if at < 0:
                return quote, flow
            quote = None
            if not flow:
                # A quoted key (`"run": ...`) is followed by its value.
                after = KEY_END.match(text, at)
                if not after or key_seen:
                    return None
                key_seen, at = True, after.end()
                continue
        if flow:
            # To the next quote that starts a node of the flow collection.
            opener = FLOW_QUOTE.search(text, at)
            if not opener or COMMENT.search(text, at, opener.start()):
                return None
            quote, at = opener["quote"], opener.end()
            continue
        at = NODE_START.match(text, at).end()
        if text[at : at + 1] in ('"', "'"):
            quote, at = text[at], at + 1
        elif text[at : at + 1] in ("{", "["):
            flow = True
        else:
            # A plain key, then its value; a plain value holds no quoted scalar.
            after = PLAIN_KEY.match(text, at)
            if not after or key_seen:
                return None
            key_seen, at = True, after.end()


def block_scalars(text):
    """Character ranges of scalar content that is not on its key's line: block
    scalars and the later lines of quoted scalars. They hold scripts and other
    embedded text, where a `uses:` line is not a step."""
    spans, parent, start, offset, quoted, previous = [], None, None, 0, None, -1
    for line in lines(text):
        content = line.strip()
        indent = len(line) - len(line.lstrip(" \t"))
        bare = line.rstrip("\r\n")
        if quoted:
            spans.append((offset, offset + len(line)))
            quoted = open_quote(bare, 0, quoted)
            offset += len(line)
            continue
        if parent is not None and content and indent <= parent:
            spans.append((start, offset))
            parent = None
        if parent is None and content and not content.startswith("#"):
            entries = ENTRIES.match(line)[0]
            if BLOCK_SCALAR.search(bare):
                # The scalar's content is indented past the node that holds it: the
                # key after `- ` (so a sibling key of that step ends it), the `-`
                # itself when the entry is the scalar, or the line before when the
                # indicator stands alone on its line.
                item = ITEM_SCALAR.match(line, len(entries))
                if item and "-" not in entries:
                    parent = previous
                else:
                    parent = max(indent, len(entries.rstrip()) - 1 if item else len(entries))
                start = offset + len(line)
            else:
                quoted = open_quote(bare, len(entries))
            previous = len(entries)
        offset += len(line)
    if parent is not None:
        spans.append((start, offset))
    return spans


# A steps: key that opens a block sequence, optionally quoted, anchored or commented.
STEPS_KEY = re.compile(r"""[ \t]*(?:-[ \t]+)?(?P<q>['"]?)steps(?P=q)[ \t]*:[ \t]*(?:[!&]\S*[ \t]*)*(?:#.*)?""")


def step_lines(text, embedded):
    """Offsets of the lines whose block `uses:` key belongs to a step: a key of a
    mapping that is an item of a block sequence under a `steps:` key. A uses:
    key anywhere else (an input, a variable, a matrix entry, a data file) is
    data, not a step. Lines of block and multi-line quoted scalars, blank lines
    and comments are passed over."""
    rows, offset = [], 0
    for line in lines(text):
        content = line.strip()
        inside = any(start <= offset < end for start, end in embedded)
        if content and not content.startswith("#") and not inside:
            rows.append((offset, line.rstrip("\r\n"), len(line) - len(line.lstrip(" "))))
        offset += len(line)
    steps = set()
    for index, (offset, line, indent) in enumerate(rows):
        entries = ENTRIES.match(line)[0]
        if not line[len(entries):].startswith("uses:") and not re.match(r"""(['"])uses\1[ \t]*:""", line[len(entries):]):
            continue
        if entries.count("-") > 1:
            continue
        key = len(entries)
        at = index
        if "-" not in entries:
            # The item that holds this key: the nearest line indented less, which
            # must be a `- ` entry whose first key is at this key's column.
            at = next((i for i in range(index - 1, -1, -1) if rows[i][2] < key), None)
            if at is None:
                continue
            item = ENTRIES.match(rows[at][1])[0]
            if item.count("-") != 1 or len(item) != key:
                continue
        dash = rows[at][2]
        # The sequence's key: the nearest earlier line that is not an item of it.
        parent = next(
            (i for i in range(at - 1, -1, -1) if rows[i][2] < dash or (rows[i][2] == dash and not rows[i][1].lstrip().startswith("-"))),
            None,
        )
        if parent is not None and STEPS_KEY.fullmatch(rows[parent][1]):
            steps.add(offset)
    return steps


def rewrite(text, action_sha):
    if not SHA.fullmatch(action_sha):
        raise ValueError(f"action_sha must be a full commit SHA, got {action_sha!r}")
    action = f"{ACTION_REPO}@{action_sha}"
    hosted = hosted_jobs(text)
    embedded = block_scalars(text)
    steps = step_lines(text, embedded)

    def replace(match):
        if "cachew: keep" in match[0]:
            return match[0]
        pinned = "cachew-checkout@" in match[0].lower()
        if match.start() not in steps:
            # Text a script writes or prints, or data that is not a step of this
            # file: a checkout there is not migrated. A pin to the action is still
            # moved to the current commit, as --verify-pins holds every mention to it.
            return f"{match['prefix']}{action} # cachew checkout" if pinned else match[0]
        if any(start <= match.start() < end for start, end in hosted):
            return f"{match['prefix']}{PLAIN_CHECKOUT}" if pinned else match[0]
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
        if path.suffix.lower() in (".yml", ".yaml"):
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
            # Only spaces and tabs around it are not part of it: str.rstrip() would also
            # drop Unicode spaces (U+00A0, U+2028, ...), which Git allows in branch names.
            end = re.search(r"[ \t]#" + (r"|[,}]" if key["flow"] else ""), line)
            value = line[: end.start() if end else len(line)].rstrip(" \t")
            yield start, start + len(value), value, None


def action_reference(value):
    """How GitHub reads a decoded uses: value that names the action: (legacy,
    subdirectory, ref, problem), or None for any other value. The runner splits
    the part before the @ on / and \\ and drops empty segments, so
    owner//repo\\actions/cachew-checkout is the action too. The ref is everything
    after the @, so a branch, short SHA or padded SHA is compared as written, and
    so is a SHA followed by more characters (`<sha>#x`, `<sha>'x`): Git allows
    those in branch names, so they are mutable refs that only look like the pin."""
    path, at, ref = value.partition("@")
    segments = [segment.lower() for segment in re.split(r"[/\\]", path) if segment]
    expected = ACTION_PATHS.get(tuple(segments[:2]))
    if not at or expected is None:
        return None
    rest = tuple(segments[2:])
    if "." in rest or ".." in rest:
        # They resolve on the runner's disk, to the action's directory or any other.
        return False, False, ref, "its path has . or .. segments"
    if rest[: len(expected)] != expected:
        return None
    return expected is ACTION_PATHS[tuple(LEGACY_REPO.lower().split("/")[:2])], len(rest) > len(expected), ref, None


def unescaped(text):
    def decode(match):
        code = match[1] or match[2] or match[3]
        if code:
            return chr(int(code, 16)) if int(code, 16) < 0x110000 else match[0]
        return "" if match[4] else match[5]

    return ESCAPE.sub(decode, text)


def verify_pins(root, action_sha, exclude=()):
    """Every reference pins exactly action_sha in tenstorrent/.github: no other
    commit, no reference to the old tt-metal location, no subdirectory.
    Whether action_sha exists there is for the caller's CI to check."""
    problems = []
    pins = {}
    # Excluded prefixes are left out; gh-aw lock files are not, since GitHub
    # runs them here although --write leaves them to gh-aw.
    for path in pinned_files(root, exclude):
        try:
            text = (root / path).read_text(encoding="utf-8")
        except (OSError, ValueError) as error:
            problems.append(f"{path}: cannot be read ({error})")
            continue
        read = []
        for start, end, value, problem in uses_values(text):
            line = text.count("\n", 0, start) + 1
            if problem:
                problems.append(f"{path}:{line}: a uses: entry cannot be verified: {problem}; write it as one plain line")
                continue
            reference = action_reference(value)
            if not reference:
                continue
            legacy, subdirectory, ref, problem = reference
            read.append((start, end))
            if problem:
                problems.append(f"{path}:{line} references {value}: {problem}; write {ACTION_REPO}@<sha>")
                continue
            if legacy:
                problems.append(f"{path}:{line} references {value}; the action moved to {ACTION_REPO} (run --write)")
                continue
            if subdirectory:
                problems.append(f"{path}:{line} references {value}; reference the action itself, not a subdirectory")
            pins.setdefault(ref, []).append(path.as_posix())
        # A mention the uses: values above do not account for (a comment, an
        # anchor, a multi-line value) could still be what GitHub runs.
        for match in ANY_PIN.finditer(text):
            if not any(start <= match.start() < end for start, end in read):
                line = text.count("\n", 0, match.start()) + 1
                problems.append(f"{path}:{line} mentions {match[0]} outside a uses: value it can verify")
        # A double-quoted scalar can spell the action with escape sequences
        # (\x65 for e), under a key the reader above does not take for uses:.
        if len(ANY_PIN.findall(unescaped(text))) != len(ANY_PIN.findall(text)):
            problems.append(f"{path} names the action through escape sequences; write it as one plain line")
    for ref in sorted(set(pins) - {action_sha}):
        for name in sorted(set(pins[ref])):
            fix = "set the pin in its .md source and recompile it with gh aw compile" if generated(Path(name)) else "run --write"
            problems.append(f"{name} pins {ref}, expected action_sha {action_sha}; {fix}")
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
    # A path argument is relative to the current directory, as in any command.
    candidates = [Path.cwd() / path for path in args.paths] or tracked_consumers(root, exclude)
    changed, failed = [], False
    for path in candidates:
        try:
            if migrate_file(path, sha, args.write, root, exclude):
                changed.append(path)
        except (OSError, ValueError) as error:
            # One unreadable file (not UTF-8, deleted, outside the repository)
            # must not stop the run midway with the others unvisited.
            failed = True
            print(f"Cannot migrate {path}: {error}", file=sys.stderr)
    for path in changed:
        print(f"{'Migrated' if args.write else 'Needs cachew migration:'} {path}")
    print(f"{len(changed)} file(s) {'updated' if args.write else 'need migration'}.")
    return 1 if failed or (changed and args.check) else 0


if __name__ == "__main__":
    sys.exit(main())

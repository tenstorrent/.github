# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0

"""migrate.py's step finder, checked against a real YAML parser.

migrate.py reads workflows without a YAML library, so consumers need only the
standard library. This test generates workflows in many YAML forms and holds
migrate.py to what PyYAML says each one means:

  * every checkout step of actions/checkout v7.0.1 in a job that is not
    GitHub-hosted is migrated by --write or reported by --check;
  * nothing else is migrated or reported;
  * --write changes no data but those steps' uses: values.

It needs PyYAML and skips without it, unless CACHEW_REQUIRE_PYYAML is set (CI
sets it, so the check cannot silently stop running).
"""

import copy
import importlib.util
import itertools
import os
from pathlib import Path
import re
import unittest

try:
    import yaml
except ImportError:
    yaml = None


ACTION = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("migrate", ACTION / "migrate.py")
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)

SHA = "a" * 40
PIN = f"{migrate.ACTION_REPO}@{SHA}"
CHECKOUT = "actions/checkout@v7.0.1"
MIGRATABLE = re.compile(r"(?i:actions/checkout)@(?:" + "|".join(map(re.escape, migrate.MIGRATABLE_REFS)) + ")")

# One step, or a few lines of a steps sequence, in many YAML forms.
STEPS = {
    "plain": f"- uses: {CHECKOUT}\n",
    "named": f"- name: x\n  uses: {CHECKOUT}\n",
    "single quotes": f"- uses: '{CHECKOUT}'\n",
    "double quotes": f'- uses: "{CHECKOUT}"\n',
    "quoted key": f'- "uses": {CHECKOUT}\n',
    "comment": f"- uses: {CHECKOUT} # v7.0.1\n",
    "tag": f"- uses: !!str {CHECKOUT}\n",
    "anchor": f"- uses: &a {CHECKOUT}\n",
    "value on the next line": f"- uses:\n    {CHECKOUT}\n",
    "escape": '- uses: "actions/checkout@v7.\\x30.1"\n',
    "folded": f"- uses: >-\n    {CHECKOUT}\n",
    "flow mapping": f"- {{uses: {CHECKOUT}}}\n",
    "flow mapping, quoted comma": f'- {{name: "a, b}}", uses: {CHECKOUT}}}\n',
    "flow mapping over lines": f"- {{name: a,\n   uses: {CHECKOUT}}}\n",
    "flow mapping, key on its own line": f"- {{\n    uses: {CHECKOUT}\n  }}\n",
    "explicit key": f"- ? uses\n  : {CHECKOUT}\n",
    "space before colon": f"- uses : {CHECKOUT}\n",
    "wide entry": f"-   uses: {CHECKOUT}\n",
    "bare dash": f"-\n  uses: {CHECKOUT}\n",
    "comment after dash": f"- # first\n  uses: {CHECKOUT}\n",
    "anchored item": f"- &s\n  uses: {CHECKOUT}\n",
    "tagged item": f"- !!map\n  uses: {CHECKOUT}\n",
    "anchored key": f"- &s uses: {CHECKOUT}\n",
    "with after": f"- uses: {CHECKOUT}\n  with:\n    ref: main\n",
    "capitalized": "- uses: Actions/Checkout@v7.0.1\n",
    "commit": f"- uses: actions/checkout@{migrate.FORWARDED_CHECKOUT}\n",
    "another version": "- uses: actions/checkout@v4\n",
    "a longer version": "- uses: actions/checkout@v7.0.10\n",
    "after a multi-line plain name": f"- name: a\n    b\n  uses: {CHECKOUT}\n",
    "after a multi-line quoted name": f'- name: "a\n    b"\n  uses: {CHECKOUT}\n',
    "after a block scalar": f"- run: |\n    echo\n  uses: {CHECKOUT}\n",
    "after a flow mapping over lines": f"- with: {{a: 1,\n    b: 2}}\n  uses: {CHECKOUT}\n",
    "after a blank line and a comment": f"- name: x\n\n  # c\n  uses: {CHECKOUT}\n",
    # Text that only looks like a step.
    "script": f"- run: |\n    - uses: {CHECKOUT}\n",
    "single-quoted script over lines": f"- run: 'echo\n    - uses: {CHECKOUT}'\n",
    "double-quoted script over lines": f'- run: "echo\n    - uses: {CHECKOUT}"\n',
    "an input": f"- uses: foo/bar@v1\n  with:\n    uses: {CHECKOUT}\n",
    "quoted text": f"- run: 'uses: {CHECKOUT}'\n",
    "quoted steps text": f"- run: 'steps: [{{uses: {CHECKOUT}}}]'\n",
    "a comment": f"# - uses: {CHECKOUT}\n- run: x\n",
    "a flow input": f"- {{uses: foo/bar@v1, with: {{uses: {CHECKOUT}}}}}\n",
    "a nested sequence": f"- - uses: {CHECKOUT}\n",
}

RUNS_ON = {
    "self-hosted": "self-hosted",
    "labels": "[self-hosted, linux]",
    "hosted": "ubuntu-latest",
    "quoted hosted": '"ubuntu-22.04"',
    "hosted sequence": "[ubuntu-latest]",
    "expression": "${{ matrix.os }}",
    "hosted block sequence": "\n      - ubuntu-latest",
    "mixed": "[ubuntu-latest, self-hosted]",
    "group": "{group: big}",
    "anchored hosted": "&r ubuntu-latest",
    "hosted with a comment": "ubuntu-latest # c",
}


def indent(block, width):
    return "".join(" " * width + line if line.strip() else line for line in block.splitlines(True))


def workflows():
    """(name, text, kept): kept when every checkout in it carries # cachew: keep."""
    for (step, item), (runner, runs_on) in itertools.product(STEPS.items(), RUNS_ON.items()):
        yield f"{step}, {runner}", f"on: push\njobs:\n  a:\n    runs-on: {runs_on}\n    steps:\n{indent(item, 6)}", False
    for runner, runs_on in RUNS_ON.items():
        one_line = "\n" not in runs_on and "#" not in runs_on and "{" not in runs_on
        job = f"jobs:\n  a:\n    runs-on: {runs_on}\n"
        yield f"flow sequence, {runner}", f"{job}    steps: [{{uses: {CHECKOUT}}}]\n", False
        yield f"steps before runs-on, {runner}", f"jobs:\n  a:\n    steps:\n      - uses: {CHECKOUT}\n    runs-on: {runs_on}\n", False
        yield f"quoted job, {runner}", job.replace("  a:", "  'a':") + f"    steps:\n      - uses: {CHECKOUT}\n", False
        yield f"quoted steps key, {runner}", f"{job}    'steps':\n      - uses: {CHECKOUT}\n", False
        yield f"anchored steps, {runner}", f"{job}    steps: &x\n      - uses: {CHECKOUT}\n", False
        yield f"document start, {runner}", f"---\n{job}    steps:\n      - uses: {CHECKOUT}\n", False
        yield f"commented runs-on before, {runner}", job.replace("    runs-on", "    # runs-on: ubuntu-latest\n    runs-on") + f"    steps:\n      - uses: {CHECKOUT}\n", False
        yield (
            f"after a hosted job, {runner}",
            f"jobs:\n  h:\n    runs-on: ubuntu-latest\n    steps:\n      - run: x\n{job[6:]}    steps:\n      - uses: {CHECKOUT}\n",
            False,
        )
        # Steps an alias runs in another job, either way round.
        yield (
            f"aliased step from a hosted job, {runner}",
            f"jobs:\n  h:\n    runs-on: ubuntu-latest\n    steps:\n      - &co\n        uses: {CHECKOUT}\n"
            f"{job[6:]}    steps:\n      - *co\n",
            False,
        )
        yield (
            f"aliased steps from a hosted job, {runner}",
            f"jobs:\n  h:\n    runs-on: ubuntu-latest\n    steps: &st\n      - uses: {CHECKOUT}\n{job[6:]}    steps: *st\n",
            False,
        )
        yield (
            f"aliased step into a hosted job, {runner}",
            f"{job}    steps:\n      - &co\n        uses: {CHECKOUT}\n  h:\n    runs-on: ubuntu-latest\n    steps:\n      - *co\n",
            False,
        )
        yield (
            f"aliased script step, {runner}",
            f"jobs:\n  h:\n    runs-on: ubuntu-latest\n    steps:\n      - &s\n        run: echo {CHECKOUT}\n"
            f"{job[6:]}    steps:\n      - *s\n",
            False,
        )
        yield (
            f"kept aliased step, {runner}",
            f"jobs:\n  h:\n    runs-on: ubuntu-latest\n    steps:\n      - &co\n        uses: {CHECKOUT}\n"
            f"{job[6:]}    steps:\n      - *co # cachew: keep\n",
            True,
        )
        yield f"kept, {runner}", f"{job}    steps:\n      - uses: {CHECKOUT} # cachew: keep\n", True
        if one_line:
            flow = f"{{runs-on: {runs_on}, steps: [{{uses: {CHECKOUT}}}]}}"
            hosted = "{runs-on: ubuntu-latest, steps: [{run: x}]}"
            yield f"flow job, {runner}", f"jobs:\n  a: {flow}\n", False
            yield f"flow jobs, hosted first, {runner}", f"jobs: {{h: {hosted}, a: {flow}}}\n", False
            yield f"flow jobs, hosted last, {runner}", f"jobs: {{a: {flow}, h: {hosted}}}\n", False
            yield f"block-indented flow job, {runner}", f"jobs:\n    a:\n        runs-on: {runs_on}\n        steps:\n        -   uses: {CHECKOUT}\n", False
        if "{" in runs_on or "#" in runs_on:
            continue
        yield (
            f"flow job over lines, {runner}",
            "jobs: {\n  a: {\n    runs-on: " + runs_on.replace("\n", " ").replace("- ", "[", 1).rstrip() + ("]" if "\n" in runs_on else "")
            + f", # c\n    steps: [\n      {{uses: {CHECKOUT}}}\n    ]\n  }}\n}}\n",
            False,
        )
    yield "composite action", f"runs:\n  using: composite\n  steps:\n    - uses: {CHECKOUT}\n", False


def hosted(runs_on):
    labels = runs_on if isinstance(runs_on, list) else [runs_on]
    return bool(labels) and all(isinstance(label, str) and migrate.HOSTED_LABEL.fullmatch(label) for label in labels)


def checkout_steps(text):
    """(hosted, uses key node, uses value node, lines) for each step uses: of
    each job, as PyYAML reads text. lines are those where a report may name the
    step: its uses: key, and any line of its job that holds an alias."""
    root = yaml.compose(text, Loader=yaml.SafeLoader)
    if not isinstance(root, yaml.MappingNode):
        return []
    top = {key.value: value for key, value in root.value if isinstance(key, yaml.ScalarNode)}
    jobs = [value for _, value in top["jobs"].value] if isinstance(top.get("jobs"), yaml.MappingNode) else []
    if isinstance(top.get("runs"), yaml.MappingNode):
        jobs.append(top["runs"])
    loader = yaml.SafeLoader("")
    rows = text.split("\n")
    found = []
    for job in jobs:
        if not isinstance(job, yaml.MappingNode):
            continue
        keys = {key.value: value for key, value in job.value if isinstance(key, yaml.ScalarNode)}
        runs_on = keys.get("runs-on")
        job_hosted = runs_on is not None and hosted(loader.construct_object(runs_on, deep=True))
        aliases = {n + 1 for n in range(job.start_mark.line, job.end_mark.line + 1) if n < len(rows) and "*" in rows[n]}
        steps = keys.get("steps")
        for step in steps.value if isinstance(steps, yaml.SequenceNode) else []:
            for key, value in step.value if isinstance(step, yaml.MappingNode) else []:
                if isinstance(key, yaml.ScalarNode) and key.value == "uses" and isinstance(value, yaml.ScalarNode):
                    found.append((job_hosted, key, value, {key.start_mark.line + 1} | aliases))
    return found


def problems(text, kept):
    """What migrate.py gets wrong about one workflow, as migrate_file reads it."""
    try:
        before = yaml.safe_load(text)
        expected = [
            lines
            for job_hosted, _, value, lines in checkout_steps(text)
            if MIGRATABLE.fullmatch(value.value) and not job_hosted and not kept
        ]
    except yaml.YAMLError as error:
        return [f"the test made invalid YAML: {error}"]
    written = migrate.rewrite(text, SHA)
    reported = set(migrate.flow_steps(text)) | set(migrate.hidden_checkouts(written))
    try:
        after = yaml.safe_load(written)
        migrated = {key.start_mark.line + 1 for _, key, value, _ in checkout_steps(written) if value.value == PIN}
    except yaml.YAMLError as error:
        return [f"--write made invalid YAML: {error}"]
    found = []
    allowed = set().union(*expected) if expected else set()
    for lines in expected:
        if not lines & (migrated | reported):
            found.append(f"a checkout step at line {min(lines)} is neither migrated nor reported")
    found += [f"line {line} is reported but holds no checkout step" for line in sorted(reported - allowed)]
    found += [f"line {line} is migrated but holds no checkout step" for line in sorted(migrated - allowed)]

    # Data: what --write wrote, with only migrated steps' uses: values changed.
    def migrate_uses(old, new):
        if isinstance(old, dict) and isinstance(new, dict):
            for key in old:
                if key == "uses" and isinstance(old[key], str) and MIGRATABLE.fullmatch(old[key]) and new.get(key) == PIN:
                    old[key] = PIN
                elif key in new:
                    migrate_uses(old[key], new[key])
        elif isinstance(old, list) and isinstance(new, list):
            for old_item, new_item in zip(old, new):
                migrate_uses(old_item, new_item)

    want = copy.deepcopy(before)
    migrate_uses(want, after)
    if want != after:
        found.append("--write changed data other than a checkout step's uses:")
    return found


@unittest.skipUnless(yaml or os.environ.get("CACHEW_REQUIRE_PYYAML"), "needs PyYAML (pip install pyyaml)")
class ParserAgreementTests(unittest.TestCase):
    def test_migrate_finds_the_checkout_steps_a_yaml_parser_finds(self):
        self.assertIsNotNone(yaml, "CACHEW_REQUIRE_PYYAML is set but PyYAML is not installed")
        cases = list(workflows())
        # Not vacuous: most cases hold a checkout to migrate or report.
        self.assertGreater(len(cases), 500)
        with_checkouts = sum(
            1
            for _, text, kept in cases
            if not kept and any(MIGRATABLE.fullmatch(v.value) and not h for h, _, v, _ in checkout_steps(text))
        )
        self.assertGreater(with_checkouts, 200)
        for name, text, kept in cases:
            with self.subTest(name, text=text):
                self.assertEqual(problems(text, kept), [])


if __name__ == "__main__":
    unittest.main()

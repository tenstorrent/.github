# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0

"""The consumer migration helper: which checkouts move to the pinned action."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ACTION = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("migrate", ACTION / "migrate.py")
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)

SHA = "a" * 40
PLAIN = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1"
PINNED = f"tenstorrent/.github/actions/cachew-checkout@{SHA} # cachew checkout"
STALE = "tenstorrent/.github/actions/cachew-checkout@" + "0" * 40 + " # cachew checkout"
LEGACY = "tenstorrent/tt-metal/.github/actions/cachew-checkout@" + "1" * 40 + " # cachew checkout"


class RewriteTests(unittest.TestCase):
    def test_a_quoted_or_anchored_job_key_still_ends_the_job_before_it(self):
        # Unseen, the hosted job's runs-on counted for the self-hosted job too,
        # and --write turned that job's pin back into plain checkout.
        for key in ('"lint":', "lint: &lint", "'lint':  # comment"):
            before = f"""jobs:
  self:
    runs-on: [self-hosted, linux]
    steps:
      - uses: {PINNED}
      - uses: {PLAIN}
  {key}
    runs-on: ubuntu-latest
    steps:
      - uses: {PLAIN}
"""
            after = before.replace(f"- uses: {PLAIN}", f"- uses: {PINNED}", 1)
            with self.subTest(key=key):
                self.assertEqual(migrate.rewrite(before, SHA), after)

    def test_self_hosted_jobs_move_to_the_pinned_action_and_hosted_jobs_keep_checkout(self):
        before = f"""on: push
jobs:
  build:
    runs-on: tt-ubuntu-2204-large-stable
    steps:
      - uses: {PLAIN}
  matrix:
    runs-on: >-
      ${{{{ inputs.label }}}}
    steps:
      - uses: {STALE}
  hosted:
    runs-on: ubuntu-22.04
    steps:
      - uses: {PLAIN}
      - uses: {STALE}
  arm:
    runs-on: "ubuntu-24.04-arm"
    steps:
      - uses: {PINNED}
  kept:
    runs-on: tt-ubuntu-2204-large-stable
    steps:
      - uses: {PLAIN} cachew: keep
"""
        expected = f"""on: push
jobs:
  build:
    runs-on: tt-ubuntu-2204-large-stable
    steps:
      - uses: {PINNED}
  matrix:
    runs-on: >-
      ${{{{ inputs.label }}}}
    steps:
      - uses: {PINNED}
  hosted:
    runs-on: ubuntu-22.04
    steps:
      - uses: {PLAIN}
      - uses: {PLAIN}
  arm:
    runs-on: "ubuntu-24.04-arm"
    steps:
      - uses: {PLAIN}
  kept:
    runs-on: tt-ubuntu-2204-large-stable
    steps:
      - uses: {PLAIN} cachew: keep
"""
        self.assertEqual(migrate.rewrite(before, SHA), expected)

    def test_uses_lines_inside_a_script_are_text_not_steps(self):
        def workflow(step, embedded_pin, hosted_pin):
            return (
                "jobs:\n  build:\n    runs-on: [self-hosted]\n    steps:\n"
                f"      - uses: {step}\n"
                "      - name: Write another workflow\n"
                "        run: |\n"
                "          cat > generated.yml <<'EOF'\n"
                "          jobs:\n"
                "            lint:\n"
                "              runs-on: ubuntu-latest\n"
                "              steps:\n"
                f"                - uses: {PLAIN}\n"
                "\n"
                f"                - uses: {embedded_pin}\n"
                "          EOF\n"
                "      - run: >-\n"
                f"          echo uses: {PLAIN}\n"
                f"      - uses: {step}\n"
                "  hosted:\n    runs-on: ubuntu-latest\n    steps:\n"
                "      - run: |  # keep\n"
                f"          - uses: {hosted_pin}\n"
                f"      - uses: {PLAIN}\n"
            )

        self.assertEqual(migrate.rewrite(workflow(PLAIN, STALE, STALE), SHA), workflow(PINNED, PINNED, PINNED))

    def test_the_exact_version_is_migrated_however_its_owner_and_name_are_cased(self):
        # GitHub resolves Actions/Checkout as actions/checkout.
        before = "runs:\n  steps:\n    - uses: Actions/Checkout@v7.0.1\n    - uses: actions/checkout@v7.0.10\n"
        after = f"runs:\n  steps:\n    - uses: {PINNED}\n    - uses: actions/checkout@v7.0.10\n"
        self.assertEqual(migrate.rewrite(before, SHA), after)

    def test_composite_actions_are_migrated_unless_kept(self):
        before = f"runs:\n  using: composite\n  steps:\n    - uses: {PLAIN}\n    - uses: {PLAIN} cachew: keep\n"
        expected = f"runs:\n  using: composite\n  steps:\n    - uses: {PINNED}\n    - uses: {PLAIN} cachew: keep\n"
        self.assertEqual(migrate.rewrite(before, SHA), expected)

    def test_pins_to_the_old_tt_metal_location_move_here(self):
        before = f"""jobs:
  build:
    runs-on: tt-ubuntu-2204-large-stable
    steps:
      - uses: {LEGACY}
  hosted:
    runs-on: ubuntu-22.04
    steps:
      - uses: {LEGACY}
"""
        expected = f"""jobs:
  build:
    runs-on: tt-ubuntu-2204-large-stable
    steps:
      - uses: {PINNED}
  hosted:
    runs-on: ubuntu-22.04
    steps:
      - uses: {PLAIN}
"""
        self.assertEqual(migrate.rewrite(before, SHA), expected)

    def test_other_checkout_versions_are_left_alone(self):
        # Floating tags too: v7 may point past the v7.0.1 the action forwards to.
        text = "steps:\n  - uses: actions/checkout@v4\n  - uses: actions/checkout@main\n  - uses: actions/checkout@v7\n"
        self.assertEqual(migrate.rewrite(text, SHA), text)

    def test_rewrite_refuses_a_short_sha(self):
        with self.assertRaises(ValueError):
            migrate.rewrite("", "abc123")

    def test_forwarded_checkout_matches_the_action(self):
        pins = re.findall(r"uses: actions/checkout@([0-9a-f]{40})", (ACTION / "action.yml").read_text())
        self.assertEqual(set(pins), {migrate.FORWARDED_CHECKOUT})


class RepositoryTests(unittest.TestCase):
    """migrate.py run against a throwaway consumer repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.files = {
            ".github/workflows/ci.yml": f"jobs:\n  build:\n    runs-on: self-hosted\n    steps:\n      - uses: {PLAIN}\n",
            ".github/actions/setup/action.yml": f"runs:\n  using: composite\n  steps:\n    - uses: {LEGACY}\n",
            "vendored/.github/workflows/ci.yml": f"jobs:\n  build:\n    runs-on: self-hosted\n    steps:\n      - uses: {PLAIN}\n",
            ".github/workflows/agent.lock.yml": f"jobs:\n  a:\n    runs-on: self-hosted\n    steps:\n      - uses: {PLAIN}\n",
            "docs/example.yml": f"- uses: {PLAIN}\n",
        }
        for name, text in self.files.items():
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text(text)
        self.write_config({"action_sha": SHA, "exclude": ["vendored/"]})
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def write_config(self, data):
        (self.root / ".github/cachew-checkout.json").write_text(json.dumps(data))

    def run_main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = migrate.main(["--root", str(self.root), *args])
        return code, out.getvalue()

    def read(self, name):
        return (self.root / name).read_text()

    def test_check_write_and_verify(self):
        code, out = self.run_main("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("2 file(s) need migration", out)
        code, out = self.run_main("--verify-pins")
        self.assertEqual(code, 1)
        self.assertIn("the action moved to", out)

        self.assertEqual(self.run_main("--write")[0], 0)
        self.assertIn(PINNED, self.read(".github/workflows/ci.yml"))
        self.assertIn(PINNED, self.read(".github/actions/setup/action.yml"))
        # Excluded prefix, gh-aw lock file and files outside .github/{actions,workflows}.
        for name in ("vendored/.github/workflows/ci.yml", ".github/workflows/agent.lock.yml", "docs/example.yml"):
            self.assertEqual(self.read(name), self.files[name], name)

        self.assertEqual(self.run_main("--check")[0], 0)
        self.assertEqual(self.run_main("--verify-pins")[0], 0)

    def test_action_sha_with_write_repins_and_saves_the_config(self):
        self.run_main("--write")
        new = "b" * 40
        self.assertEqual(self.run_main("--write", "--action-sha", new)[0], 0)
        self.assertIn(f"cachew-checkout@{new}", self.read(".github/workflows/ci.yml"))
        self.assertEqual(json.loads(self.read(".github/cachew-checkout.json"))["action_sha"], new)
        self.assertEqual(self.run_main("--verify-pins")[0], 0)

    def test_verify_pins_reports_a_pin_other_than_the_config(self):
        self.run_main("--write")
        code, out = self.run_main("--verify-pins", "--action-sha", "c" * 40)
        self.assertEqual(code, 1)
        self.assertIn("expected only action_sha", out)
        # Without --write, --action-sha does not touch the config.
        self.assertEqual(json.loads(self.read(".github/cachew-checkout.json"))["action_sha"], SHA)

    def test_verify_pins_compares_the_whole_ref(self):
        self.run_main("--write")
        workflow = self.root / ".github/workflows/ci.yml"
        good = workflow.read_text()
        for ref in ("main", SHA[:7], SHA + "0"):
            workflow.write_text(good.replace(f"@{SHA}", f"@{ref}"))
            code, out = self.run_main("--verify-pins")
            self.assertEqual(code, 1, ref)
            self.assertIn(ref, out)

    def test_verify_pins_reads_the_whole_uses_value(self):
        # Git allows #, ' and " in branch names, so a SHA followed by any of them
        # is a mutable ref, and the parts of a value YAML joins must be read whole.
        self.run_main("--write")
        workflow = self.root / ".github/workflows/ci.yml"
        good = workflow.read_text()
        action = "tenstorrent/.github/actions/cachew-checkout"
        line = f"- uses: {PINNED}"
        for bad in (
            f"- uses: {action}@{SHA}#x",
            f"- uses: \"{action}@{SHA}#x\"",
            f"- uses: \"{action}@{SHA}'x\"",
            f"- uses: '{action}@{SHA}\"x'",
            f"- {{uses: {action}@main, with: {{a: b}}}}",
            f"- uses: \"tenstorrent/.github/actions/cachew-checkou\\x74@main\"",
            f"- uses: >-\n          {action}@main",
            f"- uses: *pin",
            f"- uses: \"{action}@\\\n          main\"",
        ):
            with self.subTest(bad=bad):
                workflow.write_text(good.replace(line, bad))
                code, out = self.run_main("--verify-pins")
                self.assertEqual(code, 1, out)
        for fine in (f"- uses: '{action}@{SHA}'", f'- uses: "{action}@{SHA}"', f"- {{uses: {action}@{SHA}}}"):
            with self.subTest(fine=fine):
                workflow.write_text(good.replace(line, fine))
                code, out = self.run_main("--verify-pins")
                self.assertEqual(code, 0, out)

    def test_verify_pins_reads_the_action_path_as_the_runner_does(self):
        # The runner splits owner/repo/path on / and \\ and drops empty segments,
        # and . or .. segments resolve on its disk.
        self.run_main("--write")
        workflow = self.root / ".github/workflows/ci.yml"
        good = workflow.read_text()
        line = f"- uses: {PINNED}"
        spellings = (
            "tenstorrent/.github//actions/cachew-checkout",
            "tenstorrent//.github/actions/cachew-checkout",
            "tenstorrent/.github/./actions/cachew-checkout",
            "tenstorrent/.github/actions/../actions/cachew-checkout",
            "tenstorrent/.github\\actions\\cachew-checkout",
            "tenstorrent\\.github\\actions\\cachew-checkout",
            "tenstorrent/tt-metal//.github/actions/cachew-checkout",
        )
        for spelling in spellings:
            with self.subTest(spelling=spelling):
                workflow.write_text(good.replace(line, f"- uses: {spelling}@main"))
                code, out = self.run_main("--verify-pins")
                self.assertEqual(code, 1, out)
        # The same action at the pin passes, and so does another action of the repository.
        for fine in (f"tenstorrent/.github//actions/cachew-checkout@{SHA}", "tenstorrent/.github/actions/other@main"):
            with self.subTest(fine=fine):
                workflow.write_text(good.replace(line, f"- uses: {fine}"))
                code, out = self.run_main("--verify-pins")
                self.assertEqual(code, 0, out)

    def test_verify_pins_sees_the_action_spelled_with_escapes_under_any_key(self):
        self.run_main("--write")
        workflow = self.root / ".github/workflows/ci.yml"
        good = workflow.read_text()
        line = f"- uses: {PINNED}"
        value = '"tenstorrent/.github/actions/cachew-ch\\x65ckout@main"'
        for bad in (
            f'- "us\\x65s": {value}',
            f"- ? uses\n        : {value}",
            f"- !!str uses: {value}",
            f"- &k uses: {value}",
            f'- "us\\x65s": "tenstorrent/.github/actions/cachew-checkout\\u0040main"',
            f'- "us\\x65s": "tenstorrent/.github/actions/cachew-\\\n          checkout@main"',
        ):
            with self.subTest(bad=bad):
                workflow.write_text(good.replace(line, bad))
                code, out = self.run_main("--verify-pins")
                self.assertEqual(code, 1, out)
        # Escapes that spell nothing of the action are no concern of the gate.
        workflow.write_text(good + '      - run: "printf \'a\\x41\\tb\'"\n')
        code, out = self.run_main("--verify-pins")
        self.assertEqual(code, 0, out)

    def test_verify_pins_reads_composite_actions_anywhere(self):
        self.run_main("--write")
        action = self.root / "tools/ci/action.yml"
        action.parent.mkdir(parents=True)
        action.write_text("runs:\n  using: composite\n  steps:\n    - uses: tenstorrent/.github/actions/cachew-checkout@main\n")
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        code, out = self.run_main("--verify-pins")
        self.assertEqual(code, 1, out)
        self.assertIn("main", out)

    def test_verify_pins_sees_references_in_any_owner_and_repository_case(self):
        # GitHub resolves owner/repo case-insensitively, so this is the same action on a branch.
        self.run_main("--write")
        workflow = self.root / ".github/workflows/ci.yml"
        workflow.write_text(
            workflow.read_text().replace(
                f"tenstorrent/.github/actions/cachew-checkout@{SHA}", "Tenstorrent/.GitHub/actions/cachew-checkout@main"
            )
        )
        code, out = self.run_main("--verify-pins")
        self.assertEqual(code, 1, out)
        self.assertIn("main", out)

    def test_files_write_leaves_alone_are_not_held_to_its_pin(self):
        lock = self.root / ".github/workflows/agent.lock.yml"
        lock.write_text(lock.read_text().replace(PLAIN, f"tenstorrent/.github/actions/cachew-checkout@{'d' * 40}"))
        self.assertEqual(self.run_main("--write", "--action-sha", "b" * 40)[0], 0)
        self.assertIn("@" + "d" * 40, lock.read_text())
        code, out = self.run_main("--verify-pins")
        self.assertEqual(code, 0, out)

    def test_bad_config_is_reported(self):
        for data, message in (({"action_sha": "main"}, "full 40-character"), ({"action_sha": SHA, "exclude": "x"}, "list of path prefixes")):
            self.write_config(data)
            code, out = self.run_main("--check")
            self.assertEqual(code, 2)
            self.assertIn(message, out)
        (self.root / ".github/cachew-checkout.json").unlink()
        code, out = self.run_main("--check")
        self.assertEqual(code, 2)
        self.assertIn("not found", out)


if __name__ == "__main__":
    unittest.main()

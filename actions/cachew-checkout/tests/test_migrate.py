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
PLAIN = "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2"
PINNED = f"tenstorrent/.github/actions/cachew-checkout@{SHA} # cachew checkout"
STALE = "tenstorrent/.github/actions/cachew-checkout@" + "0" * 40 + " # cachew checkout"
LEGACY = "tenstorrent/tt-metal/.github/actions/cachew-checkout@" + "1" * 40 + " # cachew checkout"


class RewriteTests(unittest.TestCase):
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
        text = "steps:\n  - uses: actions/checkout@v4\n  - uses: actions/checkout@main\n"
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

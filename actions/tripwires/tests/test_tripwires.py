# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ACTION = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ACTION))
import tripwires  # noqa: E402
from tripwires import Unsupported, Violation  # noqa: E402


class InjectionChecks(unittest.TestCase):
    def test_a_leading_dash_is_an_option(self):
        self.assertEqual(tripwires.no_option("main"), "main")
        self.assertEqual(tripwires.no_option("feature-x"), "feature-x")
        for value in ("-x", "--upload-pack=touch /tmp/pwned", "-"):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.no_option(value)

    def test_a_control_character_breaks_a_single_line(self):
        self.assertEqual(tripwires.single_line("a bé"), "a bé")
        for value in ("a\nB=c", "a\rb", "a\x00b", "a\tb", "a\x7fb", "a\x1b[0m"):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.single_line(value)

    def test_shell_metacharacters_fire(self):
        for value in ("owner/name", "v1.2.3", "user@host:path", "a=b,c+d%"):
            with self.subTest(value=value):
                self.assertEqual(tripwires.shell_safe(value), value)
        for value in ("a;b", "$(id)", "`id`", "a b", "a|b", "a&b", "a>b", "'", '"', "a\\b", "a\nb", "*", "~", "café"):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.shell_safe(value)

    def test_a_relative_path_stays_below_its_directory(self):
        for value in ("a", "a/b.c", "a//b", "./a", ""):
            with self.subTest(value=value):
                self.assertEqual(tripwires.relative_path(value), value)
        for value in ("/etc/passwd", "..", "a/../b", "a/..", "a\\b", "a\nb", "a\x00b"):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.relative_path(value)
        self.assertEqual(tripwires.relative_path("a/.git/config"), "a/.git/config")
        with self.assertRaises(Violation):
            tripwires.relative_path("a/.git/config", forbidden=(".git",))
        # A component, not a substring.
        self.assertEqual(tripwires.relative_path("a/.github", forbidden=(".git",)), "a/.github")

    def test_inside_follows_symlinks_out_of_the_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            base, outside = Path(temporary, "base"), Path(temporary, "outside")
            base.mkdir()
            outside.mkdir()
            (base / "link").symlink_to(outside)
            (base / "loop").symlink_to(base)
            resolved = base.resolve()
            self.assertEqual(tripwires.inside(base, ""), resolved)
            self.assertEqual(tripwires.inside(base, "new/child"), resolved / "new" / "child")
            self.assertEqual(tripwires.inside(base, "loop/child"), resolved / "child")
            self.assertEqual(tripwires.inside(base, "a/../b"), resolved / "b")
            for path in ("..", "../outside", "link", "link/child", str(outside), "/", "a/../../outside"):
                with self.subTest(path=path), self.assertRaises(Violation):
                    tripwires.inside(base, path)
            # A sibling whose name starts with the base's name is not inside it.
            Path(temporary, "base-2").mkdir()
            with self.assertRaises(Violation):
                tripwires.inside(base, "../base-2")

    def test_a_plain_path_carries_no_second_request(self):
        self.assertEqual(tripwires.plain_path("owner/name.git"), "owner/name.git")
        for value in ("owner/name?x=1", "owner/name#f", "owner/%2e%2e/name", "owner/name\n", "owner name", "o/n;x", "o/café"):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.plain_path(value)


class Origins(unittest.TestCase):
    def test_an_origin_is_spelled_as_a_browser_spells_it(self):
        cases = {
            "https://github.com": "https://github.com",
            "https://GitHub.com/": "https://github.com",
            "https://github.com:443": "https://github.com",
            "https://github.com:8443": "https://github.com:8443",
            "https://[::1]": "https://[::1]",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(tripwires.origin(value), expected)

    def test_a_harmless_url_that_is_more_than_an_origin_is_unsupported(self):
        for value in (
            "http://github.com",
            "https://user@github.com",
            "https://user:secret@github.com",
            "https://github.com/path",
            "https://github.com?q",
            "https://github.com#f",
            "https://github.com:99999",
            "https://",
            "github.com",
            "",
            "ssh://github.com",
            "http://127.0.0.1:8080",
        ):
            with self.subTest(value=value), self.assertRaises(Unsupported):
                tripwires.origin(value)

    def test_loopback_http_is_only_for_fixtures(self):
        self.assertEqual(tripwires.origin("http://127.0.0.1:8080", loopback_http=True), "http://127.0.0.1:8080")
        self.assertEqual(tripwires.origin("http://localhost", loopback_http=True), "http://localhost")
        with self.assertRaises(Unsupported):
            tripwires.origin("http://example.com", loopback_http=True)

    def test_a_host_with_metacharacters_fires_whatever_else_the_url_holds(self):
        for value in (
            "https://github.com;id",
            "https://$(id).example.com",
            "https://a`id`b",
            "https://a b",
            "https://a'b/path?query",
            'https://a"b',
            "https://user@a|b",
            "http://a&b",
            "https://a\\b",
            "https://exa／mple.com",
            "ssh://a;b/path",
        ):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.origin(value)

    def test_the_message_names_the_label_and_never_the_value(self):
        with self.assertRaises(Violation) as raised:
            tripwires.origin("https://$(id)", "server URL")
        self.assertEqual(str(raised.exception), "server URL host contains shell or configuration metacharacters")


class ExfiltrationChecks(unittest.TestCase):
    TRUSTED = ("https://vault.example.com", "https://cache.example.com:8443")

    def test_a_trusted_origin_in_any_spelling_passes(self):
        for value in ("https://vault.example.com", "https://VAULT.example.com:443/", "https://cache.example.com:8443"):
            with self.subTest(value=value):
                self.assertIn(tripwires.trusted_origin(value, self.TRUSTED), self.TRUSTED)

    def test_anywhere_else_would_have_received_the_secret(self):
        for value in (
            "https://example.com",
            "https://vault.example.com.evil.test",
            "https://vault.example.com@evil.test",
            "https://evil.test/https://vault.example.com",
            "https://vault.example.com:8443",
            "http://vault.example.com",
            "https://vault.example.com/v1",
            "https://user@vault.example.com",
            "https://vault.example.com.",
            "vault.example.com",
            "https://$(id)",
        ):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.trusted_origin(value, self.TRUSTED)

    def test_the_message_names_the_secret(self):
        with self.assertRaises(Violation) as raised:
            tripwires.trusted_origin("https://evil.test", self.TRUSTED, "vault-url", "the job's OIDC token")
        self.assertEqual(
            str(raised.exception), "vault-url is not a trusted origin and would have received the job's OIDC token"
        )

    def test_a_trusted_list_must_hold_origins(self):
        with self.assertRaises(Unsupported):
            tripwires.trusted_origin("https://a.test", ("https://a.test/path",))

    def test_events_that_outside_code_controls_fire(self):
        for event in ("push", "pull_request", "schedule", "workflow_dispatch", ""):
            self.assertEqual(tripwires.untrusted_event(event), event)
        for event in ("pull_request_target", "workflow_run"):
            with self.subTest(event=event), self.assertRaises(Violation):
                tripwires.untrusted_event(event)
        with self.assertRaises(Violation):
            tripwires.untrusted_event("issue_comment", refused=("issue_comment",))


def token(claims):
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    return f"{part({'alg': 'RS256'})}.{part(claims)}.signature"


class OidcChecks(unittest.TestCase):
    CLAIMS = {"iss": tripwires.OIDC_ISSUER, "aud": "https://vault.example.com", "repository": "Owner/Name"}

    def test_the_request_url_is_on_a_github_host(self):
        for value in (
            "https://pipelines.actions.githubusercontent.com/abc/_apis/pipelines/1/runs/2?api-version=2.0",
            "https://run-actions-1-azure-eastus.ACTIONS.githubusercontent.com:443/x",
        ):
            self.assertEqual(tripwires.oidc_request_url(value), value)
        self.assertEqual(tripwires.oidc_request_url("https://ghe.example.com/_services/token", hosts=("ghe.example.com",)), "https://ghe.example.com/_services/token")
        for value in (
            "https://evil.test/?x=.actions.githubusercontent.com",
            "https://actions.githubusercontent.com.evil.test/",
            "https://evilactions.githubusercontent.com.evil.test/",
            "http://pipelines.actions.githubusercontent.com/",
            "https://user@pipelines.actions.githubusercontent.com/",
            "https://pipelines.actions.githubusercontent.com:8443/",
            "https://pipelines.actions.githubusercontent.com@evil.test/",
            "https://[::1",
            "pipelines.actions.githubusercontent.com",
        ):
            with self.subTest(value=value), self.assertRaises(Violation):
                tripwires.oidc_request_url(value)

    def test_claims_this_job_asked_for_pass(self):
        claims = tripwires.oidc_claims(token(self.CLAIMS), "https://vault.example.com", "owner/name")
        self.assertEqual(claims["repository"], "Owner/Name")
        several = dict(self.CLAIMS, aud=["https://other.example.com", "https://vault.example.com"])
        self.assertIsNotNone(tripwires.oidc_claims(token(several), "https://vault.example.com", "owner/name"))

    def test_a_swapped_token_fires(self):
        for change in (
            {"iss": "https://token.evil.test"},
            {"aud": "https://other.example.com"},
            {"aud": ["https://other.example.com"]},
            {"repository": "owner/other"},
            {"repository": None},
            {"iss": None},
        ):
            with self.subTest(change=change), self.assertRaises(Violation):
                tripwires.oidc_claims(token(dict(self.CLAIMS, **change)), "https://vault.example.com", "owner/name")

    def test_a_token_that_cannot_be_decoded_names_no_one(self):
        for value in ("opaque", "a.b.c", "a.!!.c", token([1]), ""):
            with self.subTest(value=value):
                self.assertIsNone(tripwires.oidc_claims(value, "https://vault.example.com", "owner/name"))


class EnvironmentChecks(unittest.TestCase):
    def test_an_ordinary_environment_passes(self):
        environ = {
            "PATH": "/usr/bin",
            "LD_LIBRARY_PATH": "/opt/hostedtoolcache/Python/3.12/x64/lib",
            "PYTHONPATH": "src",
            "HTTPS_PROXY": "http://proxy.example.com:3128",
            "SHELLOPTS": "braceexpand:errexit:pipefail",
            "PS4": "+ ",
            "BASH_FUNC_module%%": "() { eval x; }",
            "GIT_TRACE_REDACT": "1",
            "NODE_TLS_REJECT_UNAUTHORIZED": "1",
            "BASH_ENV": "",
        }
        self.assertEqual(tripwires.environment_violations(environ), [])
        tripwires.hostile_environment(environ)

    def test_each_hostile_setting_fires_without_its_value(self):
        cases = {
            "BASH_ENV": "/tmp/CANARY.sh",
            "LD_PRELOAD": "/tmp/CANARY.so",
            "LD_AUDIT": "/tmp/CANARY.so",
            "DYLD_INSERT_LIBRARIES": "/tmp/CANARY.dylib",
            "BASH_FUNC_curl%%": "() { CANARY; }",
            "BASH_FUNC_jq()": "() { CANARY; }",
            "SHELLOPTS": "braceexpand:xtrace",
            "PS4": "$(CANARY) ",
            "GIT_TRACE_REDACT": "false",
            "NODE_TLS_REJECT_UNAUTHORIZED": "0",
        }
        for name, value in cases.items():
            with self.subTest(name=name):
                found = tripwires.environment_violations({"PATH": "/usr/bin", name: value})
                self.assertEqual(len(found), 1)
                self.assertNotIn("CANARY", str(found[0]))
                with self.assertRaises(Violation):
                    tripwires.hostile_environment({name: value})
        self.assertEqual(len(tripwires.environment_violations(cases)), 9)


def captured(function, *arguments, **keywords):
    stream = io.StringIO()
    with contextlib.redirect_stdout(stream):
        result = function(*arguments, **keywords)
    return result, stream.getvalue()


class Reporting(unittest.TestCase):
    def test_the_annotation_cannot_be_ended_or_extended(self):
        _, text = captured(tripwires.report, "my-action", Violation("ref starts with '-'"), "Nothing ran.")
        self.assertEqual(
            text,
            "::error title=my-action: possible security compromise attempt::ref starts with '-'. Nothing ran. "
            "If this input is intentional, it is not supported; otherwise treat the workflow run as hostile.\n",
        )
        _, text = captured(tripwires.report, "a,b::c\n::warning::x", Violation("50%\r\n::add-mask::x"))
        self.assertEqual(text.count("\n"), 1)
        self.assertTrue(text.startswith("::error title=a%2Cb%3A%3Ac%0A%3A%3Awarning%3A%3Ax: possible"))
        self.assertIn("50%25%0D%0A::add-mask::x. ", text)

    def test_the_title_suffix_is_the_alerting_contract(self):
        # Receivers outside the job match this text (README.md, "Alerting").
        self.assertEqual(tripwires.ANNOTATION_SUFFIX, ": possible security compromise attempt")
        # A title cannot forge or split the suffix: its own ':' is escaped.
        _, text = captured(tripwires.report, "x: possible security compromise attempt", Violation("m"))
        self.assertEqual(text.count(": possible security compromise attempt::"), 1)

    def test_mask_escapes_line_breaks_and_skips_nothing(self):
        self.assertEqual(captured(tripwires.mask, "a%b\nc")[1], "::add-mask::a%25b%0Ac\n")
        self.assertEqual(captured(tripwires.mask, "")[1], "")

    def test_an_output_value_cannot_start_another_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "output")
            tripwires.write_output("a", "1\nb=2\nEOF\nc<<EOF", path)
            lines = path.read_text().split("\n")
            name, _, delimiter = lines[0].partition("<<")
            self.assertEqual(name, "a")
            self.assertRegex(delimiter, r"^tripwires_[0-9a-f]{32}$")
            self.assertEqual(lines[1:], ["1", "b=2", "EOF", "c<<EOF", delimiter, ""])


class CommandLine(unittest.TestCase):
    def run_main(self, spec, values=None, environ=None, title="unit"):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary, "output")
            environ = {"CHECKS": spec, "GITHUB_OUTPUT": str(output), **(environ or {})}
            arguments = ["--title", title, "--checks-env", "CHECKS"]
            if values is not None:
                environ["VALUES"] = values if isinstance(values, str) else json.dumps(values)
                arguments += ["--values-env", "VALUES"]
            code, text = captured(tripwires.main, arguments, environ)
            return code, text, output.read_text() if output.exists() else ""

    def test_clean_values_pass(self):
        with tempfile.TemporaryDirectory() as workspace:
            code, text, output = self.run_main(
                """
                # every check, on a value it accepts
                no-option      ref
                single-line    ref
                shell-safe     repository
                relative-path  path .git
                inside         path
                inside         path RUNNER_TEMP
                plain-path     repository
                url-host       server
                trusted-origin server https://github.com https://ghe.example.com
                event
                """,
                {"ref": "refs/heads/main", "repository": "owner/name", "path": "src/app", "server": "https://GitHub.com/"},
                {"GITHUB_WORKSPACE": workspace, "RUNNER_TEMP": workspace, "GITHUB_EVENT_NAME": "push"},
            )
        self.assertEqual((code, text), (0, ""))
        self.assertRegex(output, r"^security-violation<<(\S+)\nfalse\n\1\n$")

    def test_every_violation_is_reported_without_its_value(self):
        with tempfile.TemporaryDirectory() as workspace:
            code, text, output = self.run_main(
                "no-option ref\nshell-safe ref\ninside path\ntrusted-origin url https://vault.example.com\nevent\nno-option fine",
                {"ref": "--upload-pack=CANARY;x", "path": "../CANARY", "url": "https://CANARY.test", "fine": "main"},
                {"GITHUB_WORKSPACE": workspace, "GITHUB_EVENT_NAME": "pull_request_target"},
                title="my-action",
            )
        self.assertEqual(code, 1)
        lines = text.splitlines()
        self.assertEqual(len(lines), 5)
        for line, start in zip(lines, ("ref starts with '-'", "ref contains shell", "path is outside", "url is not a trusted", "the workflow runs on pull_request_target")):
            self.assertTrue(line.startswith("::error title=my-action: possible security compromise attempt::" + start), line)
        self.assertNotIn("CANARY", text)
        self.assertRegex(output, r"^security-violation<<(\S+)\ntrue\n\1\n$")

    def test_values_are_trimmed_as_inputs_and_empty_ones_pass(self):
        code, _, _ = self.run_main("no-option a\nno-option b\nsingle-line c", {"a": "", "b": " \n", "c": "main\n"})
        self.assertEqual(code, 0)
        code, _, _ = self.run_main("no-option a", {"a": "﻿ \t-x"})
        self.assertEqual(code, 1)

    def test_names_fall_back_to_the_environment(self):
        self.assertEqual(self.run_main("no-option IN_REF", environ={"IN_REF": "-x"})[0], 1)
        self.assertEqual(self.run_main("no-option IN_REF", {"other": "1"}, {"IN_REF": "main"})[0], 0)
        # values wins over a variable of the same name
        self.assertEqual(self.run_main("no-option ref", {"ref": "main"}, {"ref": "-x"})[0], 0)

    def test_typed_json_values_are_checked_as_text(self):
        self.assertEqual(self.run_main("shell-safe depth\nshell-safe flag", {"depth": 1, "flag": True})[0], 0)
        self.assertEqual(self.run_main("no-option depth", {"depth": -1})[0], 1)

    def test_a_label_replaces_the_name_in_the_report(self):
        code, text, _ = self.run_main("no-option IN_REF=ref", environ={"IN_REF": "-x"})
        self.assertEqual(code, 1)
        self.assertIn("::ref starts with '-'", text)
        self.assertNotIn("IN_REF", text)
        self.assertEqual(self.run_main("no-option =ref", environ={"": "-x"})[0], 2)

    def test_the_consequence_is_part_of_the_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            environ = {"CHECKS": "no-option A", "A": "-x", "GITHUB_OUTPUT": str(Path(temporary, "o"))}
            code, text = captured(
                tripwires.main, ["--checks-env", "CHECKS", "--consequence", "Nothing was sent."], environ
            )
        self.assertEqual(code, 1)
        self.assertIn("as a command-line option. Nothing was sent. If this input", text)

    def test_the_environment_and_oidc_checks_run_from_the_command(self):
        good = token({"iss": tripwires.OIDC_ISSUER, "aud": "https://hf.example", "repository": "o/n"})
        environ = {
            "URL": "https://x.actions.githubusercontent.com/t?v=1",
            "JWT": good,
            "GITHUB_REPOSITORY": "o/n",
            "REPO": "o/other",
        }
        spec = "environment\noidc-url URL\noidc-claims JWT=OIDC-token https://hf.example"
        self.assertEqual(self.run_main(spec, environ=environ)[0], 0)
        code, text, _ = self.run_main(
            spec + "\noidc-claims JWT=OIDC-token https://hf.example REPO",
            environ=dict(environ, URL="https://evil.test/t", BASH_ENV="/tmp/x", LD_PRELOAD="/tmp/y"),
        )
        self.assertEqual(code, 1)
        self.assertEqual(text.count("::error "), 4)
        self.assertIn("::OIDC-token does not have the issuer", text)
        self.assertNotIn(good, text)
        # A token that cannot be decoded does not pass the command.
        for value in ("opaque", "a.b.c", "a.!!.c", token([1])):
            with self.subTest(value=value):
                code, text, _ = self.run_main(spec, environ=dict(environ, JWT=value))
                self.assertEqual(code, 1)
                self.assertIn("::OIDC-token is not a token that GitHub issues", text)
        self.assertEqual(self.run_main("environment now", environ=environ)[0], 2)
        self.assertEqual(self.run_main("oidc-claims JWT", environ=environ)[0], 2)
        self.assertEqual(self.run_main("oidc-claims JWT aud MISSING", environ=environ)[0], 2)

    def test_refused_events_can_be_named(self):
        environ = {"GITHUB_EVENT_NAME": "issue_comment"}
        self.assertEqual(self.run_main("event", environ=environ)[0], 0)
        self.assertEqual(self.run_main("event issue_comment pull_request_target", environ=environ)[0], 1)

    def test_checks_that_cannot_run_fail_closed(self):
        cases = {
            "unknown check": ("no-optoin ref", {"ref": "main"}, {}),
            "no name": ("no-option", {}, {}),
            "name not found": ("no-option reff", {"ref": "main"}, {}),
            "extra argument": ("no-option ref extra", {"ref": "main"}, {}),
            "no origins": ("trusted-origin url", {"url": "https://a.test"}, {}),
            "an origin with a path": ("trusted-origin url https://a.test/x", {"url": "https://a.test"}, {}),
            "no base directory": ("inside path", {"path": "a"}, {}),
            "two base directories": ("inside path A B", {"path": "a"}, {"A": "/tmp", "B": "/tmp"}),
            "values not an object": ("no-option ref", "[1]", {}),
            "values not JSON": ("no-option ref", "{", {}),
            "nothing to check": ("# only a comment\n", {}, {}),
        }
        for name, (spec, values, environ) in cases.items():
            with self.subTest(name):
                code, text, output = self.run_main(spec, values, environ)
                self.assertEqual(code, 2)
                self.assertTrue(text.startswith("::error title=unit: tripwires could not run::"), text)
                self.assertEqual(output, "")

    def test_a_spec_error_names_its_line(self):
        _, text, _ = self.run_main("no-option ref\n\nbogus ref", {"ref": "main"})
        self.assertIn("::line 3: unknown check bogus", text)

    def test_the_script_reads_checks_from_stdin(self):
        environment = {"PATH": os.environ.get("PATH", ""), "IN_REF": "-x", "IN_PATH": "ok"}
        for spec, expected in (("no-option IN_PATH\n", 0), ("no-option IN_REF\n", 1), ("", 2)):
            with self.subTest(spec=spec):
                result = subprocess.run(
                    [sys.executable, str(ACTION / "tripwires.py"), "--title", "cli"],
                    input=spec,
                    capture_output=True,
                    text=True,
                    env=environment,
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

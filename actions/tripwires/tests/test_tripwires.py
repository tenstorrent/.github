# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

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
        listed = dict(self.CLAIMS, aud=["https://vault.example.com"])
        self.assertIsNotNone(tripwires.oidc_claims(token(listed), "https://vault.example.com", "owner/name"))

    def test_a_swapped_token_fires(self):
        for change in (
            {"iss": "https://token.evil.test"},
            {"aud": "https://other.example.com"},
            {"aud": ["https://other.example.com"]},
            # Also good for another receiver: not what this job asked for.
            {"aud": ["https://other.example.com", "https://vault.example.com"]},
            {"aud": []},
            {"aud": [["https://vault.example.com"]]},
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

    def test_a_token_in_a_loose_form_names_no_one(self):
        def part(text):
            return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")

        good = token(self.CLAIMS)
        header, payload, signature = good.split(".")
        twice = json.dumps(dict(self.CLAIMS, repository="evil/other"))[:-1] + ', "repository": "Owner/Name"}'
        cases = {
            "two parts": f"{header}.{payload}",
            "four parts": f"{good}.more",
            "an empty signature": f"{header}.{payload}.",
            "characters that a loose decoder skips": f"{header}.!!{payload}.{signature}",
            "padding": f"{header}.{payload}==.{signature}",
            "a header that is not JSON": f"{part('nope')}.{payload}.{signature}",
            "a header that is not an object": f"{part('[]')}.{payload}.{signature}",
            "a member named twice": f"{header}.{part(twice)}.{signature}",
            "nesting past the recursion limit": f"{header}.{part('[' * 200000)}.{signature}",
            "a line break at the end": good + "\n",
        }
        for name, value in cases.items():
            with self.subTest(name):
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
            "BASH_FUNC_env%%": "() { CANARY; }",
            "BASH_FUNC_exit%%": "() { CANARY; }",
            # A name no list would hold: any exported function fires.
            "BASH_FUNC_pwd%%": "() { CANARY; }",
            "BASH_FUNC_module%%": "() { CANARY; }",
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
        # One violation for the exported functions, however many there are.
        self.assertEqual(len(tripwires.environment_violations(cases)), 9)


class PathTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.workspace = self.root / "work"
        for directory in ("work/bin", "work/.venv/bin", "tools", "temp/cachew-x/bin"):
            (self.root / directory).mkdir(parents=True)

    def program(self, place):
        file = self.root / place
        file.write_text("#!/bin/sh\n")
        file.chmod(0o755)
        return file

    def found(self, path, *commands, posix=True):
        environ = {"PATH": path, "GITHUB_WORKSPACE": str(self.workspace)}
        return [str(v) for v in tripwires.environment_violations(environ, commands, posix=posix)]

    def test_an_empty_or_relative_entry_means_the_current_directory(self):
        for path in (":/usr/bin", "/usr/bin:", "/usr/bin::/bin", ".:/usr/bin", "/usr/bin:bin", "/usr/bin:./CANARY"):
            with self.subTest(path=path):
                found = self.found(path)
                self.assertEqual(found, ["PATH has an empty or relative entry, so commands are looked up in the current directory"])
        self.assertEqual(self.found("/usr/bin:/bin"), [])
        self.assertEqual(self.found(""), [])
        # Not where the entries are not POSIX paths.
        self.assertEqual(self.found(r"C:\tools;;D:\bin", posix=False), [])

    def test_a_named_command_must_not_come_from_the_workspace(self):
        self.program("work/bin/curl")
        self.program("tools/curl")
        inside, outside = str(self.workspace / "bin"), str(self.root / "tools")
        message = "the first curl on PATH is inside the workspace, where a pull request can place it"
        self.assertEqual(self.found(f"{inside}:{outside}", "curl", "jq"), [message])
        self.assertNotIn(inside, message)
        # The real one first, an absent command, and a command nobody named.
        self.assertEqual(self.found(f"{outside}:{inside}", "curl", "jq"), [])
        self.assertEqual(self.found(f"{inside}:{outside}", "jq"), [])
        self.assertEqual(self.found(f"{inside}:{outside}"), [])
        # Another spelling of the workspace: a link to it, with the real curl
        # reached through a link that the pull request committed.
        (self.root / "alias").symlink_to(self.workspace)
        self.assertEqual(self.found(f"{self.root / 'alias' / 'bin'}:{outside}", "curl"), [message])
        (self.workspace / "linked").mkdir()
        (self.workspace / "linked" / "curl").symlink_to(self.root / "tools" / "curl")
        self.assertEqual(self.found(f"{self.root / 'alias' / 'linked'}:{outside}", "curl"), [message])
        # A link outside the workspace to a file inside it.
        (self.root / "tools" / "jq").symlink_to(self.program("work/bin/jq-real"))
        self.assertEqual(len(self.found(outside, "jq")), 1)

    def test_supported_additions_to_path_pass(self):
        # A workspace virtual environment, whose python is not named; the cachew
        # session's wrapper in RUNNER_TEMP; a tool cache.
        self.program("work/.venv/bin/python3")
        self.program("temp/cachew-x/bin/git")
        self.program("tools/curl")
        path = ":".join(str(self.root / d) for d in ("work/.venv/bin", "temp/cachew-x/bin", "tools"))
        self.assertEqual(self.found(path, "curl", "jq", "git"), [])
        self.assertEqual(len(self.found(path, "python3")), 1)


class TrustStoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.workspace = self.root / "work"
        (self.workspace / "certs").mkdir(parents=True)
        (self.root / "temp").mkdir()

    def found(self, **environ):
        environ = {"PATH": "/usr/bin", "GITHUB_WORKSPACE": str(self.workspace), **environ}
        return [str(v) for v in tripwires.environment_violations(environ, ("curl",))]

    def test_certificates_from_the_workspace_fire_without_their_path(self):
        (self.root / "alias").symlink_to(self.workspace)
        (self.root / "temp" / "linked.pem").symlink_to(self.workspace / "certs" / "CANARY.pem")
        places = (
            str(self.workspace / "certs" / "CANARY.pem"),
            str(self.root / "alias" / "certs" / "CANARY.pem"),
            str(self.root / "temp" / "linked.pem"),
            # Read from the current directory, which is the workspace.
            "certs/CANARY.pem",
            # One entry of a list.
            os.pathsep.join(("/etc/ssl/certs", str(self.workspace / "certs"))),
        )
        for name in tripwires.TRUST_STORES:
            for place in places:
                with self.subTest(name=name, place=place):
                    found = self.found(**{name: place})
                    self.assertEqual(
                        found,
                        [
                            f"{name} names certificates inside the workspace, where a pull request can place them, "
                            "so a request that carries a secret would trust any server"
                        ],
                    )
                    self.assertNotIn("CANARY", found[0])
        self.assertEqual(len(tripwires.TRUST_STORES), 7)

    def test_the_certificates_of_the_runner_pass(self):
        # A runner behind a proxy that inspects TLS, and the fixture of
        # vault-secrets, which writes its certificate to RUNNER_TEMP.
        for place in ("/etc/ssl/certs/ca-certificates.crt", "/usr/local/share/ca-certificates/proxy.crt", str(self.root / "temp" / "cert.pem"), ""):
            for name in tripwires.TRUST_STORES:
                with self.subTest(name=name, place=place):
                    self.assertEqual(self.found(**{name: place, "HTTPS_PROXY": "http://proxy.example.com:3128"}), [])
        # Without a workspace there is nothing to compare with.
        environ = {"PATH": "/usr/bin", "CURL_CA_BUNDLE": "certs/ca.pem"}
        self.assertEqual(tripwires.environment_violations(environ, ("curl",)), [])


class ScriptLaunchTests(unittest.TestCase):
    """Every step that starts a script of its action, started as the runner
    starts it, on a PATH whose first bash is one a pull request placed. The
    runner looks its shell up on its own PATH; a PATH that an earlier step
    wrote to GITHUB_ENV reaches only the lookups inside the step."""

    ACTIONS = Path(tripwires.__file__).resolve().parent.parent

    def test_a_bash_from_path_does_not_start_the_scripts(self):
        steps = []
        for action in sorted(self.ACTIONS.glob("*/action.yml")):
            text = action.read_text()
            shell = re.search(r"^      shell: (.+)$", text, re.M)
            for line in re.findall(r"^      run: (.*\$GITHUB_ACTION_PATH/[\w-]+\.sh.*)$", text, re.M):
                if line[0] == line[-1] == "'":
                    line = line[1:-1].replace("''", "'")
                steps.append((action.parent.name, shell[1], line))
        self.assertGreaterEqual(len(steps), 10)
        for action, shell, line in steps:
            with self.subTest(action=action, line=line), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                canary = root / "canary"
                for directory in ("action", "work/bin"):
                    (root / directory).mkdir(parents=True)
                for script in re.findall(r"\$GITHUB_ACTION_PATH/([\w-]+\.sh)", line):
                    (root / "action" / script).write_text(f"echo script >>'{canary}'\n")
                planted = root / "work" / "bin" / "bash"
                planted.write_text(f"#!/bin/sh\necho planted >>'{canary}'\n")
                planted.chmod(0o755)
                (root / "step.sh").write_text(line + "\n")
                command = shlex.split(shell.replace("{0}", shlex.quote(str(root / "step.sh"))))
                command[0] = shutil.which(command[0])
                environ = {
                    "PATH": f"{root / 'work' / 'bin'}:{os.environ['PATH']}",
                    "GITHUB_ACTION_PATH": str(root / "action"),
                    "GITHUB_WORKSPACE": str(root / "work"),
                }
                subprocess.run(command, env=environ, capture_output=True, text=True, cwd=root / "work")
                self.assertEqual(canary.read_text() if canary.exists() else "", "script\n")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "needs bash")
class CompositeStepTests(unittest.TestCase):
    """The step of action.yml, started as the runner starts it: the shell line
    with the script file in place of {0}."""

    ACTION = Path(tripwires.__file__).resolve().parent / "action.yml"

    def run_step(self, checks, prepare=None, **environ):
        text = self.ACTION.read_text()
        shell = re.search(r"^      shell: (.+)$", text, re.M)[1]
        body = text.split("      run: |\n", 1)[1]
        script = "\n".join(line[8:] for line in body.splitlines())
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "work" / "bin").mkdir(parents=True)
        (self.root / "step.sh").write_text(script)
        self.canary = self.root / "canary"
        (self.root / "startup.sh").write_text(f"echo startup >>'{self.canary}'\n")
        fake = self.root / "work" / "bin" / "python3"
        fake.write_text(f"#!/bin/sh\necho python >>'{self.canary}'\nexit 0\n")
        fake.chmod(0o755)
        (self.root / "alias").symlink_to(self.root / "work")
        if prepare:
            prepare(self.root)
        environment = {
            "PATH": os.environ["PATH"],
            "GITHUB_ACTION_PATH": str(self.ACTION.parent),
            "GITHUB_WORKSPACE": str(self.root / "work"),
            "TRIPWIRES_TITLE": "t",
            "TRIPWIRES_VALUES": "{}",
            "TRIPWIRES_CHECKS": checks,
            "HOSTILE": "-x",
        }
        environment.update({key: value.replace("ROOT", str(self.root)) for key, value in environ.items()})
        command = shlex.split(shell.replace("{0}", shlex.quote(str(self.root / "step.sh"))))
        command[0] = shutil.which(command[0])
        result = subprocess.run(command, env=environment, capture_output=True, text=True, cwd=self.root / "work")
        return result.returncode, result.stdout + result.stderr

    def test_the_shell_reads_no_startup_file(self):
        code, text = self.run_step("environment", BASH_ENV="ROOT/startup.sh")
        self.assertEqual(code, 1)
        self.assertIn("::BASH_ENV is set", text)
        self.assertFalse(self.canary.exists(), "the BASH_ENV file ran before the check")

    def test_an_exported_function_does_not_replace_the_launch(self):
        functions = {f"BASH_FUNC_{name}%%": "() { return 0; }" for name in ("exec", "exit", "builtin", "cd", "echo")}
        code, text = self.run_step("no-option HOSTILE", **functions)
        self.assertEqual(code, 1)
        self.assertIn("::HOSTILE starts with '-'", text)

    def test_a_python_from_the_workspace_does_not_run_the_checks(self):
        for spelled in ("ROOT/work/bin", "ROOT/alias/bin", "bin", "ROOT/work/../work/bin"):
            with self.subTest(spelled=spelled):
                code, text = self.run_step("no-option HOSTILE", PATH=f"{spelled}:{os.environ['PATH']}")
                self.assertEqual(code, 1)
                self.assertIn("::HOSTILE starts with '-'", text)
                self.assertFalse(self.canary.exists(), "the workspace python3 ran")

    def test_without_another_interpreter_the_step_fails(self):
        code, text = self.run_step("no-option HOSTILE", PATH="ROOT/work/bin")
        self.assertEqual(code, 1)
        self.assertIn("The only Python on PATH is inside the workspace. The checks need Python 3.9 or newer", text)
        self.assertFalse(self.canary.exists())

    def test_the_message_names_why_no_interpreter_was_found(self):
        def prepare(root):
            for directory, status in (("old/bin", 1), ("rel/bin", 0)):
                path = root / directory / "python3"
                path.parent.mkdir(parents=True)
                path.write_text(f"#!/bin/sh\nexit {status}\n")
                path.chmod(0o755)

        older = "Python on PATH outside the workspace is older than 3.9 or does not start."
        for path, reason in (
            ("ROOT/missing", "There is no Python on PATH."),
            ("ROOT/old/bin", older),
            ("ROOT/work/bin:ROOT/old/bin", older),
            ("../rel/bin", "The only Python on PATH is in a relative PATH entry."),
        ):
            with self.subTest(path=path):
                code, text = self.run_step("no-option HOSTILE", prepare, PATH=path)
                self.assertEqual(code, 1)
                self.assertIn(f"checks could not run::{reason} The checks need Python 3.9 or newer", text)

    def test_without_an_interpreter_the_title_input_is_not_printed(self):
        title = "x::forged\n::add-mask::swallowed\n::error title=y"
        code, text = self.run_step("no-option HOSTILE", PATH="ROOT/work/bin", TRIPWIRES_TITLE=title)
        self.assertEqual(code, 1)
        self.assertIn("::error title=tripwires: checks could not run::The only Python on PATH is inside the workspace.", text)
        self.assertNotIn("forged", text)
        self.assertNotIn("add-mask", text)


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
            "::error title=my-action: input not supported::ref starts with '-'. Nothing ran.\n",
        )
        _, text = captured(tripwires.report, "a,b::c\n::warning::x", Violation("50%\r\n::add-mask::x"))
        self.assertEqual(text.count("\n"), 1)
        self.assertTrue(text.startswith("::error title=a%2Cb%3A%3Ac%0A%3A%3Awarning%3A%3Ax: input not supported::"))
        self.assertIn("50%25%0D%0A::add-mask::x. ", text)

    def test_the_title_suffix_is_the_alerting_contract(self):
        # Receivers outside the job match this text (README.md, "Alerting").
        self.assertEqual(tripwires.ANNOTATION_SUFFIX, ": input not supported")
        # A title cannot forge or split the suffix: its own ':' is escaped.
        _, text = captured(tripwires.report, "x: input not supported", Violation("m"))
        self.assertEqual(text.count(": input not supported::"), 1)

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
            self.assertTrue(line.startswith("::error title=my-action: input not supported::" + start), line)
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
        self.assertIn("as a command-line option. Nothing was sent.\n", text)

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
        self.assertEqual(self.run_main("environment ../curl", environ=environ)[0], 2)
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
                self.assertTrue(text.startswith("::error title=unit: checks could not run::"), text)
                self.assertEqual(output, "")

    def test_an_error_in_a_check_fails_closed_without_its_message(self):
        def broken(value, label, arguments, environ):
            raise RuntimeError("secret-value")

        with mock.patch.dict(tripwires.CHECKS, {"no-option": (broken, False)}):
            code, text, output = self.run_main("no-option ref", {"ref": "main"})
        self.assertEqual(code, 2)
        self.assertTrue(text.startswith("::error title=unit: checks could not run::internal error"), text)
        self.assertIn("RuntimeError", text)
        self.assertNotIn("secret-value", text)
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

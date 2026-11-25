# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
"""The checks of refuse_attack_inputs that read only the environment."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkout  # noqa: E402


class JobTokenAndEnvironment(unittest.TestCase):
    def refuse(self, **changes):
        with tempfile.TemporaryDirectory() as workspace:
            environ = {
                "GITHUB_WORKSPACE": workspace,
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/name",
                "CACHEW_JOB_TOKEN": "true",
                **changes,
            }
            checkout.refuse_attack_inputs(environ)

    def test_the_job_token_stays_on_the_job_server(self):
        for url in ("", "https://github.com", "https://GitHub.com:443/", "https://github.com/owner", " https://github.com "):
            with self.subTest(url=url):
                self.refuse(CACHEW_GITHUB_SERVER_URL=url)
        for url in (
            "https://ghe.example.com",
            "https://github.com.evil.test",
            "https://github.com:8443",
            "http://github.com",
            "https://evil.test/github.com",
            "https://github.com@evil.test/",
            "evil.test",
        ):
            with self.subTest(url=url), self.assertRaises(checkout.SecurityViolation) as raised:
                self.refuse(CACHEW_GITHUB_SERVER_URL=url)
            self.assertIn("would have received the job's GitHub token", str(raised.exception))

    def test_another_token_may_go_to_another_server(self):
        for flag in ("false", ""):
            self.refuse(CACHEW_GITHUB_SERVER_URL="https://ghe.example.com", CACHEW_JOB_TOKEN=flag)

    def test_a_prepared_environment_is_refused(self):
        for name, value in (("BASH_ENV", "/tmp/x"), ("LD_PRELOAD", "/tmp/x.so"), ("GIT_TRACE_REDACT", "0"), ("BASH_FUNC_git%%", "() { :; }")):
            with self.subTest(name=name), self.assertRaises(checkout.SecurityViolation):
                self.refuse(**{name: value})


if __name__ == "__main__":
    unittest.main()

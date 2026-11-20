# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0

"""Real downstream CMake/Git reads, one cache attempt, and job-wide rewrite removal."""

import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import unittest
import urllib.parse

import test_checkout as fixture


@unittest.skipUnless(shutil.which("cmake"), "CMake is required for downstream dependency integration tests")
class DownstreamGitTests(unittest.TestCase):
    def setUp(self):
        self.git_fixture = fixture.CheckoutTests()
        self.git_fixture.setUp()
        self.addCleanup(self.git_fixture.doCleanups)
        self.root = self.git_fixture.root
        self.env = dict(self.git_fixture.env)
        self.real_git = self.git_fixture.env.get("CACHEW_REAL_GIT") or shutil.which("git")
        self.session = self.root / "session"
        self.session.mkdir(mode=0o700)
        self.upstream = self.git_fixture.upstream
        self.cache = self.git_fixture.cache
        self.baseline = (self.git_fixture.home / ".gitconfig").read_bytes()
        # Same layout as session.py after a successful activation: the
        # caller's settings plus performance keys, then cachew's managed keys.
        active = self.session / "global.config"
        active.write_bytes(self.baseline)
        for name, value in (
            ("checkout.workers", "0"),
            ("checkout.thresholdForParallelism", "50"),
            ("submodule.fetchJobs", "0"),
            ("gc.auto", "0"),
        ):
            self.config(active, name, value)
        host = urllib.parse.urlsplit(self.upstream.url).netloc
        self.managed = [
            [f"url.{self.cache.url}/git/{host}/.insteadOf", self.upstream.url + "/"],
            [f"http.{self.cache.url}/.extraHeader", ""],
            [f"http.{self.cache.url}/.extraHeader", self.authorization()],
        ]
        for key, value in self.managed:
            subprocess.run([self.real_git, "config", "--file", str(active), "--add", key, value], check=True)
        (self.session / "state.json").write_text(
            json.dumps({"active": True, "managed": self.managed, "cache": self.cache.url})
        )
        shim = self.session / "bin/git"
        shim.parent.mkdir()
        shim.write_text(
            "#!/bin/sh\nexec "
            + shlex.quote(sys.executable)
            + " "
            + shlex.quote(str(fixture.ACTION / "git_wrapper.py"))
            + ' "$@"\n'
        )
        shim.chmod(0o500)  # read and execute for the owner only: PATH lookup needs no more
        self.env.update(
            CACHEW_REAL_GIT=self.real_git,
            CACHEW_SESSION_DIR=str(self.session),
            CACHEW_GIT_FETCH_TIMEOUT="5",
            GIT_CONFIG_GLOBAL=str(active),
            PATH=str(shim.parent) + os.pathsep + self.env["PATH"],
        )

    def authorization(self):
        return "AUTHORIZATION: basic " + base64.b64encode(f"x-access-token:{fixture.TOKEN}".encode()).decode()

    def config(self, path, key, value):
        subprocess.run([self.real_git, "config", "--file", str(path), key, value], check=True, capture_output=True)

    def dependency(self, name):
        self.git_fixture.repository(name)
        repository = self.git_fixture.project_root / "org" / name
        (repository / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.24)\nproject(cached_dependency NONE)\n"
        )
        fixture.git(repository, "add", "CMakeLists.txt", env=self.env)
        fixture.git(repository, "commit", "-m", "CMake dependency", env=self.env)
        return fixture.git(repository, "rev-parse", "HEAD", env=self.env)

    def configure(self, dependencies):
        source = self.root / "cmake-source"
        source.mkdir()
        content = "cmake_minimum_required(VERSION 3.24)\nproject(cachew_consumer NONE)\ninclude(FetchContent)\n"
        for name, sha in dependencies:
            content += f"FetchContent_Declare({name} GIT_REPOSITORY {self.upstream.url}/org/{name} GIT_TAG {sha})\n"
            content += f"FetchContent_MakeAvailable({name})\n"
        (source / "CMakeLists.txt").write_text(content)
        result = subprocess.run(
            ["cmake", "-S", str(source), "-B", str(self.root / "cmake-build")],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def run_git(self, *arguments, cwd=None):
        result = subprocess.run(["git", *arguments], cwd=cwd, env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def assert_disabled(self):
        self.assertTrue((self.session / "cache-disabled").exists())
        result = subprocess.run(
            [self.real_git, "config", "--global", "--get-regexp", r"^url\..*\.insteadof$"],
            env=self.env,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual((self.git_fixture.home / ".gitconfig").read_bytes(), self.baseline)
        self.assertNotIn(self.cache.url.encode(), (self.session / "global.config").read_bytes())
        self.assertEqual(self.run_git("config", "--global", "checkout.workers"), "0")

    def test_cmake_dependency_uses_global_cache_and_authorization(self):
        sha = self.dependency("cmake-dependency")
        self.upstream.block_submodules = True
        self.configure([("cmake-dependency", sha)])
        self.assertEqual(len(self.cache.discoveries()), 1)
        self.assertEqual(self.upstream.requests, [])
        for _, _, auth in self.cache.requests:
            self.assertEqual(auth, self.authorization().removeprefix("AUTHORIZATION: "))
        repository = self.root / "cmake-build/_deps/cmake-dependency-src"
        self.assertEqual(
            self.run_git("-C", str(repository), "config", "--get", "remote.origin.url"),
            self.upstream.url + "/org/cmake-dependency",
        )

    def test_partial_clone_lazy_fetches_go_upstream(self):
        # Git runs lazy fetches itself, past the wrapper; without the pin they
        # would follow the rewrite to a cache that cannot serve this repository.
        self.dependency("cmake-dependency")
        target = self.root / "partial"
        url = self.upstream.url + "/org/cmake-dependency"
        self.run_git("clone", "--filter=blob:none", "--no-checkout", url, str(target))
        self.assertEqual(len(self.cache.discoveries()), 1)
        self.assertEqual(self.run_git("-C", str(target), "config", "--get-all", f"url.{url}.insteadOf"), url)
        self.cache.fail_repo = "cmake-dependency"
        cache_requests = len(self.cache.requests)
        self.assertIn("cmake_minimum_required", self.run_git("-C", str(target), "show", "HEAD:CMakeLists.txt"))
        self.assertEqual(len(self.cache.requests), cache_requests)
        self.assertTrue(self.upstream.requests)
        self.assertFalse((self.session / "cache-disabled").exists())

    def test_fetch_stdin_refspecs_go_upstream_once(self):
        # An upstream retry could not replay refspecs the cache attempt consumed.
        self.dependency("cmake-dependency")
        target = self.root / "cloned"
        self.run_git("clone", self.upstream.url + "/org/cmake-dependency", str(target))
        self.cache.fail_repo = "cmake-dependency"
        requests = len(self.cache.requests)
        result = subprocess.run(
            ["git", "-C", str(target), "fetch", "--stdin", "origin"],
            input="refs/heads/main:refs/remotes/origin/from-stdin\n",
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.run_git("-C", str(target), "rev-parse", "--verify", "refs/remotes/origin/from-stdin")
        self.assertEqual(len(self.cache.requests), requests)
        self.assertFalse((self.session / "cache-disabled").exists())

    def cloned_dependency(self):
        self.dependency("cmake-dependency")
        target = self.root / "cloned"
        self.run_git("clone", self.upstream.url + "/org/cmake-dependency", str(target))
        return target

    def test_fetch_all_with_a_failing_other_remote_leaves_caching_on(self):
        # Git reports every remote's errors together: a failure elsewhere must not
        # read as the cache failing, so this fetch goes upstream once.
        target = self.cloned_dependency()
        self.run_git("-C", str(target), "remote", "add", "elsewhere", "http://127.0.0.1:1/org/missing")
        requests = len(self.cache.requests)
        subprocess.run(["git", "-C", str(target), "fetch", "--all"], env=self.env, capture_output=True, timeout=30)
        self.assertEqual(len(self.cache.requests), requests)
        self.assertFalse((self.session / "cache-disabled").exists())

    def test_fetch_all_of_cached_remotes_uses_the_cache(self):
        target = self.cloned_dependency()
        requests = len(self.cache.requests)
        self.run_git("-C", str(target), "fetch", "--all")
        self.assertGreater(len(self.cache.requests), requests)

    def test_fetch_of_a_remote_group_falls_back_like_its_remotes(self):
        target = self.cloned_dependency()
        self.run_git("-C", str(target), "remote", "add", "mirror", self.upstream.url + "/org/cmake-dependency")
        self.run_git("-C", str(target), "config", "remotes.everything", "origin mirror")
        self.cache.fail_repo = "cmake-dependency"
        self.run_git("-C", str(target), "fetch", "everything")
        self.assertTrue(self.upstream.requests)

    def test_network_remote_subcommands_go_upstream(self):
        self.dependency("cmake-dependency")
        target = self.root / "cloned"
        url = self.upstream.url + "/org/cmake-dependency"
        self.run_git("clone", url, str(target))
        self.cache.fail_repo = "cmake-dependency"
        cache_requests = len(self.cache.requests)
        self.run_git("-C", str(target), "remote", "show", "origin")
        self.run_git("-C", str(target), "remote", "add", "-f", "again", url)
        self.assertEqual(len(self.cache.requests), cache_requests)
        self.assertFalse((self.session / "cache-disabled").exists())

    def test_cmake_clone_error_removes_rewrite_and_later_dependency_stays_upstream(self):
        first = self.dependency("cmake-dependency")
        second = self.dependency("next-dependency")
        self.cache.fail_repo = "cmake-dependency"
        self.configure([("cmake-dependency", first), ("next-dependency", second)])
        self.assertEqual(len(self.cache.discoveries()), 1)
        self.assertEqual(len(self.upstream.discoveries()), 2)
        self.assertTrue(all("cmake-dependency" in path for _, path, _ in self.cache.requests))
        self.assert_disabled()

    def test_later_fetch_error_updates_origin_refs_upstream_without_cache_retry(self):
        self.dependency("cmake-dependency")
        target = self.root / "cloned"
        self.run_git("clone", self.upstream.url + "/org/cmake-dependency", str(target))
        repository = self.git_fixture.project_root / "org/cmake-dependency"
        (repository / "new.txt").write_text("new commit")
        fixture.git(repository, "add", "new.txt", env=self.env)
        fixture.git(repository, "commit", "-m", "update", env=self.env)
        sha = fixture.git(repository, "rev-parse", "HEAD", env=self.env)
        self.cache.fail_repo = "cmake-dependency"
        self.run_git("--git-dir=.git", "fetch", "--tags", "--force", "origin", cwd=target)
        self.assertEqual(len(self.cache.discoveries()), 2)
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assertEqual(self.run_git("-C", str(target), "rev-parse", "origin/main"), sha)
        self.assert_disabled()

    def test_stalled_cache_clone_falls_back_after_deadline(self):
        sha = self.dependency("cmake-dependency")
        self.env["CACHEW_GIT_FETCH_TIMEOUT"] = "0.4"
        self.cache.fail_repo = "cmake-dependency"
        self.cache.fetch_delay = 0.8
        self.configure([("cmake-dependency", sha)])
        self.assertEqual(len(self.cache.discoveries()), 1)
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_disabled()

    def test_cache_redirect_disables_rewrite_without_following(self):
        sha = self.dependency("cmake-dependency")
        self.cache.fail_repo = "cmake-dependency"
        self.cache.fail_status = 302
        self.configure([("cmake-dependency", sha)])
        self.assertEqual(len(self.cache.requests), 1)
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_disabled()

    def test_cache_401_does_not_retry_with_inherited_credential_helper(self):
        sha = self.dependency("cmake-dependency")
        self.cache.fail_repo = "cmake-dependency"
        self.cache.fail_status = 401
        handler = self.cache.server.RequestHandlerClass
        original = handler.send_response

        def unauthorized(response, status, message=None):
            original(response, status, message)
            if status == 401:
                response.send_header("WWW-Authenticate", 'Basic realm="cachew-fixture"')

        handler.send_response = unauthorized
        marker = self.root / "credential-helper-called"
        helper = f"!touch {shlex.quote(str(marker))}; printf 'username=other\\npassword=other\\n'"
        self.config(self.session / "global.config", "credential.helper", helper)
        self.configure([("cmake-dependency", sha)])
        self.assertEqual(len(self.cache.requests), 1)
        self.assertFalse(marker.exists())
        # A 401 is an answer about one repository, not a broken cache: that read
        # goes upstream, while caching stays on for the rest of the job.
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_enabled()

    def test_native_recursive_clone_goes_upstream_without_hidden_cache_retries(self):
        target = self.root / "recursive"
        self.run_git("clone", "--recurse-submodules", self.upstream.url + "/org/main", str(target))
        self.assertEqual(self.cache.requests, [])
        self.assertEqual((target / "deps/child/deep/grand/content.txt").read_text(), "grand")
        self.assertFalse((self.session / "cache-disabled").exists())

    def test_clone_recurse_submodules_false_is_still_recursive(self):
        # For clone the value is a pathspec, so this is a recursive clone
        # (Git records submodule.active=false) and goes upstream like one.
        wrapper = load_wrapper()
        arguments = ["clone", "--recurse-submodules=false", self.upstream.url + "/org/main"]
        self.assertTrue(wrapper.direct_network_operation(self.real_git, arguments, 0, self.env))
        fetch = ["fetch", "--recurse-submodules=false", "origin"]
        self.assertFalse(wrapper.direct_network_operation(self.real_git, ["-C", str(self.root), *fetch], 2, self.env))

    def test_stalled_bare_clone_without_destination_falls_back(self):
        self.dependency("cmake-dependency")
        self.env["CACHEW_GIT_FETCH_TIMEOUT"] = "1"
        self.cache.fail_repo = "cmake-dependency"
        self.cache.fetch_delay = 6
        self.run_git("clone", "--bare", self.upstream.url + "/org/cmake-dependency", cwd=self.root)
        self.assertEqual(self.run_git("-C", str(self.root / "cmake-dependency.git"), "rev-parse", "--is-bare-repository"), "true")
        self.assertFalse((self.root / "cmake-dependency").exists())
        self.assert_disabled()

    def test_disabled_session_with_a_leftover_rewrite_stays_upstream(self):
        # A concurrent disable (marker written, rewrite not yet removed), or a
        # rewrite that could not be removed: reads must still go upstream.
        self.dependency("cmake-dependency")
        (self.session / "cache-disabled").touch()
        self.run_git("ls-remote", self.upstream.url + "/org/cmake-dependency")
        self.assertEqual(self.cache.requests, [])

    def test_disabled_session_retries_removing_a_leftover_rewrite(self):
        # The disable could not remove the rewrite (locked file); the next read
        # removes it, so Git's own lazy fetches stop following it too.
        self.dependency("cmake-dependency")
        (self.session / "cache-disabled").touch()
        self.run_git("ls-remote", self.upstream.url + "/org/cmake-dependency")
        self.assertEqual(self.cache.requests, [])
        self.assert_disabled()
        self.assertEqual(json.loads((self.session / "state.json").read_text())["managed"], [])

    def test_disabled_partial_clone_with_a_stuck_rewrite_lazy_fetches_upstream(self):
        # The rewrite stays in the job file (still locked), so the partial clone
        # made upstream must be pinned there, or its lazy fetches go to the cache.
        self.dependency("cmake-dependency")
        (self.session / "cache-disabled").touch()
        lock = self.session / "global.config.lock"
        lock.touch()
        self.addCleanup(lock.unlink, missing_ok=True)
        self.cache.fail_repo = "cmake-dependency"
        target = self.root / "partial"
        url = self.upstream.url + "/org/cmake-dependency"
        self.run_git("clone", "--filter=blob:none", "--no-checkout", url, str(target))
        self.assertEqual(self.cache.requests, [])
        self.assertIn(self.cache.url.encode(), (self.session / "global.config").read_bytes())
        self.assertEqual(self.run_git("-C", str(target), "config", "--get-all", f"url.{url}.insteadOf"), url)
        self.assertIn("cmake_minimum_required", self.run_git("-C", str(target), "show", "HEAD:CMakeLists.txt"))
        self.assertEqual(self.cache.requests, [])

    def test_disabled_aliased_partial_clone_with_a_stuck_rewrite_lazy_fetches_upstream(self):
        self.dependency("cmake-dependency")
        self.config(self.session / "global.config", "alias.partial", "clone --filter=blob:none --no-checkout")
        (self.session / "cache-disabled").touch()
        lock = self.session / "global.config.lock"
        lock.touch()
        self.addCleanup(lock.unlink, missing_ok=True)
        self.cache.fail_repo = "cmake-dependency"
        target = self.root / "partial"
        url = self.upstream.url + "/org/cmake-dependency"
        self.run_git("partial", url, str(target))
        self.assertIn(self.cache.url.encode(), (self.session / "global.config").read_bytes())
        self.assertEqual(self.run_git("-C", str(target), "config", "--get-all", f"url.{url}.insteadOf"), url)
        self.assertIn("cmake_minimum_required", self.run_git("-C", str(target), "show", "HEAD:CMakeLists.txt"))
        self.assertEqual(self.cache.requests, [])

    def test_disable_keeps_keys_it_could_not_remove(self):
        wrapper = load_wrapper()
        lock = self.session / "global.config.lock"
        lock.touch()
        self.addCleanup(lock.unlink, missing_ok=True)
        state = json.loads((self.session / "state.json").read_text())
        state = wrapper.remove_cache_keys(self.real_git, self.session, state, self.env)
        self.assertEqual(state["managed"], self.managed)
        self.assertEqual(json.loads((self.session / "state.json").read_text())["managed"], self.managed)

    def test_push_bypasses_read_only_cache(self):
        self.dependency("cmake-dependency")
        target = self.root / "push-source"
        self.run_git("clone", self.upstream.url + "/org/cmake-dependency", str(target))
        cache_requests = list(self.cache.requests)
        self.run_git("-C", str(target), "push", "origin", "HEAD:refs/heads/proof")
        self.assertEqual(self.cache.requests, cache_requests)
        remote = self.git_fixture.project_root / "org/cmake-dependency"
        self.assertEqual(fixture.git(remote, "rev-parse", "proof"), fixture.git(remote, "rev-parse", "main"))

    def cloned_dependency(self):
        self.dependency("cmake-dependency")
        target = self.root / "cloned"
        self.run_git("clone", self.upstream.url + "/org/cmake-dependency", str(target))
        return target

    def test_aliased_push_goes_upstream(self):
        target = self.cloned_dependency()
        self.config(self.session / "global.config", "alias.pu", "push")
        self.config(self.session / "global.config", "alias.force", "-c push.default=current pu")
        cache_requests = list(self.cache.requests)
        self.run_git("-C", str(target), "pu", "origin", "HEAD:refs/heads/aliased")
        self.run_git("-C", str(target), "force", "origin", "HEAD:refs/heads/nested")
        self.run_git("-C", str(target), "-c", "alias.send=push origin", "send", "HEAD:refs/heads/inline")
        self.assertEqual(self.cache.requests, cache_requests)
        remote = self.git_fixture.project_root / "org/cmake-dependency"
        for branch in ("aliased", "nested", "inline"):
            self.assertEqual(fixture.git(remote, "rev-parse", branch), fixture.git(remote, "rev-parse", "main"))

    def test_push_past_the_wrapper_goes_upstream(self):
        """The pushInsteadOf that session.py writes keeps a push off the cache even
        when Git is run directly, as a tool that knows its full path does."""
        target = self.cloned_dependency()
        key = f"url.{self.upstream.url}/.pushInsteadOf"
        self.config(self.session / "global.config", key, self.upstream.url + "/")
        cache_requests = list(self.cache.requests)
        result = subprocess.run(
            [self.real_git, "-C", str(target), "push", "origin", "HEAD:refs/heads/direct"],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cache.requests, cache_requests)
        remote = self.git_fixture.project_root / "org/cmake-dependency"
        self.assertEqual(fixture.git(remote, "rev-parse", "direct"), fixture.git(remote, "rev-parse", "main"))

    def test_aliased_fetch_is_retried_upstream_like_a_fetch(self):
        target = self.cloned_dependency()
        self.config(self.session / "global.config", "alias.up", "fetch --tags")
        self.run_git("-C", str(target), "up", "origin")
        self.assertEqual(len(self.cache.discoveries()), 2)
        self.assertEqual(self.upstream.discoveries(), [])
        self.cache.fail_repo = "cmake-dependency"
        self.run_git("-C", str(target), "up", "origin")
        self.assertEqual(len(self.cache.discoveries()), 3)
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_disabled()

    def test_an_alias_in_its_subsection_form_is_retried_upstream_like_a_fetch(self):
        # alias.<name>.command, whose name may hold any character; the last form set wins.
        target = self.cloned_dependency()
        self.config(self.session / "global.config", "alias.up", "status")
        self.config(self.session / "global.config", "alias.up.command", "fetch --tags")
        self.config(self.session / "global.config", "alias.f.x.command", "up origin")
        self.cache.fail_repo = "cmake-dependency"
        self.run_git("-C", str(target), "f.x")
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_disabled()

    def test_a_fetch_after_an_attribute_source_option_is_retried_upstream(self):
        target = self.cloned_dependency()
        self.cache.fail_repo = "cmake-dependency"
        self.run_git("-C", str(target), "--attr-source", "HEAD", "fetch", "origin")
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_disabled()

    def test_shell_alias_reads_go_upstream(self):
        target = self.cloned_dependency()
        self.config(self.session / "global.config", "alias.sync", "!git fetch origin")
        cache_requests = list(self.cache.requests)
        self.run_git("-C", str(target), "sync")
        self.assertEqual(self.cache.requests, cache_requests)
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_enabled()

    def test_alias_named_like_a_git_command_is_ignored(self):
        target = self.cloned_dependency()
        self.config(self.session / "global.config", "alias.status", "push origin HEAD:refs/heads/shadow")
        requests = (list(self.cache.requests), list(self.upstream.requests))
        self.run_git("-C", str(target), "status")
        self.assertEqual((self.cache.requests, self.upstream.requests), requests)

    def test_disabled_session_respects_explicit_step_global_configuration(self):
        (self.session / "cache-disabled").touch()
        explicit = self.root / "explicit.config"
        explicit.write_text("[user]\n name = Explicit\n")
        self.env["GIT_CONFIG_GLOBAL"] = str(explicit)
        self.assertEqual(self.run_git("config", "--get", "user.name"), "Explicit")

    def assert_enabled(self):
        self.assertFalse((self.session / "cache-disabled").exists())
        self.assertIn(self.cache.url.encode(), (self.session / "global.config").read_bytes())

    def test_failures_of_remotes_that_are_not_the_cache_keep_caching_on(self):
        unreachable = "http://127.0.0.1:1/org/elsewhere"
        for arguments in (["ls-remote", unreachable], ["clone", unreachable, str(self.root / "elsewhere")]):
            with self.subTest(command=arguments[0]):
                result = subprocess.run(["git", *arguments], env=self.env, text=True, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Cachew", result.stderr)
        target = self.root / "pinned-upstream"
        self.run_git("init", "-q", str(target))
        self.run_git("-C", str(target), "remote", "add", "origin", unreachable)
        result = subprocess.run(
            ["git", "-C", str(target), "fetch", "--depth", "1", "origin"],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Cachew", result.stderr)
        self.assertEqual(self.cache.requests, [])
        self.assert_enabled()

    def test_global_writes_survive_cache_disable(self):
        # M2: a job's own `git config --global` writes must survive the cache
        # being switched off mid-job.
        sha = self.dependency("cmake-dependency")
        self.run_git("config", "--global", "user.email", "job@example.com")
        self.run_git("config", "--global", "--add", "safe.directory", str(self.root))
        self.cache.fail_repo = "cmake-dependency"
        self.configure([("cmake-dependency", sha)])
        self.assert_disabled()
        self.assertEqual(self.run_git("config", "--global", "user.email"), "job@example.com")
        self.assertEqual(self.run_git("config", "--global", "safe.directory"), str(self.root))

    def test_ls_remote_exit_code_2_does_not_disable_cache(self):
        # M1: `ls-remote --exit-code` returns 2 when nothing matches. That is an
        # answer, not a cache failure.
        self.dependency("cmake-dependency")
        url = self.upstream.url + "/org/cmake-dependency"
        result = subprocess.run(
            ["git", "ls-remote", "--exit-code", url, "refs/heads/does-not-exist"],
            env=self.env,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assert_enabled()
        self.assertEqual(self.run_git("ls-remote", url, "refs/heads/main").split()[1], "refs/heads/main")
        self.assertEqual(len(self.cache.discoveries()), 2)

    def test_missing_ref_retries_upstream_without_disabling_cache(self):
        self.dependency("cmake-dependency")
        target = self.root / "cloned"
        self.run_git("clone", self.upstream.url + "/org/cmake-dependency", str(target))
        result = subprocess.run(
            ["git", "-C", str(target), "fetch", "--no-recurse-submodules", "origin", "refs/heads/missing"],
            env=self.env,
            capture_output=True,
            timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.upstream.discoveries()), 1, "one upstream retry for a ref the cache lacks")
        self.assert_enabled()

    def test_cache_404_retries_upstream_without_disabling_cache(self):
        sha = self.dependency("cmake-dependency")
        self.cache.fail_repo = "cmake-dependency"
        self.cache.fail_status = 404
        self.configure([("cmake-dependency", sha)])
        self.assertEqual(len(self.upstream.discoveries()), 1)
        self.assert_enabled()

    def test_stalled_cache_transfer_is_abandoned_by_progress_not_wall_clock(self):
        # M5: lowSpeedTime abandons a silent cache after the stall timeout
        # instead of a fixed wall-clock deadline that also kills slow progress.
        self.dependency("cmake-dependency")
        self.env["CACHEW_GIT_FETCH_TIMEOUT"] = "1"
        self.cache.fail_repo = "cmake-dependency"
        self.cache.fetch_delay = 6
        started = time.monotonic()
        self.run_git("clone", self.upstream.url + "/org/cmake-dependency", str(self.root / "stalled"))
        self.assertLess(time.monotonic() - started, 5.5)
        self.assertEqual(self.run_git("-C", str(self.root / "stalled"), "rev-parse", "--is-inside-work-tree"), "true")
        self.assert_disabled()

    def test_killed_clone_cleanup_covers_the_second_directory(self):
        # Git removes both directories itself on an ordinary failure; after a
        # SIGKILL only this cleanup stands between the leftovers and the retry.
        wrapper = load_wrapper()
        url = self.upstream.url + "/org/main"
        cases = [
            (["clone", "--separate-git-dir", str(self.root / "sep-a"), url, str(self.root / "dest-a")], {}, "sep-a"),
            (["clone", f"--separate-git-dir={self.root / 'sep-b'}", url, str(self.root / "dest-b")], {}, "sep-b"),
            ([f"--work-tree={self.root / 'wt-c'}", "clone", url, str(self.root / "dest-c")], {}, "wt-c"),
            (["clone", url, str(self.root / "dest-d")], {"GIT_WORK_TREE": str(self.root / "wt-d")}, "wt-d"),
        ]
        kept = self.root / "existing"
        kept.mkdir()
        (kept / "mine").write_text("keep")
        for arguments, environ, second in cases:
            with self.subTest(arguments=arguments):
                target = wrapper.CloneTarget(arguments, wrapper.command_index(arguments), environ)
                for leftover in (target.path, self.root / second):
                    leftover.mkdir()
                    (leftover / "partial").write_text("left by a killed clone")
                target.reset()
                self.assertFalse(target.path.exists())
                self.assertFalse((self.root / second).exists())
        arguments = ["clone", f"--separate-git-dir={kept}", url, str(self.root / "dest-e")]
        wrapper.CloneTarget(arguments, 0, {}).reset()
        self.assertEqual((kept / "mine").read_text(), "keep")

    def test_clone_destination_parsing(self):
        wrapper = load_wrapper()
        cwd = Path.cwd()
        cases = [
            (["clone", "https://h/o/repo.git"], cwd / "repo"),
            (["clone", "--depth", "1", "-b", "main", "https://h/o/repo", "dest"], cwd / "dest"),
            (["-C", "/tmp", "clone", "--no-checkout", "--config", "a=b", "https://h/o/r/", "x"], Path("/tmp/x")),
            (["clone", "--", "https://h/o/repo", "--odd"], cwd / "--odd"),
            (["clone", "git@github.com:o/name.git"], cwd / "name"),
            (["clone", "--bare", "https://h/o/repo.git"], cwd / "repo.git"),
            (["clone", "--bar", "https://h/o/repo.git"], cwd / "repo.git"),
            (["clone", "--mirr", "--temp", "t", "https://h/o/repo"], cwd / "repo.git"),
            (["clone", "--mirror", "https://h/o/repo"], cwd / "repo.git"),
            (["clone", "--bare", "https://h/o/repo", "explicit"], cwd / "explicit"),
            (["clone", "--revision", "v1.0", "https://h/o/repo"], cwd / "repo"),
        ]
        for arguments, expected in cases:
            index = wrapper.command_index(arguments)
            self.assertEqual(wrapper.clone_destination(arguments, index), expected, arguments)

    def history(self, name, children=()):
        """A repository whose content.txt changed: a blob:none clone lacks HEAD~1's blob."""
        self.git_fixture.repository(name, children)
        path = self.git_fixture.project_root / "org" / name
        (path / "content.txt").write_text(name + " second version\n")
        fixture.git(path, "commit", "-am", "second", env=self.env)
        return fixture.git(path, "rev-parse", "HEAD", env=self.env)

    def git_result(self, *arguments, env=None):
        return subprocess.run(["git", *arguments], env=env or self.env, text=True, capture_output=True, timeout=60)

    def assert_lazy_fetch_skips_dead_cache(self, repo, name, spec="HEAD~1:content.txt"):
        self.cache.fail_repo = name
        before = len(self.cache.requests)
        result = self.git_result("-C", str(repo), "show", spec)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cache.requests), before)

    def test_filtered_fetch_from_a_url_is_pinned(self):
        # Git records the URL itself as the promisor remote: there is no remote.<name>.url.
        self.history("hist")
        repo = self.root / "by-url"
        self.assertEqual(self.git_result("init", str(repo)).returncode, 0)
        result = self.git_result(
            "-C", str(repo), "fetch", "--filter=blob:none", self.upstream.url + "/org/hist", "main"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_lazy_fetch_skips_dead_cache(repo, "hist", "FETCH_HEAD~1:content.txt")

    def test_filtered_submodules_are_pinned(self):
        kid = self.history("kid")
        self.git_fixture.repository("top", [("kid-name", "deps/kid", "../kid", kid)])
        top = self.upstream.url + "/org/top"
        recursive = self.root / "recursive"
        result = self.git_result(
            "clone", "--recurse-submodules", "--filter=blob:none", "--also-filter-submodules", top, str(recursive)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_lazy_fetch_skips_dead_cache(recursive / "deps/kid", "kid")
        self.cache.fail_repo = None
        updated = self.root / "updated"
        self.assertEqual(self.git_result("clone", top, str(updated)).returncode, 0)
        result = self.git_result("-C", str(updated), "submodule", "update", "--init", "--filter=blob:none")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_lazy_fetch_skips_dead_cache(updated / "deps/kid", "kid")

    def test_clone_under_an_inherited_git_dir_pins_the_clone(self):
        # git clone ignores GIT_DIR; the pin must not read that other repository.
        self.history("hist")
        other = self.root / "other"
        self.assertEqual(self.git_result("init", str(other)).returncode, 0)
        destination = self.root / "under-git-dir"
        env = dict(self.env, GIT_DIR=str(other / ".git"))
        url = self.upstream.url + "/org/hist"
        result = self.git_result("clone", "--filter=blob:none", url, str(destination), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_lazy_fetch_skips_dead_cache(destination, "hist")

    def test_clustered_short_options_do_not_hide_the_repository(self):
        # In `-nb main`, main is the branch, not the repository.
        self.history("hist")
        url = self.upstream.url + "/org/hist"
        destination = self.root / "clustered"
        result = self.git_result("clone", "-nb", "main", "--filter=blob:none", url, str(destination))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_lazy_fetch_skips_dead_cache(destination, "hist")
        self.cache.fail_status = 404
        retried = self.git_result("clone", "-nb", "main", url, str(self.root / "clustered-retry"))
        self.assertEqual(retried.returncode, 0, retried.stderr)
        wrapper = load_wrapper()
        for arguments, expected in (
            (["clone", "-nb", "main", "u", "d"], "u"),
            (["clone", "--bran", "main", "u", "d"], "u"),
            # An option that is itself the start of a longer one's name.
            (["fetch", "--recurse-submodules", "origin"], "origin"),
            (["fetch", "--recurse-submodules-default", "yes", "origin"], "origin"),
            (["clone", "-bmain", "u"], "u"),
            (["clone", "-nq", "u"], "u"),
            (["fetch", "-qj", "4", "origin"], "origin"),
        ):
            self.assertEqual(wrapper.repository_argument(arguments, 0), expected, arguments)
        self.assertEqual(wrapper.clone_destination(["clone", "-nb", "main", "h:o/r", "d"], 0), Path.cwd() / "d")

    def test_a_failed_recursive_clone_still_pins_what_it_left(self):
        # One submodule cannot be cloned: Git exits 1 and leaves the others in place.
        kid = self.history("kid")
        children = [("kid-name", "deps/kid", "../kid", kid), ("ghost", "deps/ghost", "../ghost", kid)]
        self.git_fixture.repository("top", children)
        destination = self.root / "partly"
        result = self.git_result(
            "clone",
            "--filter=blob:none",
            "--also-filter-submodules",
            "--recurse-submodules",
            self.upstream.url + "/org/top",
            str(destination),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assert_lazy_fetch_skips_dead_cache(destination / "deps/kid", "kid")

    def test_pull_and_remote_update_pin_a_promisor_remote(self):
        self.history("hist")
        for name, command, spec in (
            ("pulled", ["pull", "origin", "main"], "HEAD~1:content.txt"),
            ("updated", ["remote", "update"], "origin/main~1:content.txt"),
        ):
            repo = self.root / name
            self.git_result("init", "-b", "main", str(repo))
            self.git_result("-C", str(repo), "remote", "add", "origin", self.upstream.url + "/org/hist")
            self.git_result("-C", str(repo), "config", "remote.origin.promisor", "true")
            self.git_result("-C", str(repo), "config", "remote.origin.partialclonefilter", "blob:none")
            result = self.git_result("-C", str(repo), *command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_lazy_fetch_skips_dead_cache(repo, "hist", spec)
            self.cache.fail_repo = None

    def test_a_submodule_path_with_a_line_break_is_pinned(self):
        kid = self.history("kid")
        path = "deps/k\nid\u2028x"
        repo = self.git_fixture.project_root / "org" / "odd"
        repo.mkdir(parents=True)
        fixture.git(repo, "init", "--initial-branch=main", env=self.env)
        fixture.git(repo, "config", "-f", ".gitmodules", "submodule.kid.path", path, env=self.env)
        fixture.git(repo, "config", "-f", ".gitmodules", "submodule.kid.url", "../kid", env=self.env)
        fixture.git(repo, "update-index", "--add", "--cacheinfo", f"160000,{kid},{path}", env=self.env)
        fixture.git(repo, "add", ".gitmodules", env=self.env)
        fixture.git(repo, "commit", "-m", "sub", env=self.env)
        destination = self.root / "odd"
        result = self.git_result(
            "clone",
            "--recurse-submodules",
            "--filter=blob:none",
            "--also-filter-submodules",
            self.upstream.url + "/org/odd",
            str(destination),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_lazy_fetch_skips_dead_cache(destination / path, "kid")

    def test_pin_keeps_the_rewrite_the_job_wrote_for_the_remote(self):
        # A later step's own insteadOf, here one that adds a credential, ties with
        # cachew's and loses. The pin must send reads where the job's rewrite does.
        self.history("priv")
        required = "Basic " + base64.b64encode(b"x:JOBPAT").decode()
        self.upstream.required_auth["priv"] = required
        self.cache.required_auth["priv"] = required
        env = dict(self.env, GIT_TERMINAL_PROMPT="0")
        authed = self.upstream.url.replace("http://", "http://x:JOBPAT@")
        subprocess.run(
            [self.real_git, "config", "--global", f"url.{authed}/.insteadOf", self.upstream.url + "/"],
            env=env,
            check=True,
        )
        destination = self.root / "private"
        url = self.upstream.url + "/org/priv"
        result = self.git_result("clone", "--filter=blob:none", url, str(destination), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        lazy = self.git_result("-C", str(destination), "show", "HEAD~1:content.txt", env=env)
        self.assertEqual(lazy.returncode, 0, lazy.stderr)
        fetch = self.git_result("-C", str(destination), "fetch", "origin", env=env)
        self.assertEqual(fetch.returncode, 0, fetch.stderr)
        # The credential stays out of the work tree, which a job may upload whole:
        # the pin that holds it is a session file the repository includes.
        self.assertNotIn("JOBPAT", (destination / ".git/config").read_text())
        included = self.run_git("-C", str(destination), "config", "--local", "--get", "include.path")
        self.assertTrue(Path(included).is_relative_to(self.session), included)
        self.assertEqual(Path(included).stat().st_mode & 0o077, 0)

    def test_a_command_that_turns_off_verification_sends_the_cache_no_token(self):
        # GIT_SSL_NO_VERIFY overrides http.sslVerify. A command the wrapper does
        # not route (here a lazy fetch of a clone Git made by its full path, so
        # unpinned) would send the cache its token over an unverified connection.
        self.history("lazy")
        destination = self.root / "lazy"
        url = self.upstream.url + "/org/lazy"
        subprocess.run(
            [self.real_git, "clone", "--quiet", "--filter=blob:none", url, str(destination)], env=self.env, check=True
        )
        requests = len(self.cache.requests)
        env = dict(self.env, GIT_SSL_NO_VERIFY="")
        result = self.git_result("-C", str(destination), "show", "HEAD~1:content.txt", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(len(self.cache.requests), requests)
        self.assertEqual({auth for _, _, auth in self.cache.requests[requests:]}, {None})

    def test_no_route_sends_the_cache_a_token_over_a_weakened_request(self):
        # Whichever way the wrapper runs a command, as it is or upstream, the
        # command may still reach the cache: a lazy fetch of an unpinned clone, a
        # remote whose URL names the cache. Unverified or redirectable, those
        # requests carry no token.
        self.history("routes")
        host = urllib.parse.urlsplit(self.upstream.url).netloc
        lazy, direct = self.root / "lazy-routes", self.root / "direct-routes"
        clone = [self.real_git, "clone", "--quiet", "--filter=blob:none"]
        subprocess.run([*clone, self.upstream.url + "/org/routes", str(lazy)], env=self.env, check=True)
        subprocess.run([*clone, f"{self.cache.url}/git/{host}/org/routes", str(direct)], env=self.env, check=True)
        weak = ["-c", f"http.{self.cache.url}/git/.followRedirects=true"]
        unverified = dict(self.env, GIT_SSL_NO_VERIFY="")
        for name, arguments, env in (
            ("as it is, weak setting", [*weak, "-C", str(lazy), "show", "HEAD~1:content.txt"], self.env),
            ("upstream view, weak setting", [*weak, "-C", str(direct), "pull"], self.env),
            ("upstream view, unverified", ["-C", str(direct), "pull"], unverified),
            ("push route, unverified", ["-C", str(direct), "remote", "update"], unverified),
        ):
            with self.subTest(name):
                requests = len(self.cache.requests)
                result = self.git_result(*arguments, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreater(len(self.cache.requests), requests)
                self.assertEqual({auth for _, _, auth in self.cache.requests[requests:]}, {None})

    def test_a_clones_own_settings_that_weaken_cache_requests_keep_it_off_the_cache(self):
        # git clone applies its -c/--config options, and the configuration of its
        # template directory, to the new repository before it fetches.
        self.history("cloned")
        url = self.upstream.url + "/org/cloned"
        scope = f"http.{self.cache.url}/git/"
        template = self.root / "template"
        template.mkdir()
        self.config(template / "config", scope + ".sslVerify", "false")
        configured = dict(self.env, GIT_TEMPLATE_DIR=str(template))
        included = self.root / "included.config"
        self.config(included, scope + ".sslVerify", "false")
        for number, (options, env) in enumerate(
            (
                (["-c", scope + ".sslVerify=false"], self.env),
                (["--config", scope + ".followRedirects=true"], self.env),
                (["--config=" + scope + ".followRedirects"], self.env),
                (["--conf", scope + ".sslVerify=off"], self.env),
                (["-qc" + scope + ".sslVerify=0"], self.env),
                (["-nc", scope + ".sslVerify=no", "-b", "main"], self.env),
                (["--template", str(template)], self.env),
                (["--template=" + str(template)], self.env),
                ([], configured),
                # The new repository's configuration then includes the file.
                (["-c", f"include.path={included}"], self.env),
                (["--config", f"Include.Path={included}"], self.env),
                (["-c", f"includeIf.gitdir:{self.root.resolve()}/.path={included}"], self.env),
            )
        ):
            with self.subTest(options=options, template=env is configured):
                requests = len(self.cache.requests)
                result = self.git_result("clone", *options, url, str(self.root / f"cloned-{number}"), env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.cache.requests), requests)
        with self.subTest("init.templateDir"):
            requests = len(self.cache.requests)
            destination = str(self.root / "cloned-configured")
            result = self.git_result("-c", f"init.templateDir={template}", "clone", url, destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(self.cache.requests), requests)
        with self.subTest("the last init.templateDir, as Git reads it"):
            plain = self.root / "plain-template"
            plain.mkdir()
            requests = len(self.cache.requests)
            chosen = ["-c", f"init.templateDir={plain}", "-c", f"init.templateDir={template}"]
            result = self.git_result(*chosen, "clone", url, str(self.root / "cloned-last"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(self.cache.requests), requests)
        requests = len(self.cache.requests)
        harmless = ["-c", "http.https://elsewhere.example/.sslVerify=false", "-b", "main", "-o", "c"]
        self.assertEqual(self.git_result("clone", *harmless, url, str(self.root / "cloned-cache")).returncode, 0)
        self.assertGreater(len(self.cache.requests), requests)

    def test_settings_a_clone_inherits_only_at_its_destination_keep_it_off_the_cache(self):
        # A conditional include applies once the new repository exists (its Git
        # directory, its remote's URL), and a template's configuration may
        # include another file: neither shows in the configuration read before.
        self.history("inherited")
        url = self.upstream.url + "/org/inherited"
        weak = self.root / "weak.config"
        self.config(weak, f"http.{self.cache.url}/git/.sslVerify", "false")
        active = self.session / "global.config"
        template = self.root / "including-template"
        template.mkdir()
        self.config(template / "config", "include.path", str(weak))
        conditional = self.root / "conditional-template"
        conditional.mkdir()
        by_template = self.root / "by-conditional-template"
        self.config(conditional / "config", f"includeIf.gitdir:{by_template.resolve()}/.path", str(weak))
        destination = self.root / "inherited-gitdir"
        cases = (
            (f"includeIf.gitdir:{destination.resolve()}/.path", str(weak), destination, []),
            (f"includeIf.hasconfig:remote.*.url:{self.upstream.url}/**.path", str(weak), self.root / "by-url", []),
            ("", "", self.root / "by-template", ["--template", str(template)]),
            ("", "", by_template, ["--template", str(conditional)]),
        )
        for key, value, target, options in cases:
            with self.subTest(key=key, options=options):
                if key:
                    self.config(active, key, value)
                requests = len(self.cache.requests)
                result = self.git_result("clone", *options, url, str(target))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.cache.requests), requests)
                if key:
                    subprocess.run([self.real_git, "config", "--file", str(active), "--unset-all", key], check=True)

    def test_relative_includes_of_a_clone_resolve_from_its_new_git_directory(self):
        # Git resolves a relative include against the directory of the file that
        # holds it: for the new repository's configuration, its Git directory,
        # wherever the template that configuration was copied from is.
        self.history("relative")
        url = self.upstream.url + "/org/relative"
        work = self.root / "relative"
        (work / "deep" / "er" / "template" / "sub").mkdir(parents=True)
        (work / "nested" / "x" / "template" / "sub").mkdir(parents=True)
        (work / "separate").mkdir()
        self.config(work / "weak.config", f"http.{self.cache.url}/git/.sslVerify", "false")
        self.config(work / "deep" / "er" / "template" / "config", "include.path", "../../weak.config")
        self.config(work / "nested" / "x" / "template" / "config", "include.path", "sub/more.config")
        self.config(work / "nested" / "x" / "template" / "sub" / "more.config", "include.path", "../../../weak.config")
        up = "include.path=../../weak.config"
        cases = (
            ("work tree", [], ["-c", up], str(work / "a")),
            ("bare", [], ["--bare", "-c", "include.path=../weak.config"], str(work / "b.git")),
            ("separate", [], ["--separate-git-dir", str(work / "separate" / "git"), "-c", up], str(work / "c")),
            ("relative destination", ["-C", str(work)], ["-c", up], "d"),
            ("conditional", [], ["-c", f"includeIf.gitdir:{work.resolve()}/.path=../../weak.config"], str(work / "e")),
            ("template", [], ["--template", str(work / "deep" / "er" / "template")], str(work / "f")),
            ("template file", [], ["--template", str(work / "nested" / "x" / "template")], str(work / "g")),
        )
        for name, before, options, destination in cases:
            with self.subTest(name):
                requests = len(self.cache.requests)
                result = self.git_result(*before, "clone", *options, url, destination)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.cache.requests), requests)

    def test_conditional_includes_the_guard_does_not_read_keep_a_clone_off_the_cache(self):
        # The guard reads a bounded number of files. Past that it cannot tell
        # what the new repository inherits, so the clone goes upstream.
        self.history("many")
        weak = self.root / "weak-many.config"
        self.config(weak, f"http.{self.cache.url}/git/.sslVerify", "false")
        destination = self.root / "many-clone"
        text = f'[includeIf "gitdir:{destination.resolve()}/"]\n\tpath = {weak}\n'
        for number in range(load_wrapper().MAX_CONDITIONAL_INCLUDES):
            text += f'[includeIf "gitdir:/elsewhere-{number}/"]\n\tpath = {self.root}/other-{number}.config\n'
        with (self.session / "global.config").open("a") as config:
            config.write(text)
        requests = len(self.cache.requests)
        result = self.git_result("clone", self.upstream.url + "/org/many", str(destination))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cache.requests), requests)
        self.assertIn("Cachew", result.stderr)

    def test_a_job_setting_that_weakens_cache_requests_keeps_the_read_off_the_cache(self):
        # A request to the cache can carry the token. Where the job's own
        # configuration, for the cache's host, turns off certificate verification
        # or allows redirects, Git would apply it: the read goes upstream instead.
        self.history("guarded")
        url = self.upstream.url + "/org/guarded"
        active = self.session / "global.config"
        address = urllib.parse.urlsplit(self.cache.url)
        dotted = f"{address.scheme}://{address.hostname}.:{address.port}"
        for key, value, options in (
            (f"http.{self.cache.url}/git/.sslVerify", "false", []),
            (f"http.{self.cache.url}/git/.followRedirects", "true", []),
            (f"http.{self.cache.url}/.followRedirects", "initial", []),
            ("", "", ["-c", f"http.{self.cache.url}/.sslVerify=false"]),
            # Git reads a host with a trailing dot as the same host.
            (f"http.{dotted}/.sslVerify", "false", []),
        ):
            with self.subTest(key=key, options=options):
                if key:
                    self.config(active, key, value)
                requests = len(self.cache.requests)
                result = self.git_result(*options, "ls-remote", url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.cache.requests), requests)
                self.assertIn("Cachew", result.stderr)
                if key:
                    subprocess.run([self.real_git, "config", "--file", str(active), "--unset-all", key], check=True)
        # GIT_CONFIG names the one file `git config` reads, and no other Git
        # command reads it: it hides no setting from the guard, and no alias.
        legacy = dict(self.env, GIT_CONFIG=os.devnull)
        key = f"http.{self.cache.url}/git/.sslVerify"
        self.config(active, key, "false")
        self.config(active, "alias.look", "ls-remote")
        for command in ("ls-remote", "look"):
            with self.subTest(command=command, GIT_CONFIG=os.devnull):
                requests = len(self.cache.requests)
                result = self.git_result(command, url, env=legacy)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.cache.requests), requests)
                self.assertIn("Cachew", result.stderr)
        subprocess.run([self.real_git, "config", "--file", str(active), "--unset-all", key], check=True)
        requests = len(self.cache.requests)
        self.config(active, "http.https://elsewhere.example/.sslVerify", "false")
        self.config(active, f"http.{self.cache.url}/.sslVerify", "true")
        self.assertEqual(self.git_result("ls-remote", url).returncode, 0)
        self.assertGreater(len(self.cache.requests), requests)


def load_wrapper():
    import importlib.util

    spec = importlib.util.spec_from_file_location("git_wrapper", fixture.ACTION / "git_wrapper.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if __name__ == "__main__":
    unittest.main()

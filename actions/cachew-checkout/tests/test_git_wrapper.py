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
            (["clone", "--mirror", "https://h/o/repo"], cwd / "repo.git"),
            (["clone", "--bare", "https://h/o/repo", "explicit"], cwd / "explicit"),
            (["clone", "--revision", "v1.0", "https://h/o/repo"], cwd / "repo"),
        ]
        for arguments, expected in cases:
            index = wrapper.command_index(arguments)
            self.assertEqual(wrapper.clone_destination(arguments, index), expected, arguments)


def load_wrapper():
    import importlib.util

    spec = importlib.util.spec_from_file_location("git_wrapper", fixture.ACTION / "git_wrapper.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if __name__ == "__main__":
    unittest.main()

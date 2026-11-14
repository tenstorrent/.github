#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Start a cachew session with whichever Node.js this job can run. Composite
# action run steps do not get the runner's bundled Node on PATH, so also look
# where the runner keeps it:
#   * host jobs: <runner root>/externals/node24/bin/node, where RUNNER_TEMP
#     is <runner root>/_work/_temp (tt CI VMs: /opt/runner);
#   * job containers: the runner mounts the same externals at /__e.
# Without a usable Node, or on any error, report ready=false and leave the job
# untouched so the plain checkout runs exactly as actions/checkout would.
set -u

# A session an earlier checkout in this job activated must not outlive a
# not-ready report: the fallback checkout would still be rewritten to the cache.
# Without Node this is done with Git alone. The marker turns the Git wrapper and
# later activations into pass-throughs, and exactly the keys the session wrote
# (index.js lists their names in managed-keys) leave the job's global file;
# everything else in it is the job's own.
#
# As with a ready session, the official checkout then gets a throwaway copy of
# the job's global file (its `git config --global include.path` would replace
# the include that carries the job's own settings), and the restore step
# (restore.sh) points the job back at the real file afterwards.
disable_existing_session() {
  local directory=${CACHEW_SESSION_DIR:-} global fallback key
  local -a managed=()
  [ -n "$directory" ] && [ -f "$directory/global.config" ] || return 0
  global=$directory/global.config
  (umask 077 && : >"$directory/cache-disabled") || true
  [ -f "$directory/managed-keys" ] && mapfile -t managed <"$directory/managed-keys"
  for key in "${managed[@]}"; do
    git config --file "$global" --unset-all "$key" >/dev/null 2>&1 || true
  done
  fallback=$directory/fallback-checkout.config
  # The copy skips them too: removal from the job's file fails while it is locked.
  (umask 077 && : >"$fallback") && flatten "$global" "$fallback" "${managed[@]}" || return 0
  # restore.sh copies back only the safe.directory entries the checkout adds after these.
  git config --file "$fallback" --null --get-all safe.directory 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ' \
    >"$fallback.safe-directories" || return 0
  [ -n "${GITHUB_ENV:-}" ] && echo "GIT_CONFIG_GLOBAL=$fallback" >>"$GITHUB_ENV"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "fallback-config=$fallback" >>"$GITHUB_OUTPUT"
  return 0
}

# Appends <source>'s entries to <target>, inlining unconditional includes and
# keeping conditional ones as directives, like the helper's flatten (index.js):
# the checkout may replace include.path, so nothing may depend on it. Entries
# are written as text, never as Git arguments, since values may be credentials.
# Keys named after <source> <target> are left out.
flatten() {
  local source=$1 target=$2 entry key value skip
  shift 2
  while IFS= read -r -d '' entry; do
    key=${entry%%$'\n'*}
    if [ "$key" = "$entry" ]; then value=true; else value=${entry#*$'\n'}; fi
    for skip in "$@"; do [ "${key,,}" = "${skip,,}" ] && continue 2; done
    if [ "$key" = include.path ]; then
      [ -f "$value" ] && { flatten "$value" "$target" "$@" || return 1; }
      continue
    fi
    render "$key" "$value" >>"$target" || return 1
  done < <(git config --file "$source" --no-includes --null --list 2>/dev/null)
}

# One entry in Git's config syntax, as index.js's entry() writes it.
render() {
  local key=$1 section=${1%%.*} name=${1##*.} subsection=""
  [ "$section.$name" = "$key" ] || { subsection=${key#*.}; subsection=" $(quote "${subsection%.*}")"; }
  printf '[%s%s]\n\t%s = %s\n' "$section" "$subsection" "$name" "$(quote "$2")"
}

quote() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//$'\n'/\\n}
  v=${v//$'\r'/\\n}
  v=${v//$'\t'/\\t}
  printf '"%s"' "$v"
}

not_ready() {
  disable_existing_session
  echo "$1; using standard checkout only."
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "ready=false" >>"$GITHUB_OUTPUT"
  exit 0
}

candidates=()
if path_node=$(command -v node 2>/dev/null); then candidates+=("$path_node"); fi
if [ -n "${RUNNER_TEMP:-}" ]; then
  runner_root=$(cd "$RUNNER_TEMP/../.." 2>/dev/null && pwd -P) || runner_root=""
  if [ -n "$runner_root" ]; then
    candidates+=("$runner_root/externals/node24/bin/node")
  fi
fi
candidates+=("/__e/node24/bin/node")

node_bin=""
for candidate in "${candidates[@]}"; do
  [ -x "$candidate" ] || continue
  # Rejects binaries that cannot run here (e.g. glibc Node in an Alpine container) and
  # end-of-life Node (20 and older).
  if "$candidate" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1; then
    node_bin=$candidate
    break
  fi
done
[ -n "$node_bin" ] || not_ready "Node.js 22+ unavailable"

"$node_bin" "$(dirname "${BASH_SOURCE[0]}")/index.js" prepare || not_ready "Cachew session could not start"

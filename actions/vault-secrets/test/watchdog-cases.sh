#!/usr/bin/env bash
# shellcheck disable=SC2015 # "check && echo OK || fail": echo does not fail.
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs watchdog.sh directly, without Vault or the network. Dummy node processes
# stand in for hashicorp/vault-action: their command line has the same form,
#   node <work>/_actions/hashicorp/vault-action/<ref>/dist/index.js
# so the test uses the default pattern of watchdog.sh. Needs node and pgrep.
# Takes about 30 seconds. Uses no token and no secret.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
watchdog="$here/../watchdog.sh"
work="$(mktemp -d)"
pids=()
# shellcheck disable=SC2329 # Called by the EXIT trap.
cleanup() {
  local p
  for p in "${pids[@]+"${pids[@]}"}"; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

command -v node >/dev/null || { echo "::error::node is not available"; exit 1; }
command -v pgrep >/dev/null || { echo "::error::pgrep is not available"; exit 1; }

limit=3
status=0
mkdir -p "$work/ws" "$work/temp" "$work/other/dist"
target_dir="$work/_actions/hashicorp/vault-action/0123abcd/dist"
mkdir -p "$target_dir"
# Runs for $1 seconds.
printf 'setTimeout(() => {}, Number(process.argv[2]) * 1000);\n' >"$target_dir/index.js"
cp "$target_dir/index.js" "$work/other/dist/index.js"

# Starts a dummy process (script $1, runs $2 seconds). Sets dummy to its PID.
start_dummy() {
  node "$1" "$2" &
  dummy=$!
  pids+=("$dummy")
}

# Runs watchdog.sh $1 like the action does. Sets rc, log and id.
run_watchdog() {
  local out="$work/out"
  : >"$out"
  rc=0
  env -i PATH="$PATH" \
    RUNNER_TEMP="$work/temp" \
    RUNNER_WORKSPACE="$work/ws" \
    GITHUB_OUTPUT="$out" \
    VAULT_TIMEOUT="$limit" \
    WATCHDOG_ID="${id:-}" \
    bash "$watchdog" "$1" >"$work/log" 2>&1 || rc=$?
  log="$(cat "$work/log")"
  if [ "$1" = start ]; then
    id="$(sed -n 's/^id=//p' "$out")"
    wd_pid="$(cat "$work/temp/vault-secrets-watchdog-$id.pid" 2>/dev/null || true)"
  fi
}

alive() { kill -0 "$1" 2>/dev/null; }

fail() {
  echo "::error::$1"
  [ -z "${log:-}" ] || printf '%s\n' "$log"
  status=1
}

# Waits up to $2 seconds until process $1 is gone. Returns 1 if it still runs.
gone_within() {
  local i
  for ((i = 0; i < $2 * 2; i++)); do
    alive "$1" || return 0
    sleep 0.5
  done
  return 1
}

# ── Case 1: the target runs too long ──────────────────────────────────────────
echo "Case 1: the Vault step runs longer than the limit."
id=""
run_watchdog start
[ "$rc" -eq 0 ] && [ -n "$id" ] && [ -n "$wd_pid" ] || fail "case 1: start failed (rc $rc, id '$id')"
start_dummy "$target_dir/index.js" 300
target=$dummy
start_dummy "$work/other/dist/index.js" 300
bystander=$dummy
if gone_within "$target" $((limit + 6)); then
  echo "OK: the watchdog stopped the target."
else
  fail "case 1: the target still runs after $((limit + 6)) seconds"
fi
alive "$bystander" && echo "OK: a process with another path still runs." \
  || fail "case 1: the watchdog stopped a process that does not match"
kill -KILL "$bystander" 2>/dev/null || true
[ -e "$work/temp/vault-secrets-watchdog-$id.marker" ] && echo "OK: the marker exists." \
  || fail "case 1: no marker file"
gone_within "$wd_pid" 3 && echo "OK: the watchdog exited." || fail "case 1: the watchdog still runs"
run_watchdog stop
want="::error title=vault-secrets::Vault did not answer within $limit seconds."
if [ "$rc" -ne 0 ] && printf '%s\n' "$log" | grep -q -F -- "$want"; then
  echo "OK: the stop step failed with the message."
else
  fail "case 1: stop step: rc $rc, expected a failure with '$want'"
fi
[ -z "$(ls -A "$work/temp")" ] && echo "OK: no files left." || fail "case 1: files left in RUNNER_TEMP"

# ── Case 2: the target ends in time ───────────────────────────────────────────
echo "Case 2: the Vault step ends in time."
id=""
run_watchdog start
[ "$rc" -eq 0 ] && [ -n "$id" ] || fail "case 2: start failed (rc $rc)"
start_dummy "$target_dir/index.js" 1
target=$dummy
wait "$target" 2>/dev/null || true
gone_within "$wd_pid" 3 && echo "OK: the watchdog exited after the target ended." \
  || fail "case 2: the watchdog still runs after the target ended"
[ ! -e "$work/temp/vault-secrets-watchdog-$id.marker" ] && echo "OK: no marker." \
  || fail "case 2: marker file exists"
run_watchdog stop
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$log" | grep -q -F '::error'; then
  echo "OK: the stop step passed without an error."
else
  fail "case 2: stop step: rc $rc, expected success without an error"
fi

# ── Case 3: an old watchdog does not stop a later call ────────────────────────
echo "Case 3: a later process with the same pattern is not stopped."
id=""
run_watchdog start
[ "$rc" -eq 0 ] && [ -n "$id" ] || fail "case 3: start failed (rc $rc)"
start_dummy "$target_dir/index.js" 1
first=$dummy
wait "$first" 2>/dev/null || true
# The stop step of the first call does not run here: the watchdog must still
# leave the second process alone.
start_dummy "$target_dir/index.js" 300
second=$dummy
sleep $((limit + 4))
alive "$second" && echo "OK: the later process still runs after the limit." \
  || fail "case 3: the old watchdog stopped a later process"
[ ! -e "$work/temp/vault-secrets-watchdog-$id.marker" ] && echo "OK: no marker." \
  || fail "case 3: marker file exists"
alive "$wd_pid" && fail "case 3: the old watchdog still runs" || echo "OK: the old watchdog exited."
kill -KILL "$second" 2>/dev/null || true
run_watchdog stop
[ "$rc" -eq 0 ] && echo "OK: the stop step passed." || fail "case 3: stop step failed (rc $rc)"

# ── Case 4: the stop step stops a watchdog that still waits ───────────────────
echo "Case 4: the stop step ends a waiting watchdog (the action failed earlier)."
limit=60
id=""
run_watchdog start
[ "$rc" -eq 0 ] && [ -n "$wd_pid" ] || fail "case 4: start failed (rc $rc)"
run_watchdog stop
[ "$rc" -eq 0 ] || fail "case 4: stop step failed (rc $rc)"
gone_within "$wd_pid" 2 && echo "OK: the stop step ended the watchdog." \
  || fail "case 4: the watchdog still runs after the stop step"

# ── Case 5: no pgrep ──────────────────────────────────────────────────────────
echo "Case 5: no pgrep on the runner."
nopgrep="$work/bin"
mkdir -p "$nopgrep"
for tool in bash env; do ln -s "$(command -v "$tool")" "$nopgrep/$tool"; done
rc=0
env -i PATH="$nopgrep" RUNNER_TEMP="$work/temp" RUNNER_WORKSPACE="$work/ws" \
  GITHUB_OUTPUT="$work/out" VAULT_TIMEOUT=60 \
  "$nopgrep/bash" "$watchdog" start >"$work/log" 2>&1 || rc=$?
log="$(cat "$work/log")"
if [ "$rc" -eq 0 ] && printf '%s\n' "$log" | grep -q -F '::warning title=vault-secrets::pgrep is not available'; then
  echo "OK: start passed with a warning."
else
  fail "case 5: rc $rc, expected success with a warning"
fi

exit "$status"

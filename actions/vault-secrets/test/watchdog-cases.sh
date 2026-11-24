#!/usr/bin/env bash
# shellcheck disable=SC2015 # "check && echo OK || fail": echo does not fail.
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs watchdog.sh directly, without Vault or the network. Dummy node processes
# stand in for hashicorp/vault-action: their command line has the same form,
#   node <work>/_actions/hashicorp/vault-action/<ref>/dist/index.js
# so the test uses the default pattern of watchdog.sh. Needs node and pgrep.
# Also checks the attached record of each call. Takes about 25 seconds. Uses no token and no secret.
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
# Runs for $1 seconds at most. With a second argument (a file name), it ends
# as soon as that file exists. Cases use the file to end a process on a
# condition, not after a fixed time, so a slow runner cannot change the result.
cat >"$target_dir/index.js" <<'JS'
const fs = require('fs');
const end = Date.now() + Number(process.argv[2]) * 1000;
const release = process.argv[3];
setInterval(() => {
  if (Date.now() >= end || (release && fs.existsSync(release))) process.exit(0);
}, 50);
JS
cp "$target_dir/index.js" "$work/other/dist/index.js"

# Starts a dummy process (script $1, runs $2 seconds at most, ends when file $3
# exists). Sets dummy to its PID.
start_dummy() {
  node "$1" "$2" ${3:+"$3"} &
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
    VAULT_OUTCOME="${outcome:-}" \
    bash "$watchdog" "$1" >"$work/log" 2>&1 || rc=$?
  log="$(cat "$work/log")"
  if [ "$1" = start ]; then
    id="$(sed -n 's/^id=//p' "$out")"
    wd_pid="$(cat "$wd/$id.pid" 2>/dev/null || true)"
  fi
}

wd="$work/temp/vault-secrets-watchdog"

alive() { kill -0 "$1" 2>/dev/null; }

# Fails unless the attached record of call $id names the target script.
attached_ok() {
  if grep -q -F -- "$target_dir/index.js" "$wd/$id.attached" 2>/dev/null; then
    echo "OK: attached record: $(cat "$wd/$id.attached")"
  else
    fail "$1: no attached record with the target command line"
  fi
}

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

# Waits up to $1 seconds until the attached record of call $id exists.
attached_within() {
  local i
  for ((i = 0; i < $1 * 10; i++)); do
    [ -s "$wd/$id.attached" ] && return 0
    sleep 0.1
  done
  return 1
}

# Wall-clock limits below are for failures only: each wait ends as soon as its
# condition holds. The watchdog limit is long enough that a slow runner does
# not reach it before the case has done its work.
wait_max=30

# ── Case 1: the target runs too long ──────────────────────────────────────────
echo "Case 1: the Vault step runs longer than the limit."
# The processes run before the watchdog starts: the limit cannot run out while
# a slow runner still starts node.
start_dummy "$target_dir/index.js" 300
target=$dummy
start_dummy "$work/other/dist/index.js" 300
bystander=$dummy
id=""
run_watchdog start
[ "$rc" -eq 0 ] && [ -n "$id" ] && [ -n "$wd_pid" ] || fail "case 1: start failed (rc $rc, id '$id')"
if gone_within "$target" $((limit + wait_max)); then
  echo "OK: the watchdog stopped the target."
else
  fail "case 1: the target still runs after $((limit + wait_max)) seconds"
fi
alive "$bystander" && echo "OK: a process with another path still runs." \
  || fail "case 1: the watchdog stopped a process that does not match"
kill -KILL "$bystander" 2>/dev/null || true
[ -e "$wd/$id.marker" ] && echo "OK: the marker exists." \
  || fail "case 1: no marker file"
attached_ok "case 1"
gone_within "$wd_pid" "$wait_max" && echo "OK: the watchdog exited." || fail "case 1: the watchdog still runs"
outcome=failure
run_watchdog stop
want="::error title=vault-secrets::Vault did not answer within $limit seconds."
if [ "$rc" -ne 0 ] && printf '%s\n' "$log" | grep -q -F -- "$want"; then
  echo "OK: the stop step failed with the message."
else
  fail "case 1: stop step: rc $rc, expected a failure with '$want'"
fi
left="$(cd "$wd" && echo *)"
[ "$left" = "$id.attached" ] && echo "OK: only the attached record is left." \
  || fail "case 1: other files left: $left"

# ── Case 2: the target ends in time (a short Vault step) ─────────────────────
# Five times: the watchdog must find a short process and leave it alone. The
# process ends when the attached record exists, not after a fixed time, and
# the limit is long: the result does not depend on runner speed.
limit=$wait_max
for n in 1 2 3 4 5; do
  echo "Case 2.$n: the Vault step ends in time."
  id=""
  run_watchdog start
  [ "$rc" -eq 0 ] && [ -n "$id" ] || fail "case 2.$n: start failed (rc $rc)"
  rm -f "$work/release"
  start_dummy "$target_dir/index.js" 120 "$work/release"
  target=$dummy
  attached_within "$wait_max" || fail "case 2.$n: the watchdog did not find the process"
  : >"$work/release"
  wait "$target" 2>/dev/null || true
  gone_within "$wd_pid" "$wait_max" && echo "OK: the watchdog exited after the target ended." \
    || fail "case 2.$n: the watchdog still runs after the target ended"
  [ ! -e "$wd/$id.marker" ] && echo "OK: no marker." \
    || fail "case 2.$n: marker file exists"
  attached_ok "case 2.$n"
  outcome=success
  run_watchdog stop
  if [ "$rc" -eq 0 ] && [ "$log" = "The time limit watched the Vault step." ]; then
    echo "OK: the stop step passed and wrote that it watched the Vault step."
  else
    fail "case 2.$n: stop step: rc $rc, expected success with the 'watched' line only"
  fi
done

# ── Case 3: an old watchdog does not stop a later call ────────────────────────
echo "Case 3: a later process with the same pattern is not stopped."
case3_start=$SECONDS
limit=6
rm -f "$work/release"
start_dummy "$target_dir/index.js" 120 "$work/release"
first=$dummy
id=""
run_watchdog start
[ "$rc" -eq 0 ] && [ -n "$id" ] || fail "case 3: start failed (rc $rc)"
attached_within "$wait_max" || fail "case 3: the watchdog did not find the first process"
: >"$work/release"
wait "$first" 2>/dev/null || true
# The stop step of the first call does not run here: the watchdog must still
# leave the second process alone, also after its own limit has passed.
start_dummy "$target_dir/index.js" 300
second=$dummy
gone_within "$wd_pid" "$wait_max" || fail "case 3: the old watchdog does not exit"
[ "$SECONDS" -ge "$((case3_start + limit + 2))" ] || sleep $((case3_start + limit + 2 - SECONDS))
alive "$second" && echo "OK: the later process still runs after the limit." \
  || fail "case 3: the old watchdog stopped a later process"
[ ! -e "$wd/$id.marker" ] && echo "OK: no marker." \
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
outcome=skipped
run_watchdog stop
[ "$rc" -eq 0 ] && [ -z "$log" ] && echo "OK: the stop step passed without a message (Vault step skipped)." \
  || fail "case 4: stop step: rc $rc, expected success without a message"
gone_within "$wd_pid" "$wait_max" && echo "OK: the stop step ended the watchdog." \
  || fail "case 4: the watchdog still runs after the stop step"

# ── Case 4b: the Vault step ran, but the watchdog did not find it ────────────
echo "Case 4b: the Vault step ran and the watchdog did not find it."
id=""
run_watchdog start
[ "$rc" -eq 0 ] && [ -n "$wd_pid" ] || fail "case 4b: start failed (rc $rc)"
outcome=failure
run_watchdog stop
want='::warning title=vault-secrets::the time limit did not find the Vault step.'
if [ "$rc" -eq 0 ] && printf '%s\n' "$log" | grep -q -F -- "$want"; then
  echo "OK: the stop step passed with a warning."
else
  fail "case 4b: stop step: rc $rc, expected success with '$want'"
fi

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

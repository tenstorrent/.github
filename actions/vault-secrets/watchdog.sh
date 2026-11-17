#!/usr/bin/env bash
# Time limit for the Vault step. A composite action step cannot have
# timeout-minutes, and hashicorp/vault-action has no timeout input: one stalled
# HTTP request can hold the step until the TCP stack gives up (about 16 minutes
# on Linux). This script stops the vault-action process after a time limit.
#
#   watchdog.sh start   Starts a background watchdog for one call of the action.
#                       Writes output id. Never fails the step: if it cannot
#                       start, it writes a warning and the Vault step runs
#                       without a time limit.
#   watchdog.sh stop    Stops the watchdog of this call. Fails with an error
#                       message if the watchdog stopped the Vault step. Writes
#                       a warning if the Vault step ran and the watchdog did
#                       not find its process (the step ran without a limit).
#   watchdog.sh loop    The background watchdog. Started by `start` only.
#
# The watchdog takes the FIRST process that matches the pattern as its target
# and writes its command line to the attached record. Until then it looks
# every 0.1 second, so it also finds a Vault step of about 0.5 second.
# It exits when that process ends, or after it stops the process, or at the
# time limit. It never stops a process that starts after its target, so it
# cannot stop the Vault step of a later call in the same job.
#
# Reads (start): VAULT_TIMEOUT RUNNER_TEMP RUNNER_WORKSPACE GITHUB_OUTPUT
#                VAULT_WATCHDOG_PATTERN (optional; tests set it)
# Reads (stop):  VAULT_TIMEOUT VAULT_OUTCOME RUNNER_TEMP WATCHDOG_ID
# Files in $RUNNER_TEMP/vault-secrets-watchdog/, per call:
#   <id>.pid       PID of the watchdog (removed by stop)
#   <id>.marker    the watchdog stopped the Vault step (removed by stop)
#   <id>.attached  command line of the process it watched (kept; tests count it)
set -euo pipefail

warn() {
  printf '::warning title=vault-secrets::%s\n' "$1"
}

files() {
  dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/vault-secrets-watchdog"
  pid_file="$dir/$1.pid"
  marker="$dir/$1.marker"
  attached="$dir/$1.attached"
}

# Escapes a path for use in an extended regular expression.
ere_escape() {
  printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|/]/\\&/g'
}

# The node process of hashicorp/vault-action in this runner's work folder:
#   <node> <work>/_actions/hashicorp/vault-action/<ref>/dist/index.js
default_pattern() {
  local work
  [ -n "${RUNNER_WORKSPACE:-}" ] || return 1
  work="$(dirname "$RUNNER_WORKSPACE")"
  printf '^[^ ]*node[0-9]* %s/_actions/hashicorp/vault-action/[^/ ]+/dist/index\\.js( |$)' \
    "$(ere_escape "$work")"
}

# Prints the PIDs of this user's processes that match the pattern.
matching() {
  pgrep -u "$uid" -f -- "$WATCHDOG_PATTERN" 2>/dev/null || true
}

do_start() {
  local limit="${VAULT_TIMEOUT:-}" id pattern
  if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
    warn "no valid time limit for the Vault step ('$limit'). The Vault step runs without a time limit."
    return 0
  fi
  if ! command -v pgrep >/dev/null 2>&1; then
    warn "pgrep is not available on this runner. The Vault step runs without a time limit."
    return 0
  fi
  if [ -z "${RUNNER_TEMP:-}" ] || [ ! -d "$RUNNER_TEMP" ]; then
    warn "RUNNER_TEMP is not set. The Vault step runs without a time limit."
    return 0
  fi
  pattern="${VAULT_WATCHDOG_PATTERN:-}"
  if [ -z "$pattern" ] && ! pattern="$(default_pattern)"; then
    warn "RUNNER_WORKSPACE is not set. The Vault step runs without a time limit."
    return 0
  fi

  id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  files "$id"
  mkdir -p "$dir"
  rm -f "$pid_file" "$marker" "$attached"

  # Detach: no stdio, own session if setsid exists, so the step does not wait.
  local -a detach=(nohup)
  if command -v setsid >/dev/null 2>&1; then detach=(nohup setsid); fi
  WATCHDOG_LIMIT="$limit" WATCHDOG_PATTERN="$pattern" \
    WATCHDOG_PID_FILE="$pid_file" WATCHDOG_MARKER="$marker" \
    WATCHDOG_ATTACHED="$attached" \
    "${detach[@]}" bash "${BASH_SOURCE[0]}" loop </dev/null >/dev/null 2>&1 &

  # The watchdog writes its own PID. Wait for it, at most 5 seconds.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$pid_file" ] && break
    sleep 0.5
  done
  if [ ! -s "$pid_file" ]; then
    warn "the time limit for the Vault step did not start. The Vault step runs without a time limit."
    return 0
  fi
  printf 'id=%s\n' "$id" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
  echo "Time limit for the Vault step: $limit seconds."
}

do_loop() {
  local limit="$WATCHDOG_LIMIT" target="" deadline
  uid="$(id -u)"
  printf '%s\n' "$$" >"$WATCHDOG_PID_FILE"
  deadline=$((SECONDS + limit))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -z "$target" ]; then
      target="$(matching | head -n 1)"
      if [ -n "$target" ]; then
        # The command line has the node and script paths only, no value.
        ps -p "$target" -o args= >"$WATCHDOG_ATTACHED" 2>/dev/null || true
        [ -s "$WATCHDOG_ATTACHED" ] || echo "pid $target" >"$WATCHDOG_ATTACHED"
      fi
      sleep 0.1
    elif ! kill -0 "$target" 2>/dev/null; then
      exit 0 # The Vault step ended in time.
    else
      sleep 1
    fi
  done
  [ -n "$target" ] || exit 0
  # Stop the target only if it still runs and still matches.
  matching | grep -q -x -- "$target" || exit 0
  : >"$WATCHDOG_MARKER"
  kill -TERM "$target" 2>/dev/null || exit 0
  for _ in 1 2 3 4 5; do
    kill -0 "$target" 2>/dev/null || exit 0
    sleep 1
  done
  kill -KILL "$target" 2>/dev/null || true
}

do_stop() {
  local id="${WATCHDOG_ID:-}" pid args
  [[ "$id" =~ ^[0-9a-f]+$ ]] || return 0 # The watchdog did not start.
  files "$id"
  if [ -s "$pid_file" ]; then
    pid="$(cat "$pid_file")"
    args=""
    [[ "$pid" =~ ^[0-9]+$ ]] && args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    # Stop it only if the PID is still this watchdog.
    if [[ "$args" == *'watchdog.sh loop'* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
    fi
  fi
  rm -f "$pid_file"
  if [ -e "$marker" ]; then
    rm -f "$marker"
    printf '::error title=vault-secrets::%s\n' "Vault did not answer within ${VAULT_TIMEOUT:-?} seconds. The action stopped the Vault step. The likely cause is a stalled network connection on the tailnet. Run the job again."
    return 1
  fi
  if [ -s "$attached" ]; then
    echo "The time limit watched the Vault step."
  elif [ "${VAULT_OUTCOME:-}" = success ] || [ "${VAULT_OUTCOME:-}" = failure ]; then
    warn "the time limit did not find the Vault step. The Vault step ran without a time limit."
  fi
}

case "${1:-}" in
  start) do_start ;;
  stop) do_stop ;;
  loop) do_loop ;;
  *)
    echo "usage: watchdog.sh start|stop" >&2
    exit 2
    ;;
esac

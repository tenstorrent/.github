#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Fails unless the time limit of the action found the Vault step process in
# each call of this job: one attached record per call in
# $RUNNER_TEMP/vault-secrets-watchdog/. Prints the command lines of the
# watched processes (node and script paths, no value).
#
# Reads: RUNNER_TEMP EXPECT_COUNT
set -euo pipefail

dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/vault-secrets-watchdog"
want="${EXPECT_COUNT:?EXPECT_COUNT is not set}"
count=0
for f in "$dir"/*.attached; do
  [ -s "$f" ] || continue
  count=$((count + 1))
  echo "Watched: $(cat "$f")"
done
if [ "$count" -ne "$want" ]; then
  echo "::error::expected $want attached record(s) of the time limit, found $count"
  exit 1
fi
echo "OK: the time limit watched the Vault step in each of the $count call(s)."

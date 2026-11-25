#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Fails unless the action step failed in the expected step of the action and
# left both outputs empty. Never prints a token or secrets output value.
#
# Reads: OUTCOME TOKEN SECRETS FAILED_STEP EXPECT_STEP
# Optional: TOKENS (output tokens, release 1.2): must be empty or '{}'.
# EXPECT_STEP is prepare, join, wait, vault or check (output failed-step).
# The direct tests (prepare-cases.sh, wait-cases.sh) check the message of each
# step. This check proves that the action stopped in that step.
set -euo pipefail

status=0
if [ -z "${EXPECT_STEP:-}" ]; then
  echo "::error::EXPECT_STEP is not set"
  exit 1
fi
if [ "$OUTCOME" != failure ]; then
  echo "::error::expected the action to fail, but its outcome is '$OUTCOME'"
  status=1
fi
if [ -n "$TOKEN" ]; then
  echo "::error::output token is not empty"
  status=1
fi
compact="$(printf '%s' "$SECRETS" | tr -d '[:space:]')"
if [ -n "$compact" ] && [ "$compact" != '{}' ]; then
  echo "::error::output secrets is not empty"
  status=1
fi
compact="$(printf '%s' "${TOKENS:-}" | tr -d '[:space:]')"
if [ -n "$compact" ] && [ "$compact" != '{}' ]; then
  echo "::error::output tokens is not empty"
  status=1
fi
if [ "${FAILED_STEP:-}" != "$EXPECT_STEP" ]; then
  echo "::error::expected the action to fail in step '$EXPECT_STEP', but output failed-step is '${FAILED_STEP:-}'"
  status=1
fi
[ "$status" -ne 0 ] || echo "OK: the action failed in step '$EXPECT_STEP' and both outputs are empty."
exit "$status"

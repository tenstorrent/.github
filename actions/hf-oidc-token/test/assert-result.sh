#!/usr/bin/env bash
# Test helper for .github/workflows/hf-oidc-token-test.yml. Not used by the action.
# Fails unless the action step has the expected outcome, stopped in the
# expected step (output failed-step), and gave no token. Never prints a token.
#
# Reads: OUTCOME EXPECT_OUTCOME TOKEN EXPIRES_AT FAILED_STEP EXPECT_STEP
set -euo pipefail

status=0
if [ "${OUTCOME:-}" != "${EXPECT_OUTCOME:?EXPECT_OUTCOME is not set}" ]; then
  echo "::error::expected outcome '$EXPECT_OUTCOME', got '${OUTCOME:-}'"
  status=1
fi
if [ -n "${TOKEN:-}" ]; then
  echo "::error::output token is not empty"
  status=1
fi
if [ -n "${EXPIRES_AT:-}" ]; then
  echo "::error::output expires-at is not empty"
  status=1
fi
if [ "${FAILED_STEP:-}" != "${EXPECT_STEP:?EXPECT_STEP is not set}" ]; then
  echo "::error::expected failed-step '$EXPECT_STEP', got '${FAILED_STEP:-}'"
  status=1
fi
[ "$status" -ne 0 ] || echo "OK: outcome $OUTCOME, failed-step $FAILED_STEP, no token."
exit "$status"

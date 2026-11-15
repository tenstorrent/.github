#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Fails unless the action step failed and left both outputs empty.
# Never prints an output value.
#
# Reads: OUTCOME TOKEN SECRETS
set -euo pipefail

status=0
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
[ "$status" -ne 0 ] || echo "OK: the action failed and both outputs are empty."
exit "$status"

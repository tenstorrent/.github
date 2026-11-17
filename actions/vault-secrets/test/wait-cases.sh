#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs wait-for-vault.sh directly against a local port that has no server.
# Checks that it fails with its own message. Takes about 12 seconds
# (6 attempts, 2 seconds apart). Uses no network, no token and no secret.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wait_script="$here/../wait-for-vault.sh"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Port 9 (discard) on the loopback address: the connection is refused at once.
url='http://127.0.0.1:9'
rc=0
env -i PATH="$PATH" VAULT_URL="$url" bash "$wait_script" >"$log" 2>&1 || rc=$?

want="::error title=vault-secrets::Vault $url is not reachable."
if [ "$rc" -eq 0 ]; then
  echo "::error::wait-for-vault.sh succeeded, expected a failure"
  cat "$log"
  exit 1
fi
if ! grep -q -F -- "$want" "$log"; then
  echo "::error::wait-for-vault.sh failed, but not with the message '$want'"
  cat "$log"
  exit 1
fi
echo "OK: wait-for-vault.sh failed with its message for $url."

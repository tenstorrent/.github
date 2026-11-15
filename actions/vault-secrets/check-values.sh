#!/usr/bin/env bash
# Fails when a value that the caller asked for is empty.
# Reads: VAULT_OUTPUTS (JSON object of the vault step outputs). Prints names only.
set -euo pipefail

empty="$(jq -r 'to_entries[] | select((.value // "") == "") | .key' <<<"$VAULT_OUTPUTS")"
if [ -n "$empty" ]; then
  while IFS= read -r name; do
    [ "$name" = "VAULT_SECRETS_GITHUB_TOKEN" ] && name="github-token"
    echo "::error::Vault gave an empty value for ${name}. The value stored in Vault is empty. Ask the owner of the secret to store it again."
  done <<<"$empty"
  exit 1
fi

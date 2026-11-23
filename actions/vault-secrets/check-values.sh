#!/usr/bin/env bash
# Fails when a value that the caller asked for is empty. Then writes the
# output secrets: the outputs of the read step (vault-action), plus the token
# from the token step (read-token.sh) under the key VAULT_SECRETS_GITHUB_TOKEN.
# Reads:  VAULT_OUTPUTS (JSON object of the vault step outputs; '{}' when the
#         step did not run), TOKEN_VALUE (output token of the token step, or
#         empty), GITHUB_OUTPUT
# Writes: output secrets. Prints names only. Values stay in env and stdin,
# never in argv.
set -euo pipefail

TOKEN_OUTPUT='VAULT_SECRETS_GITHUB_TOKEN'

merged="$(jq --arg key "$TOKEN_OUTPUT" \
  '. + (if (env.TOKEN_VALUE // "") != "" then {($key): env.TOKEN_VALUE} else {} end)' \
  <<<"${VAULT_OUTPUTS:-{\}}")"

empty="$(jq -r 'to_entries[] | select((.value // "") == "") | .key' <<<"$merged")"
if [ -n "$empty" ]; then
  while IFS= read -r name; do
    [ "$name" = "$TOKEN_OUTPUT" ] && name="github-token"
    echo "::error::Vault gave an empty value for ${name}. The value stored in Vault is empty. Ask the owner of the secret to store it again."
  done <<<"$empty"
  exit 1
fi

delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$merged" != *"$delimiter"* ]] || { echo "::error::internal error: output delimiter collision. Run the job again."; exit 1; }
printf 'secrets<<%s\n%s\n%s\n' "$delimiter" "$merged" "$delimiter" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
merged=""

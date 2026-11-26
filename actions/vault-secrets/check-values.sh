#!/usr/bin/env bash
# Fails when a value that the caller asked for is empty. Then writes the
# output secrets: the outputs of the read step (vault-action), plus the token
# from the token step (read-token.sh) under the key VAULT_SECRETS_GITHUB_TOKEN.
# Release 1.2: also writes the output tokens, a JSON object key -> token for
# each entry of github-token that is a key or a full name ('{}' for none, or
# for a Vault path). With a list, every token of the list must be there and
# not empty, and the first must be the token of output token.
# Reads:  VAULT_OUTPUTS (JSON object of the vault step outputs; '{}' when the
#         step did not run), TOKEN_VALUE (output token of the token step, or
#         empty), GITHUB_OUTPUT
#         TOKEN_LIST (output token-list of the prepare step, or empty),
#         TOKENS_VALUE (output tokens of the token step; only with a list)
# Writes: outputs secrets and tokens. Prints names only. Values stay in env
# and stdin, never in argv.
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

# Output tokens. One entry: the token of the token step under its key. A list:
# the tokens of the token step, checked against the list.
list="${TOKEN_LIST:-}"
[ -n "$list" ] || list='[]'
count="$(jq -r 'length' <<<"$list")"
if [ "$count" -eq 0 ]; then
  tokens='{}'
elif [ "$count" -eq 1 ]; then
  if [ -z "${TOKEN_VALUE:-}" ]; then
    echo "::error::Vault gave an empty value for github-token."
    exit 1
  fi
  tokens="$(jq -c '{(.[0].key): env.TOKEN_VALUE}' <<<"$list")"
else
  # Keys of the list without a token, or with an empty token.
  empty="$(jq -r '(env.TOKENS_VALUE // "" | if . == "" then {} else fromjson end) as $t
    | .[].key | select(($t[.] // "") == "")' <<<"$list")"
  if [ -n "$empty" ]; then
    while IFS= read -r name; do
      echo "::error::Vault gave an empty value for github-token key ${name}. Report this to OSPO."
    done <<<"$empty"
    exit 1
  fi
  if ! jq -e '(env.TOKENS_VALUE | fromjson) as $t
      | ($t | keys) == ([.[].key] | sort) and $t[.[0].key] == (env.TOKEN_VALUE // "")' \
      <<<"$list" >/dev/null; then
    echo "::error::internal error: the tokens of the token step do not match the list in github-token. Report this to OSPO."
    exit 1
  fi
  tokens="$(jq -c -n 'env.TOKENS_VALUE | fromjson')"
fi

delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$merged" != *"$delimiter"* && "$tokens" != *"$delimiter"* ]] || { echo "::error::internal error: output delimiter collision. Run the job again."; exit 1; }
{
  printf 'secrets<<%s\n%s\n%s\n' "$delimiter" "$merged" "$delimiter"
  printf 'tokens<<%s\n%s\n%s\n' "$delimiter" "$tokens" "$delimiter"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
merged=""
tokens=""

#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs prepare.sh directly, without Vault or the network, and checks the
# reserved output name rule: prepare.sh accepts a `secrets` value that only
# contains the reserved name, and refuses a value that uses it as an output name.
# Uses no token and no secret.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare="$here/../prepare.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
nl=$'\n'

# Runs prepare.sh with IN_SECRETS=$2 and IN_GITHUB_TOKEN=$3.
# Sets rc and spec (the spec output, empty if prepare.sh failed).
run_prepare() {
  local out="$work/out" log="$work/log"
  : >"$out"
  rc=0
  env -i PATH="$PATH" \
    ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/not-used \
    EVENT_NAME=workflow_dispatch \
    IN_ROLE=test-role \
    IN_SECRETS="$1" \
    IN_GITHUB_TOKEN="$2" \
    IN_JOIN_TAILNET=false \
    GITHUB_OUTPUT="$out" \
    bash "$prepare" >"$log" 2>&1 || rc=$?
  spec="$(awk '
    /^spec<</ { d = substr($0, 7); on = 1; next }
    on && $0 == d { on = 0; next }
    on { print }
  ' "$out")"
}

accepts() {
  local title="$1" secrets="$2" token="$3" want="$4"
  run_prepare "$secrets" "$token"
  if [ "$rc" -ne 0 ]; then
    echo "::error::$title: prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif [ "$spec" != "$want" ]; then
    echo "::error::$title: spec output is not as expected"
    printf 'got:\n%s\nwant:\n%s\n' "$spec" "$want"
    status=1
  else
    echo "OK: accepted: $title"
  fi
}

refuses() {
  local title="$1" secrets="$2"
  run_prepare "$secrets" test-token
  if [ "$rc" -eq 0 ]; then
    echo "::error::$title: prepare.sh accepted it, expected a refusal"
    status=1
  elif ! grep -q 'keeps for github-token' "$work/log"; then
    echo "::error::$title: prepare.sh failed for another reason"
    cat "$work/log"
    status=1
  else
    echo "OK: refused: $title"
  fi
}

token_line='github/token/test-token token | VAULT_SECRETS_GITHUB_TOKEN'

accepts 'reserved name inside a path' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN_backup value | API_KEY' test-token \
  "kv/data/VAULT_SECRETS_GITHUB_TOKEN_backup value | API_KEY ;${nl}${token_line}"
accepts 'reserved name inside a path, no github-token' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN/x value | API_KEY ;' '' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN/x value | API_KEY'
accepts 'output name that only starts with the reserved name' \
  "kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN_2 ;${nl}kv/data/app other | B" test-token \
  "kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN_2 ;${nl}kv/data/app other | B ;${nl}${token_line}"
accepts 'default name with a dash is not the reserved name' \
  'kv/data/app VAULT-SECRETS_GITHUB_TOKEN' test-token \
  "kv/data/app VAULT-SECRETS_GITHUB_TOKEN ;${nl}${token_line}"

refuses 'exact output name' 'kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN'
refuses 'exact output name with blanks and ;' "kv/data/app value |  VAULT_SECRETS_GITHUB_TOKEN  ;${nl}"
refuses 'output name in lower case' 'kv/data/app value | vault_secrets_github_token'
refuses 'output name in the second entry' \
  "kv/data/app a | A ;${nl}kv/data/app b | VAULT_SECRETS_GITHUB_TOKEN"
refuses 'default name from the selector' 'kv/data/app VAULT_SECRETS_GITHUB_TOKEN'
refuses 'default name from a quoted selector' 'kv/data/app "vault_secrets_github_token"'

exit "$status"

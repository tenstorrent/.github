#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Turns a negative test case name into action inputs.
#
# Reads:  CASE VAULT_URL VAULT_ROLE VAULT_TOKEN_NAME VAULT_TOKEN_KEY VAULT_KV_PATH VAULT_KV_FIELD GITHUB_OUTPUT
# Writes: outputs role, github-token, secrets, vault-url, join-tailnet
set -euo pipefail

role="$VAULT_ROLE"
token="$VAULT_TOKEN_NAME"
secrets=""
url="$VAULT_URL"
join=auto

case "$CASE" in
  # Pre-checks: fail before any network call.
  no-inputs) token="" ;;
  # A role of another repository: Vault binds the claim repository, so it
  # can never work. Refused before any network call.
  foreign-role) role="${VAULT_ROLE%%--*}--no-such-repo--x" ;;
  # A token name of another repository: never in a grant of this repository.
  # Refused before any network call.
  foreign-token) token="${VAULT_ROLE%%--*}--no-such-repo--${VAULT_TOKEN_KEY}" ;;
  bad-token-name) token="bad;name" ;;
  bad-join-value) join=maybe ;;
  http-url) url="http://${VAULT_URL#https://}" ;;
  other-host-url) url="https://vault-ospo.invalid" ;;
  url-with-path) url="${VAULT_URL}/v1" ;;
  url-with-port) url="${VAULT_URL}:8200" ;;
  reserved-output-name) secrets="$VAULT_KV_PATH $VAULT_KV_FIELD | VAULT_SECRETS_GITHUB_TOKEN" ;;
  # No '| NAME': vault-action takes the output name from the selector.
  reserved-default-name) secrets="$VAULT_KV_PATH VAULT_SECRETS_GITHUB_TOKEN" ;;
  # Network: fail before Vault login.
  no-tailnet) join=false ;;
  # Vault refuses (needs the grant to be meaningful).
  wrong-role) role="${VAULT_ROLE}--no-such-role" ;;
  wrong-token) token="${VAULT_TOKEN_NAME}-no-such-token" ;;
  # A short key that the role has no grant for: denied in every engine.
  short-key-no-grant) token="no-such-key" ;;
  # Release 1.2: a list whose second key has no grant. The first token is
  # read, but the action fails and gives no token. A comma, not a new line:
  # the output github-token of this script is one line.
  list-no-grant) token="${VAULT_TOKEN_KEY},no-such-key" ;;
  wrong-kv-path)
    token=""
    secrets="${VAULT_KV_PATH}-no-such-path $VAULT_KV_FIELD | KV_TEST"
    ;;
  # No role: the default role has no metadata-read token. Proves the default
  # role is used, not the named role (which has this token).
  default-role-denied)
    role=""
    token="${VAULT_ROLE%--vault-action-test}--metadata-read"
    ;;
  wrong-kv-field)
    token=""
    secrets="$VAULT_KV_PATH no_such_field | KV_TEST"
    ;;
  *)
    echo "::error::unknown test case: $CASE"
    exit 1
    ;;
esac

{
  printf 'role=%s\n' "$role"
  printf 'github-token=%s\n' "$token"
  printf 'secrets=%s\n' "$secrets"
  printf 'vault-url=%s\n' "$url"
  printf 'join-tailnet=%s\n' "$join"
} >>"$GITHUB_OUTPUT"

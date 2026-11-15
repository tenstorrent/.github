#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Turns a negative test case name into action inputs.
#
# Reads:  CASE VAULT_URL VAULT_ROLE VAULT_TOKEN_NAME VAULT_KV_PATH VAULT_KV_FIELD GITHUB_OUTPUT
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
  empty-role) role="" ;;
  bad-token-name) token="bad;name" ;;
  bad-join-value) join=maybe ;;
  http-url) url="http://${VAULT_URL#https://}" ;;
  reserved-output-name) secrets="$VAULT_KV_PATH $VAULT_KV_FIELD | VAULT_SECRETS_GITHUB_TOKEN" ;;
  # Network: fail before Vault login.
  unreachable-url) url="https://vault-ospo.invalid" ;;
  no-tailnet) join=false ;;
  # Vault refuses (needs the grant to be meaningful).
  wrong-role) role="${VAULT_ROLE}--no-such-role" ;;
  wrong-token) token="${VAULT_TOKEN_NAME}-no-such-token" ;;
  wrong-kv-path)
    token=""
    secrets="${VAULT_KV_PATH}-no-such-path $VAULT_KV_FIELD | KV_TEST"
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

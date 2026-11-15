#!/usr/bin/env bash
# Pre-checks for the vault-secrets action. Fails early with a plain message.
# Every input arrives through env (never through ${{ }} in shell text).
#
# Reads:  IN_ROLE IN_GITHUB_TOKEN IN_SECRETS IN_VAULT_URL IN_JOIN_TAILNET
#         IN_TS_CLIENT_ID IN_TS_AUDIENCE IN_TS_TAGS EVENT_NAME
#         ACTIONS_ID_TOKEN_REQUEST_URL GITHUB_OUTPUT
# Writes: outputs url, join, spec
set -euo pipefail

DEFAULT_URL='https://vault-ospo.eng-svc.aws.tenstorrent.com'
TOKEN_OUTPUT='VAULT_SECRETS_GITHUB_TOKEN'

fail() {
  printf '::error title=vault-secrets::%s\n' "$1"
  exit 1
}

if [ "${EVENT_NAME:-}" = pull_request_target ]; then
  fail "refused on pull_request_target: that event runs with base-branch rights on untrusted pull request code. Use pull_request, push, workflow_dispatch or schedule."
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  fail "job needs permissions: id-token: write (not available on fork pull requests)"
fi

role="${IN_ROLE:-}"
[ -n "$role" ] || fail "input role is empty. Set it to the Vault role of this workflow, for example <org>--<repo>."
[[ "$role" =~ ^[A-Za-z0-9._-]+$ ]] || fail "input role has characters that a Vault role name cannot have. Allowed: letters, digits, '.', '_', '-'."

# Trim trailing blanks and ';' so that the token line can be appended.
secrets="${IN_SECRETS:-}"
while [[ "$secrets" =~ [[:space:]\;]$ ]]; do secrets="${secrets%?}"; done
while [[ "$secrets" =~ ^[[:space:]\;] ]]; do secrets="${secrets#?}"; done

github_token="${IN_GITHUB_TOKEN:-}"
if [ -z "$github_token" ] && [ -z "$secrets" ]; then
  fail "nothing to get: set github-token, secrets, or both."
fi

if [[ "$secrets" == *"$TOKEN_OUTPUT"* ]]; then
  fail "secrets uses the output name $TOKEN_OUTPUT, which this action keeps for github-token. Choose another name."
fi

spec="$secrets"
if [ -n "$github_token" ]; then
  [[ "$github_token" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
    || fail "input github-token is not a valid token name or path. Use a name such as <org>--<repo>--<key>, or a full path such as github-members/token/<org>--<repo>--<key>."
  if [[ "$github_token" == */* ]]; then
    token_path="$github_token"
  else
    token_path="github/token/$github_token"
  fi
  token_line="$token_path token | $TOKEN_OUTPUT"
  if [ -n "$spec" ]; then
    spec="$spec ;"$'\n'"$token_line"
  else
    spec="$token_line"
  fi
fi

url="${IN_VAULT_URL:-$DEFAULT_URL}"
while [[ "$url" == */ ]]; do url="${url%/}"; done
[[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] \
  || fail "input vault-url must be an https:// URL without query or spaces."

join="${IN_JOIN_TAILNET:-auto}"
case "$join" in
  true | false) ;;
  auto)
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
      echo "This runner is already on the tailnet. The action does not join again."
      join=false
    else
      join=true
    fi
    ;;
  *) fail "input join-tailnet must be auto, true or false." ;;
esac

if [ "$join" = true ]; then
  [ -n "${IN_TS_CLIENT_ID:-}" ] || fail "input tailscale-client-id is empty. It is needed to join the tailnet."
  [ -n "${IN_TS_AUDIENCE:-}" ] || fail "input tailscale-audience is empty. It is needed to join the tailnet."
  [ -n "${IN_TS_TAGS:-}" ] || fail "input tailscale-tags is empty. It is needed to join the tailnet."
fi

delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
{
  printf 'url=%s\n' "$url"
  printf 'join=%s\n' "$join"
  printf 'spec<<%s\n%s\n%s\n' "$delimiter" "$spec" "$delimiter"
} >>"$GITHUB_OUTPUT"

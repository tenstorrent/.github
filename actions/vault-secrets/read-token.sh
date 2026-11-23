#!/usr/bin/env bash
# Gets the GitHub token of one token set (input github-token without '/').
# The workflow gives only the token name. This script finds the Vault engine
# that holds the token set, so the workflow does not need to know it.
#
# The grant module puts each token set in exactly one engine (grant key `app`):
#   github/          app: default
#   github-members/  app: members
#   github-admin/    app: admin
# at <engine>/token/<set>. The policy github-<set> allows read on exactly that
# path. The script reads the engines in this order, least privilege first, one
# request each, and stops at the first success:
#   HTTP 200        the token. It is THE token of this call: each read makes a
#                   new GitHub App token, so the script never reads it again.
#   HTTP 403, 404   the role cannot read the set in this engine. Try the next.
#   other           stop with an error (no retry: a read can make a token).
# 403 in every engine: the role has no grant for this token set.
# A denied read is an entry in the Vault audit log (path and 'permission
# denied'). It needs no access that the role does not already have.
#
# Secrets: the Vault token (input) and the GitHub token. The GitHub token gets
# '::add-mask::' at once, before anything else can print it. Neither is ever
# echoed, in argv, or in a file. The GitHub token goes to the step output
# token; the action outputs token and secrets take it from there.
# Do not use 'set -x' here.
#
# Proxy (release 1.2): when VAULT_PROXY is set (network-mode userspace), every
# read goes through that Tailscale loopback proxy, also when NO_PROXY says
# otherwise.
#
# Reads:  VAULT_URL VAULT_TOKEN TOKEN_SET TOKEN_INPUT ROLE REPOSITORY GITHUB_OUTPUT
#         VAULT_PROXY (empty in network-mode kernel)
# Writes: output token
set -euo pipefail

# Seconds per HTTP request. At most one request per engine.
REQUEST_TIMEOUT=15
ENGINES=(github github-members github-admin)

# Prints one error annotation and exits. Escapes the characters that end or
# change a workflow command.
fail() {
  local msg="$1"
  msg="${msg//'%'/%25}"
  msg="${msg//$'\r'/%0D}"
  msg="${msg//$'\n'/%0A}"
  printf '::error title=vault-secrets::%s\n' "$msg"
  exit 1
}

url="${VAULT_URL:-}"
token_set="${TOKEN_SET:-}"
token_input="${TOKEN_INPUT:-}"
token_input="${token_input#"${token_input%%[![:space:]]*}"}"
token_input="${token_input%"${token_input##*[![:space:]]}"}"
role="${ROLE:-}"
repository="${REPOSITORY:-}"

# The same allow-list as prepare.sh. The Vault token goes only to OSPO Vault.
case "$url" in
  https://vault-ospo.eng-svc.aws.tenstorrent.com | https://vault-ospo-staging.eng-svc.aws.tenstorrent.com) ;;
  *) fail "Vault URL '$url' is not an OSPO Vault URL. The action does not send the Vault token to it." ;;
esac
[[ "$token_set" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
  || fail "internal error: no valid token set name (output token-set of the prepare step is '$token_set')."
[ -n "${VAULT_TOKEN:-}" ] || fail "internal error: no Vault token from the login step."
# Vault requests go through the Tailscale proxy only, and only on loopback.
vault_proxy=()
if [ -n "${VAULT_PROXY:-}" ]; then
  [[ "$VAULT_PROXY" =~ ^http://127\.0\.0\.1:([1-9][0-9]{0,4})$ ]] && [ "${BASH_REMATCH[1]}" -le 65535 ] \
    || fail "proxy URL '$VAULT_PROXY' is not a loopback Tailscale proxy. The action does not send the Vault token through it."
  vault_proxy=(--proxy "$VAULT_PROXY" --noproxy '')
fi

# Splits "<body>\n<http code>" (curl -w '\n%{http_code}') into body and code.
split_response() {
  code="${1##*$'\n'}"
  body="${1%$'\n'*}"
  [ "$body" != "$1" ] || body=""
}

# The first Vault error text of the body, on one line, without '::'.
vault_said() {
  local err
  err="$(printf '%s' "$body" | jq -r '(.errors // [])[0] // empty | tostring' 2>/dev/null || true)"
  err="${err//$'\r'/ }"
  err="${err//$'\n'/ }"
  err="${err//::/}"
  printf 'Vault said: %s.' "${err:0:300}"
}

from=""
[ "$token_input" = "$token_set" ] || from=" (from github-token: $token_input)"

github_token=""
for engine in "${ENGINES[@]}"; do
  # The Vault token goes in a header read from a pipe, never in argv.
  rc=0
  response="$(curl -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
    "${vault_proxy[@]+"${vault_proxy[@]}"}" \
    -w '\n%{http_code}' \
    -H @<(printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN") \
    "$url/v1/$engine/token/$token_set")" || rc=$?
  code="" body=""
  [ "$rc" -ne 0 ] || split_response "$response"
  response=""
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
    github_token="$(printf '%s' "$body" | jq -r '.data.token // empty' 2>/dev/null || true)"
    if [ -n "$github_token" ]; then
      printf '::add-mask::%s\n' "$github_token"
    fi
    body=""
    [ -n "$github_token" ] \
      || fail "Vault answered the read of GitHub token set $token_set$from without a token. Report this to OSPO."
    break
  fi
  if [ "$rc" -eq 28 ]; then
    fail "Vault did not answer the read of GitHub token set $token_set$from within $REQUEST_TIMEOUT seconds. The likely cause is a stalled network connection on the tailnet. Run the job again."
  elif [ "$rc" -ne 0 ]; then
    fail "the action could not send the read of GitHub token set $token_set$from to Vault $url (curl exit $rc). Run the job again."
  elif [ "$code" = 403 ] || [ "$code" = 404 ]; then
    body=""
    continue
  else
    fail "Vault refused the read of GitHub token set $token_set$from (HTTP ${code:-?}). $(vault_said) Role: $role."
  fi
done

if [ -z "$github_token" ]; then
  fail "Role $role has no grant for GitHub token set $token_set$from. Check the token key in github_tokens of your workflow entry in grants/repos/${repository}.yaml in github-vault-iac. If you added it just now, OSPO may not have applied the grant yet."
fi

# ── Pass the token to the action outputs ────────────────────────────────────
delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$github_token" != *"$delimiter"* ]] || fail "internal error: output delimiter collision. Run the job again."
printf 'token<<%s\n%s\n%s\n' "$delimiter" "$github_token" "$delimiter" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
github_token=""
echo "Found GitHub token set $token_set$from."

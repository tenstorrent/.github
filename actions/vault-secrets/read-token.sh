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
# The one exception (release 1.2): curl did not send the read, because the
# name lookup or the connection failed or timed out, or the proxy could not
# open a tunnel to Vault. Then the script sends the same read again: up to 3
# tries, 2 seconds apart. The same rule as login.sh (not_sent_cause).
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
# A caller can set SHELLOPTS=xtrace: no trace may print a secret.
set +x

# Seconds per HTTP request. At most one request per engine that Vault gets.
REQUEST_TIMEOUT=15
# Tries of one read when curl did not send it, and seconds between them.
TRIES=3
RETRY_DELAY=2
# curl -w: the HTTP code, the CONNECT code of a proxy, and the times of the
# name lookup and of the start of the transfer. curl writes this line also
# when it fails.
WRITE_OUT='\n%{http_code} %{http_connect} %{time_namelookup} %{time_pretransfer}'
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

# Splits "<body>\n<WRITE_OUT line>" into body, code, proxy_code, t_lookup and
# t_start. All are empty when curl wrote no such line.
split_vault_response() {
  local line="${1##*$'\n'}"
  body="${1%$'\n'*}"
  [ "$body" != "$1" ] || body=""
  code="" proxy_code="" t_lookup="" t_start=""
  read -r code proxy_code t_lookup t_start _ <<<"$line" || true
}

# Prints why the request did not reach Vault, but only when it is certain that
# curl did not send it. Else prints nothing. Certain means all of:
#   - time_pretransfer is 0: curl did not get to the start of the transfer, so
#     no byte of the request went out. curl sets this time only after the
#     connection (with TLS, and with the CONNECT tunnel of a proxy) is ready.
#   - no HTTP answer (http_code 000).
#   - the curl error is one of: 5, 6 (name lookup failed), 7 (connection
#     failed), 28 (timeout; with time_pretransfer 0 this is a timeout of the
#     name lookup or of the connection), 56 with a 5xx answer of the proxy to
#     CONNECT (the proxy could not open a tunnel to Vault).
# Not retried: a request that curl started to send, any HTTP answer of Vault,
# TLS errors, a 4xx answer of the proxy, and a missing -w line.
not_sent_cause() {
  local zero='^0(\.0+)?$' proxy="the proxy"
  [ -z "${VAULT_PROXY:-}" ] || proxy="the Tailscale proxy"
  if ! [[ "$t_start" =~ $zero ]] || [ "$code" != 000 ]; then
    return 0
  fi
  case "$rc" in
    5) echo "name lookup of $proxy failed" ;;
    6) echo "name lookup failed" ;;
    7) if [ -n "${VAULT_PROXY:-}" ]; then echo "connection to $proxy failed"; else echo "connection failed"; fi ;;
    28)
      if [[ "$t_lookup" =~ $zero ]]; then
        echo "name lookup timed out"
      elif [ -n "${VAULT_PROXY:-}" ]; then
        echo "connection through $proxy timed out"
      else
        echo "connection timed out"
      fi
      ;;
    56) if [[ "$proxy_code" =~ ^5[0-9][0-9]$ ]]; then echo "$proxy could not connect to Vault, HTTP $proxy_code"; fi ;;
  esac
  return 0
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

# Masks a value, one '::add-mask::' line per line of the value. The runner
# ends a line at a carriage return too, and decodes '%' in command data: each
# piece between line ends is masked, with '%' written as '%25'. A value cannot
# then start a workflow command of its own.
mask() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    [ -z "$l" ] || printf '::add-mask::%s\n' "${l//%/%25}"
  done <<<"${1//$'\r'/$'\n'}"
}

from=""
[ "$token_input" = "$token_set" ] || from=" (from github-token: $token_input)"

github_token=""
for engine in "${ENGINES[@]}"; do
  # The Vault token goes in a header read from a pipe, never in argv.
  # A new try only when curl did not send the read (not_sent_cause).
  try=1
  while :; do
    rc=0
    response="$(curl -q -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
      "${vault_proxy[@]+"${vault_proxy[@]}"}" \
      -w "$WRITE_OUT" \
      -H @<(printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN") \
      "$url/v1/$engine/token/$token_set")" || rc=$?
    split_vault_response "$response"
    response=""
    cause=""
    [ "$rc" -eq 0 ] || cause="$(not_sent_cause)"
    { [ -n "$cause" ] && [ "$try" -lt "$TRIES" ]; } || break
    try=$((try + 1))
    echo "Could not reach Vault ($cause). Try $try of $TRIES."
    sleep "$RETRY_DELAY"
  done
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
    github_token="$(printf '%s' "$body" | jq -r '.data.token // empty' 2>/dev/null || true)"
    [ -z "$github_token" ] || mask "$github_token"
    body=""
    [ -n "$github_token" ] \
      || fail "Vault answered the read of GitHub token set $token_set$from without a token. Report this to OSPO."
    # A token is one word of printable characters.
    if ! [[ "$github_token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || [ "${#github_token}" -gt 8192 ]; then
      fail "Vault gave a GitHub token for token set $token_set in a form that the action does not expect. Report this to OSPO."
    fi
    break
  fi
  if [ -n "$cause" ]; then
    fail "the action could not reach Vault $url for the read of GitHub token set $token_set$from in $TRIES tries ($cause, curl exit $rc). Vault did not get the read. The likely cause is a short network problem on the tailnet. Run the job again."
  elif [ "$rc" -eq 28 ]; then
    fail "Vault did not answer the read of GitHub token set $token_set$from within $REQUEST_TIMEOUT seconds. The likely cause is a stalled network connection on the tailnet. Run the job again."
  elif [ "$rc" -ne 0 ] && [[ "$t_start" =~ ^[0-9]+(\.[0-9]+)?$ ]] && ! [[ "$t_start" =~ ^0(\.0+)?$ ]]; then
    # time_pretransfer > 0: curl sent the read, then the connection broke.
    fail "the connection to Vault $url broke after the action sent the read of GitHub token set $token_set$from (curl exit $rc). Vault may have got the read. The action does not send it again. Run the job again."
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

#!/usr/bin/env bash
# Gets the GitHub token of one token set (input github-token without '/'),
# or of each token set of a list (release 1.2, two or more entries).
# The workflow gives only the token name. This script finds the Vault engine
# that holds the token set, so the workflow does not need to know it.
#
# A list: the script reads the token sets one after the other, in the order
# of the input, each with the rules below. The engine of one token set is not
# a hint for the next: each token set can be in a different engine. All or
# nothing: if one read fails, the script writes no output. The first token
# goes to output token, all tokens to output tokens (a JSON object: key ->
# token, built with jq).
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
# token; the action outputs token and secrets take it from there. With a list,
# every token gets its mask at once after its own read, before the next read
# and before any output.
# Do not use 'set -x' here.
#
# Proxy (release 1.2): when VAULT_PROXY is set (network-mode userspace), every
# read goes through that Tailscale loopback proxy, also when NO_PROXY says
# otherwise.
#
# Reads:  VAULT_URL VAULT_TOKEN TOKEN_SET TOKEN_INPUT ROLE REPOSITORY GITHUB_OUTPUT
#         VAULT_PROXY (empty in network-mode kernel)
#         TOKEN_LIST (output token-list of the prepare step: a JSON array of
#         {set, key, input}; a list only with two or more entries)
# Writes: output token; with a list also output tokens
set -euo pipefail

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

# Reads the token of token set $1 (input text $2) into github_token, and masks
# it at once. Fails with a message that names the token set.
# The body keeps the indent of release 1.1, so that the diff stays small.
read_token_set() {
local token_set="$1" token_input="$2"
local engine try
from=""
[ "$token_input" = "$token_set" ] || from=" (from github-token: $token_input)"

github_token=""
for engine in "${ENGINES[@]}"; do
  # The Vault token goes in a header read from a pipe, never in argv.
  # A new try only when curl did not send the read (not_sent_cause).
  try=1
  while :; do
    rc=0
    response="$(curl -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
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
    if [ -n "$github_token" ]; then
      printf '::add-mask::%s\n' "$github_token"
    fi
    body=""
    [ -n "$github_token" ] \
      || fail "Vault answered the read of GitHub token set $token_set$from without a token. Report this to OSPO."
    break
  fi
  if [ -n "$cause" ]; then
    fail "the action could not reach Vault $url for the read of GitHub token set $token_set$from in $TRIES tries ($cause, curl exit $rc). Vault did not get the read. The likely cause is a short network problem on the tailnet. Run the job again."
  elif [ "$rc" -eq 28 ]; then
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
}

# A list has two or more entries. Else (no TOKEN_LIST, or one entry) the
# script works as in release 1.1: see the end of this script.
list_length="$(printf '%s' "${TOKEN_LIST:-[]}" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || true)"
[[ "$list_length" =~ ^[0-9]+$ ]] || fail "internal error: output token-list of the prepare step is not a JSON array."
if [ "$list_length" -ge 2 ]; then
  # ── A list of token sets (release 1.2) ──────────────────────────────────────
  # The prepare step made the list and checked each entry. Check it again: a
  # name goes into a Vault path and a key into a JSON key.
  # No mapfile: bash 3.2 (macOS) does not have it.
  list_sets=() list_keys=() list_inputs=()
  while IFS=$'\t' read -r one_set one_key one_input; do
    list_sets+=("$one_set")
    list_keys+=("$one_key")
    list_inputs+=("$one_input")
  done < <(jq -r '.[] | [.set, .key, .input] | @tsv' <<<"$TOKEN_LIST")
  [ "${#list_sets[@]}" -eq "$list_length" ] || fail "internal error: the token list has entries that are not valid."
  [ "${list_sets[0]}" = "$token_set" ] \
    || fail "internal error: the token list does not start with token set $token_set."
  for i in "${!list_sets[@]}"; do
    [[ "${list_sets[$i]}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] && [[ "${list_keys[$i]:-}" =~ ^[a-z0-9_]([a-z0-9._-]*[a-z0-9_])?$ ]] \
      || fail "internal error: entry $((i + 1)) of the token list is not valid."
  done

  first_token=""
  tokens_json='{}'
  for i in "${!list_sets[@]}"; do
    read_token_set "${list_sets[$i]}" "${list_inputs[$i]:-}"
    # The masks hide each token in the log. A character that JSON escapes would
    # make the JSON text different from the masked value: refuse it.
    if ! [[ "$github_token" =~ ^[[:graph:]]+$ ]] || [[ "$github_token" == *[\"\\]* ]]; then
      github_token=""
      fail "Vault gave a token with characters that the action cannot put in output tokens, for GitHub token set ${list_sets[$i]}$from. Report this to OSPO."
    fi
    [ -n "$first_token" ] || first_token="$github_token"
    # The token goes to jq through env and stdin, never through argv.
    tokens_json="$(printf '%s' "$tokens_json" | T_KEY="${list_keys[$i]}" T_VALUE="$github_token" \
      jq -c '. + {(env.T_KEY): env.T_VALUE}')"
    github_token=""
    echo "Found GitHub token set ${list_sets[$i]}$from."
  done

  # ── Pass the tokens to the action outputs ───────────────────────────────────
  # Written only now, after every read worked.
  delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  [[ "$first_token" != *"$delimiter"* && "$tokens_json" != *"$delimiter"* ]] \
    || fail "internal error: output delimiter collision. Run the job again."
  {
    printf 'token<<%s\n%s\n%s\n' "$delimiter" "$first_token" "$delimiter"
    printf 'tokens<<%s\n%s\n%s\n' "$delimiter" "$tokens_json" "$delimiter"
  } >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
  first_token=""
  tokens_json=""
  echo "Found ${#list_sets[@]} GitHub token sets."
  exit 0
fi

# ── One token set (as in release 1.1) ───────────────────────────────────────
# A list of one entry: the entry without the separators around it.
if [ "$list_length" -eq 1 ]; then
  token_input="$(jq -r '.[0].input' <<<"$TOKEN_LIST")"
fi
read_token_set "$token_set" "$token_input"

# ── Pass the token to the action outputs ────────────────────────────────────
delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$github_token" != *"$delimiter"* ]] || fail "internal error: output delimiter collision. Run the job again."
printf 'token<<%s\n%s\n%s\n' "$delimiter" "$github_token" "$delimiter" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
github_token=""
echo "Found GitHub token set $token_set$from."

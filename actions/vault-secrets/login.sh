#!/usr/bin/env bash
# Logs in to OSPO Vault (auth/jwt-github) with the job's GitHub OIDC token.
# The action does the login here and not in hashicorp/vault-action, so that it
# can show Vault's error text and the facts of the run when Vault refuses.
#
# Secrets: the OIDC JWT and the Vault token. Each gets '::add-mask::' at once,
# before anything else can print it. Neither is ever echoed, in argv, or in a
# file. The one exception: the Vault token goes to the step output vault-token,
# which the token step (read-token.sh) and the read step (hashicorp/vault-action,
# method token) read. The action
# exposes no composite output with it. Do not use 'set -x' here.
#
# One login, no retry: each refused login is an audit entry and counts against
# the rate-limit quota on auth/jwt-github/. A login that curl sent is never
# sent again, also when Vault did not answer in time.
# The one exception (release 1.2): curl did not send the login, because the
# name lookup or the connection failed or timed out, or the proxy could not
# open a tunnel to Vault. Then Vault did not get the login, and the script
# sends it again: up to 3 tries, 2 seconds apart. See not_sent_cause.
#
# Proxy (release 1.2): when VAULT_PROXY is set (network-mode userspace), the
# Vault login goes through that Tailscale loopback proxy, also when NO_PROXY
# says otherwise. The OIDC request to GitHub keeps the runner's own proxy
# environment (HTTPS_PROXY, NO_PROXY) in both modes.
#
# Reads:  VAULT_URL ROLE ROLE_SOURCE ROLE_INPUT PREFIX REPOSITORY
#         VAULT_PROXY (empty in network-mode kernel)
#         ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN GITHUB_OUTPUT
#         GITHUB_REF GITHUB_EVENT_NAME GITHUB_WORKFLOW_REF (only for messages,
#         when the OIDC token cannot be decoded)
# Writes: output vault-token
set -euo pipefail
# A caller can set SHELLOPTS=xtrace: no trace may print a secret.
set +x

# Seconds per HTTP request.
REQUEST_TIMEOUT=15
# Tries of the Vault login when curl did not send it, and seconds between them.
TRIES=3
RETRY_DELAY=2
# curl -w for Vault requests: the HTTP code, the CONNECT code of a proxy, and
# the times of the name lookup and of the start of the transfer. curl writes
# this line also when it fails.
WRITE_OUT='\n%{http_code} %{http_connect} %{time_namelookup} %{time_pretransfer}'

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
role="${ROLE:-}"
role_source="${ROLE_SOURCE:-}"
prefix="${PREFIX:-}"
repository="${REPOSITORY:-}"

# The same allow-list as prepare.sh. The OIDC token of the job goes only to OSPO Vault.
case "$url" in
  https://vault-ospo.eng-svc.aws.tenstorrent.com | https://vault-ospo-staging.eng-svc.aws.tenstorrent.com) ;;
  *) fail "Vault URL '$url' is not an OSPO Vault URL. The action does not send the OIDC token to it." ;;
esac
# Vault requests go through the Tailscale proxy only, and only on loopback.
vault_proxy=()
if [ -n "${VAULT_PROXY:-}" ]; then
  [[ "$VAULT_PROXY" =~ ^http://127\.0\.0\.1:([1-9][0-9]{0,4})$ ]] && [ "${BASH_REMATCH[1]}" -le 65535 ] \
    || fail "proxy URL '$VAULT_PROXY' is not a loopback Tailscale proxy. The action does not send the OIDC token through it."
  vault_proxy=(--proxy "$VAULT_PROXY" --noproxy '')
fi
[ -n "$role" ] || fail "no Vault role to log in with (output role of the prepare step is empty)."
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
  || fail "job needs permissions: id-token: write (not available on fork pull requests)"

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

# Splits "<body>\n<http code>" (curl -w '\n%{http_code}') into body and code.
split_response() {
  code="${1##*$'\n'}"
  body="${1%$'\n'*}"
  [ "$body" != "$1" ] || body=""
}

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

# ── OIDC token ──────────────────────────────────────────────────────────────
# Audience: the Vault URL, as in vault-secrets 1.0 (jwtGithubAudience).
# The request token goes in a header read from a pipe, never in argv.
# Up to 3 tries of REQUEST_TIMEOUT seconds each, 2 seconds apart: about 50
# seconds in the worst case. The Vault login below is sent one time (see the
# header for the tries when curl did not send it).
audience="$(printf '%s' "$url" | jq -sRr @uri)"
# -q (first argument): curl reads no .curlrc, which could trace headers or change the target.
rc=0
response="$(curl -q -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
  --retry 2 --retry-delay 2 --retry-max-time 50 \
  -w '\n%{http_code}' \
  -H @<(printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN") \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}")" || rc=$?
code="" body=""
[ "$rc" -ne 0 ] || split_response "$response"
jwt=""
if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
  jwt="$(printf '%s' "$body" | jq -r '.value // empty' 2>/dev/null || true)"
fi
response="" body=""
[ -z "$jwt" ] || mask "$jwt"
if [ "$rc" -eq 28 ]; then
  fail "GitHub did not give the OIDC token in 3 tries of $REQUEST_TIMEOUT seconds each. Run the job again."
elif [ "$rc" -ne 0 ]; then
  fail "the action could not get the OIDC token from GitHub (curl exit $rc). Run the job again."
elif [ -z "$jwt" ]; then
  fail "GitHub did not give an OIDC token (HTTP $code). Check that the job has permissions: id-token: write."
fi
# A JWT is three base64url words. Anything else is not from GitHub.
[[ "$jwt" =~ ^[A-Za-z0-9._-]+$ ]] \
  || fail "GitHub gave an OIDC token in a form that the action does not expect. The action does not send it to Vault."

# Tripwire (../tripwires/README.md): the token must be the one this job asked
# for: GitHub's issuer, the Vault URL as audience, this repository. Another
# token was swapped in on the way and does not go to Vault. Python (-I) gets
# neither the step outputs nor the OIDC request token.
env -u GITHUB_OUTPUT -u ACTIONS_ID_TOKEN_REQUEST_TOKEN TRIPWIRE_JWT="$jwt" TRIPWIRE_REPOSITORY="$repository" \
  python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tripwires/tripwires.py" \
  --title vault-secrets --consequence "The OIDC token was not sent to Vault." \
  <<<"oidc-claims TRIPWIRE_JWT=OIDC-token $url TRIPWIRE_REPOSITORY" || exit 1

# ── Facts of this run, for messages only ────────────────────────────────────
# From the OIDC token payload (claims are not secret), else from the runner env.
claims="$(printf '%s' "$jwt" | jq -rR '
  split(".")[1] | gsub("-"; "+") | gsub("_"; "/")
  | (. + ("=" * ((4 - length % 4) % 4)))
  | @base64d | fromjson
  | [.repository, .ref, (.environment // "none"), .event_name, .job_workflow_ref]
  | map((. // "") | tostring | gsub("[\u0000-\u001f]"; " "))
  | join("\u001f")' 2>/dev/null || true)"
c_repo="" c_ref="" c_env="" c_event="" c_workflow=""
if [ -n "$claims" ]; then
  IFS=$'\x1f' read -r c_repo c_ref c_env c_event c_workflow <<<"$claims" || true
else
  c_repo="$repository" c_ref="${GITHUB_REF:-}" c_env="unknown" c_event="${GITHUB_EVENT_NAME:-}" c_workflow="${GITHUB_WORKFLOW_REF:-}"
fi
run_facts="This run: repository=${c_repo:-?}, ref=${c_ref:-?}, environment=${c_env:-none}, event=${c_event:-?}, workflow=${c_workflow:-?}."

# ── Login ───────────────────────────────────────────────────────────────────
# The body comes from jq on stdin, so the JWT is never in argv.
# A new try only when curl did not send the login (not_sent_cause). Worst
# case: 2 failed tries of at most 5 seconds (--connect-timeout), 2 waits of
# 2 seconds, then one try of 15 seconds: 29 seconds, 14 more than one try.
try=1
while :; do
  rc=0
  response="$(printf '%s' "$jwt" \
    | jq -Rc --arg role "$role" '{role: $role, jwt: .}' \
    | curl -q -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
      "${vault_proxy[@]+"${vault_proxy[@]}"}" \
      -w "$WRITE_OUT" \
      -H 'Content-Type: application/json' \
      -X POST --data-binary @- \
      "$url/v1/auth/jwt-github/login")" || rc=$?
  split_vault_response "$response"
  response=""
  cause=""
  [ "$rc" -eq 0 ] || cause="$(not_sent_cause)"
  { [ -n "$cause" ] && [ "$try" -lt "$TRIES" ]; } || break
  try=$((try + 1))
  echo "Could not reach Vault ($cause). Try $try of $TRIES."
  sleep "$RETRY_DELAY"
done
jwt=""
vault_token=""
if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
  vault_token="$(printf '%s' "$body" | jq -r '.auth.client_token // empty' 2>/dev/null || true)"
  [ -z "$vault_token" ] || mask "$vault_token"
  body=""
fi

if [ -n "$cause" ]; then
  fail "the action could not reach Vault $url in $TRIES tries ($cause, curl exit $rc). Vault did not get the login. The likely cause is a short network problem on the tailnet. Run the job again."
elif [ "$rc" -eq 28 ]; then
  fail "Vault did not answer the login within $REQUEST_TIMEOUT seconds. The likely cause is a stalled network connection on the tailnet. Run the job again."
elif [ "$rc" -ne 0 ] && [[ "$t_start" =~ ^[0-9]+(\.[0-9]+)?$ ]] && ! [[ "$t_start" =~ ^0(\.0+)?$ ]]; then
  # time_pretransfer > 0: curl sent the login, then the connection broke.
  fail "the connection to Vault $url broke after the action sent the login (curl exit $rc). Vault may have got the login. The action does not send it again. Run the job again."
elif [ "$rc" -ne 0 ]; then
  fail "the action could not send the login to Vault $url (curl exit $rc). Run the job again."
fi

if [ -z "$vault_token" ]; then
  # Refused. Only the first Vault error text is printed, never the body.
  err="$(printf '%s' "$body" | jq -r '(.errors // [])[0] // empty | tostring' 2>/dev/null || true)"
  err="${err//$'\r'/ }"
  err="${err//$'\n'/ }"
  err="${err//::/}"
  err="${err:0:300}"
  said="Vault said: ${err:-(no error text)}."
  repo_file="grants/repos/${repository}.yaml"
  claim_re='claim "([A-Za-z0-9_.-]+)"'
  if [ "$code" = 200 ]; then
    fail "Vault answered the login with role $role without a token. Report this to OSPO. $run_facts"
  elif [ "$code" = 429 ]; then
    fail "Vault refused the login: too many logins (rate limit). Run the job again in a minute. Role tried: $role. $run_facts"
  elif [[ "$err" == *'could not be found'* ]]; then
    case "$role_source" in
      default)
        fail "This repository has no default Vault role ($prefix): every workflow entry in its grant has a name. Set role to the name of your entry, for example 'role: nightly'. The names are in $repo_file in github-vault-iac, or ask OSPO. $said $run_facts"
        ;;
      short)
        fail "Vault has no role $role (from role: ${ROLE_INPUT:-}). Check the name of the workflow entry in $repo_file. If you added it just now, OSPO may not have applied the grant yet. $said $run_facts"
        ;;
      *)
        suffix="${role#"$prefix"}"
        suffix="${suffix#--}"
        if [ -n "$suffix" ]; then
          hint="You can also use the short name '$suffix'."
        else
          hint="You can also leave role empty."
        fi
        fail "Vault has no role $role. Check the role name in $repo_file. $hint $said $run_facts"
        ;;
    esac
  elif [[ "$err" =~ $claim_re ]]; then
    claim="${BASH_REMATCH[1]}"
    fail "This run does not match role $role: Vault refused claim $claim. $run_facts Run from the bound branch, environment or workflow file, or ask OSPO to change the grant. $said"
  else
    fail "Vault refused the login with role $role (HTTP ${code:-?}). $said $run_facts"
  fi
fi

# A token is one word of printable characters.
if ! [[ "$vault_token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || [ "${#vault_token}" -gt 8192 ]; then
  fail "Vault gave a token in a form that the action does not expect. Report this to OSPO."
fi

# ── Pass the Vault token to the read step ───────────────────────────────────
delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$vault_token" != *"$delimiter"* ]] || fail "internal error: output delimiter collision. Run the job again."
printf 'vault-token<<%s\n%s\n%s\n' "$delimiter" "$vault_token" "$delimiter" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
vault_token=""
echo "Logged in to Vault with role $role ($role_source)."

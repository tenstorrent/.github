#!/usr/bin/env bash
# shellcheck disable=SC2016 # Backticks are Markdown in the job summary, not commands.
# Gets a short-lived, read-only Hugging Face token for the job: asks GitHub for
# an OIDC token with audience https://huggingface.co, and exchanges it at
# https://huggingface.co/oauth/token (RFC 8693) for a token of the service
# account RESOURCE. Plain curl and jq: no Python package sees the OIDC request
# variables.
#
# Vendor reference: https://huggingface.co/docs/hub/trusted-publishers
# ("API reference"), and huggingface_hub src/huggingface_hub/_oidc.py
# (_get_github_oidc_token, exchange_oidc_token).
#
# Secrets: the OIDC JWT and the Hugging Face token. Each gets '::add-mask::'
# at once, before anything else can print it. Neither is ever echoed, in argv,
# or in a file. The Hugging Face token goes to the step output token only. Do
# not use 'set -x' here.
#
# Requests: the OIDC request is tried up to 3 times (it has no side effect).
# The exchange is sent one time, no retry: a refused exchange does not get
# better on a second try, and a timeout can mean a token was issued.
#
# Reads:  RESOURCE MODE ACTIONS_ID_TOKEN_REQUEST_URL
#         ACTIONS_ID_TOKEN_REQUEST_TOKEN GITHUB_OUTPUT GITHUB_STEP_SUMMARY
#         GITHUB_REPOSITORY GITHUB_REF GITHUB_WORKFLOW_REF GITHUB_EVENT_NAME
#         (for messages only, when the OIDC token cannot be decoded)
# Writes: outputs token, expires-at, stopped (exchange, only in warn mode)
set -euo pipefail
# A caller can set SHELLOPTS=xtrace: no trace may print a secret.
set +x

# Only the exchange may give the token. The action never reads a stored token.
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN

TITLE='hf-oidc-token'
HF_ENDPOINT_URL='https://huggingface.co'
AUDIENCE='https://huggingface.co'
REQUEST_TIMEOUT=20

escape() {
  local msg="$1"
  msg="${msg//'%'/%25}"
  msg="${msg//$'\r'/%0D}"
  msg="${msg//$'\n'/%0A}"
  printf '%s' "$msg"
}

fail() {
  printf '::error title=%s::%s\n' "$TITLE" "$(escape "$1")"
  exit 1
}

mode="${MODE:-fail}"
resource="${RESOURCE:-}"

# No token. Error in mode fail; warning and success in mode warn.
stop() {
  if [ "$mode" = warn ]; then
    printf '::warning title=%s::%s\n' "$TITLE" "$(escape "$1 The job continues without a Hugging Face token (if-no-token: warn).")"
    printf 'stopped=exchange\n' >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
    exit 0
  fi
  fail "$1"
}

# Same rule as prepare.sh: a user name, never a repository (a repository
# resource gives a write token).
[[ "$resource" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,94}[A-Za-z0-9])?$ ]] \
  || fail "resource '$resource' is not a Hugging Face user name. The action does not send the OIDC token."
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
  || stop "the job has no OIDC token. Add 'permissions: id-token: write' to this job."

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

# Splits "<body>\n<http code>" (curl -w '\n%{http_code}') into body and code.
split_response() {
  code="${1##*$'\n'}"
  body="${1%$'\n'*}"
  [ "$body" != "$1" ] || body=""
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

# Removes control characters and workflow command markers from server text.
clean() {
  local s="$1"
  s="$(printf '%s' "$s" | tr -d '\000-\037')"
  s="${s//::/}"
  printf '%s' "${s:0:300}"
}

# ── 1. OIDC token from GitHub ──────────────────────────────────────────────
# The request token goes in a header from a pipe, never in argv.
audience_q="$(printf '%s' "$AUDIENCE" | jq -sRr @uri)"
rc=0
# -q (first argument): curl reads no .curlrc, which could trace headers or change the target.
response="$(curl -q -sS --connect-timeout 5 --max-time 15 \
  --retry 2 --retry-delay 2 --retry-max-time 50 \
  -w '\n%{http_code}' \
  -H @<(printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN") \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience_q}")" || rc=$?
code="" body=""
[ "$rc" -ne 0 ] || split_response "$response"
jwt=""
if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
  jwt="$(printf '%s' "$body" | jq -r '(.value // empty) | select(type == "string")' 2>/dev/null || true)"
fi
response="" body=""
[ -z "$jwt" ] || mask "$jwt"
if [ "$rc" -eq 28 ]; then
  stop "GitHub did not give the OIDC token in 3 tries. Run the job again."
elif [ "$rc" -ne 0 ]; then
  stop "the action could not get the OIDC token from GitHub (curl exit $rc). Run the job again."
elif [ -z "$jwt" ]; then
  stop "GitHub did not give an OIDC token (HTTP $code). Check that the job has permissions: id-token: write."
fi

# Tripwire (../tripwires/README.md): the token must be the one this job asked
# for: GitHub's issuer, the Hugging Face audience, this repository. Another
# token was swapped in on the way and does not go to Hugging Face. Python
# (-I, standard library only) gets neither the step outputs nor the OIDC
# request token.
env -u GITHUB_OUTPUT -u ACTIONS_ID_TOKEN_REQUEST_TOKEN TRIPWIRE_JWT="$jwt" \
  python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tripwires/tripwires.py" \
  --title "$TITLE" --consequence "The OIDC token was not sent to Hugging Face." \
  <<<"oidc-claims TRIPWIRE_JWT=OIDC-token $AUDIENCE" || exit 1

# ── 2. The identity values of this run ─────────────────────────────────────
# From the OIDC token payload (claims are not secret), else from the runner
# env. These are the values that a CI/CD identity on the account must have.
claims="$(printf '%s' "$jwt" | jq -rR '
  split(".")[1] | gsub("-"; "+") | gsub("_"; "/")
  | (. + ("=" * ((4 - length % 4) % 4)))
  | @base64d | fromjson
  | [.repository, .ref, .workflow_ref, .event_name, .job_workflow_ref]
  | map((. // "") | tostring | gsub("[\u0000-\u001f]"; " "))
  | join("\u001f")' 2>/dev/null || true)"
c_repo="" c_ref="" c_wref="" c_event="" c_jwref=""
if [ -n "$claims" ]; then
  IFS=$'\x1f' read -r c_repo c_ref c_wref c_event c_jwref <<<"$claims" || true
else
  c_repo="${GITHUB_REPOSITORY:-}" c_ref="${GITHUB_REF:-}" c_wref="${GITHUB_WORKFLOW_REF:-}" c_event="${GITHUB_EVENT_NAME:-}"
fi
id_branch="${c_ref#refs/heads/}"
id_workflow="${c_wref%@*}"
id_workflow="${id_workflow##*/}"
identity="repository=${c_repo:-?}, branch=${id_branch:-?}, workflow=${id_workflow:-?}"
called=""
if [ -n "$c_jwref" ] && [ "${c_jwref%@*}" != "${c_wref%@*}" ]; then
  called=" This job runs in the reusable workflow ${c_jwref%@*}. The identity must name the calling workflow ${id_workflow:-?}, not the reusable workflow."
fi

# Writes the values for OSPO to the job summary (no secret in it).
summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### Hugging Face token: %s\n\n' "$1"
    printf 'Open an OSPO ticket. Copy this table and the list of gated models that the job reads into it.\n'
    printf 'OSPO adds a CI/CD identity with these values to the Hugging Face account `%s`:\n\n' "$resource"
    printf '| Field | Value |\n| --- | --- |\n'
    printf '| Provider | GitHub Actions |\n'
    printf '| repository | `%s` |\n' "${c_repo:-?}"
    printf '| branch | `%s` |\n' "${id_branch:-?}"
    printf '| workflow | `%s` |\n' "${id_workflow:-?}"
    printf '| Allow Inference Providers calls | Off |\n\n'
    printf 'Event of this run: `%s`.\n' "${c_event:-?}"
  } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}

# ── 3. Exchange at Hugging Face ────────────────────────────────────────────
# The body comes from jq on stdin, so the JWT is never in argv. The response
# headers go to a file in a private directory; they hold no secret.
# -q (first argument): curl reads no .curlrc, which could trace headers or change the target.
rc=0
response="$(printf '%s' "$jwt" \
  | jq -Rc --arg resource "$resource" '{
      grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
      subject_token_type: "urn:ietf:params:oauth:token-type:id_token",
      subject_token: .,
      resource: $resource
    }' \
  | curl -q -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
    -w '\n%{http_code}' \
    -D "$work/headers" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -X POST --data-binary @- \
    "$HF_ENDPOINT_URL/oauth/token")" || rc=$?
jwt=""
code="" body=""
[ "$rc" -ne 0 ] || split_response "$response"
response=""
token=""
expires_in=""
if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
  token="$(printf '%s' "$body" | jq -r '(.access_token // empty) | select(type == "string")' 2>/dev/null || true)"
  [ -z "$token" ] || mask "$token"
  expires_in="$(printf '%s' "$body" | jq -r '.expires_in // empty' 2>/dev/null || true)"
  body=""
fi

if [ "$rc" -eq 28 ]; then
  stop "Hugging Face did not answer the exchange within $REQUEST_TIMEOUT seconds. Run the job again."
elif [ "$rc" -ne 0 ]; then
  stop "the action could not send the exchange to $HF_ENDPOINT_URL (curl exit $rc). The runner must reach huggingface.co. Run the job again."
fi

if [ -z "$token" ]; then
  err="" desc=""
  if [ -n "$body" ]; then
    err="$(printf '%s' "$body" | jq -r '.error // empty | tostring' 2>/dev/null || true)"
    desc="$(printf '%s' "$body" | jq -r '(.error_description // .message // empty) | tostring' 2>/dev/null || true)"
  fi
  body=""
  err="$(clean "$err")"
  desc="$(clean "$desc")"
  request_id="$(tr -d '\r' <"$work/headers" 2>/dev/null \
    | awk -F': *' 'tolower($1) == "x-request-id" { v = $2 } END { print v }' || true)"
  request_id="$(clean "$request_id")"
  said="Hugging Face said: ${err:-(no error code)}${desc:+ ($desc)}${request_id:+ (Request ID: $request_id)}."
  if [ "$code" = 200 ]; then
    fail "Hugging Face answered the exchange without a token. Report this to OSPO. $said"
  elif [ "$code" = 429 ]; then
    stop "Hugging Face refused the exchange: too many requests. Run the job again later. $said"
  elif [ "${code:0:1}" = 5 ]; then
    stop "Hugging Face had an error (HTTP $code). Run the job again. $said"
  elif [ "$err" = invalid_grant ]; then
    summary "no CI/CD identity matches this run"
    stop "Hugging Face did not accept this run for account $resource. The likely cause: no CI/CD identity on that account matches this run. Open an OSPO ticket (or add to your open one) so that OSPO adds an identity with: $identity. Also put the gated models that the job reads in the ticket. The values are in the job summary.$called Other causes: the account does not exist or is locked. $said"
  else
    stop "Hugging Face refused the exchange (HTTP ${code:-?}). $said This run: $identity."
  fi
fi

# A token is one word of printable characters.
if ! [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || [ "${#token}" -gt 8192 ]; then
  fail "Hugging Face gave a token in a form that the action does not expect. Report this to OSPO."
fi

# ── 4. Outputs ─────────────────────────────────────────────────────────────
[[ "$expires_in" =~ ^[0-9]{1,6}$ ]] || expires_in=3600
until_epoch=$(($(date -u +%s) + expires_in))
expires_at="$(date -u -d "@$until_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "$until_epoch" +%Y-%m-%dT%H:%M:%SZ)"

delimiter="hf_oidc_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$token" != *"$delimiter"* ]] || fail "internal error: output delimiter collision. Run the job again."
{
  printf 'token<<%s\n%s\n%s\n' "$delimiter" "$token" "$delimiter"
  printf 'expires-at=%s\n' "$expires_at"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
token=""
echo "Got a read-only Hugging Face token for account $resource. It ends at $expires_at. This run: $identity."

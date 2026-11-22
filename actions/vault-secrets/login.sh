#!/usr/bin/env bash
# Logs in to OSPO Vault (auth/jwt-github) with the job's GitHub OIDC token.
# The action does the login here and not in hashicorp/vault-action, so that it
# can show Vault's error text and the facts of the run when Vault refuses.
#
# Secrets: the OIDC JWT and the Vault token. Each gets '::add-mask::' at once,
# before anything else can print it. Neither is ever echoed, in argv, or in a
# file. The one exception: the Vault token goes to the step output vault-token,
# which the next step (hashicorp/vault-action, method token) reads. The action
# exposes no composite output with it. Do not use 'set -x' here.
#
# One login, no retry: each refused login is an audit entry and counts against
# the rate-limit quota on auth/jwt-github/.
#
# Reads:  VAULT_URL ROLE ROLE_SOURCE ROLE_INPUT PREFIX REPOSITORY
#         ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN GITHUB_OUTPUT
#         GITHUB_REF GITHUB_EVENT_NAME GITHUB_WORKFLOW_REF (only for messages,
#         when the OIDC token cannot be decoded)
# Writes: output vault-token
set -euo pipefail

# Seconds per HTTP request.
REQUEST_TIMEOUT=15

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
[ -n "$role" ] || fail "no Vault role to log in with (output role of the prepare step is empty)."
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
  || fail "job needs permissions: id-token: write (not available on fork pull requests)"

# Splits "<body>\n<http code>" (curl -w '\n%{http_code}') into body and code.
split_response() {
  code="${1##*$'\n'}"
  body="${1%$'\n'*}"
  [ "$body" != "$1" ] || body=""
}

# ── OIDC token ──────────────────────────────────────────────────────────────
# Audience: the Vault URL, as in vault-secrets 1.0 (jwtGithubAudience).
# The request token goes in a header read from a pipe, never in argv.
audience="$(printf '%s' "$url" | jq -sRr @uri)"
rc=0
response="$(curl -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
  --retry 2 --retry-delay 2 --retry-max-time 40 \
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
if [ -n "$jwt" ]; then
  printf '::add-mask::%s\n' "$jwt"
fi
if [ "$rc" -eq 28 ]; then
  fail "GitHub did not give the OIDC token within $REQUEST_TIMEOUT seconds. Run the job again."
elif [ "$rc" -ne 0 ]; then
  fail "the action could not get the OIDC token from GitHub (curl exit $rc). Run the job again."
elif [ -z "$jwt" ]; then
  fail "GitHub did not give an OIDC token (HTTP $code). Check that the job has permissions: id-token: write."
fi

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
rc=0
response="$(printf '%s' "$jwt" \
  | jq -Rc --arg role "$role" '{role: $role, jwt: .}' \
  | curl -sS --connect-timeout 5 --max-time "$REQUEST_TIMEOUT" \
    -w '\n%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST --data-binary @- \
    "$url/v1/auth/jwt-github/login")" || rc=$?
jwt=""
code="" body=""
[ "$rc" -ne 0 ] || split_response "$response"
response=""
vault_token=""
if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
  vault_token="$(printf '%s' "$body" | jq -r '.auth.client_token // empty' 2>/dev/null || true)"
  if [ -n "$vault_token" ]; then
    printf '::add-mask::%s\n' "$vault_token"
  fi
  body=""
fi

if [ "$rc" -eq 28 ]; then
  fail "Vault did not answer the login within $REQUEST_TIMEOUT seconds. The likely cause is a stalled network connection on the tailnet. Run the job again."
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

# ── Pass the Vault token to the read step ───────────────────────────────────
delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$vault_token" != *"$delimiter"* ]] || fail "internal error: output delimiter collision. Run the job again."
printf 'vault-token<<%s\n%s\n%s\n' "$delimiter" "$vault_token" "$delimiter" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
vault_token=""
echo "Logged in to Vault with role $role ($role_source)."

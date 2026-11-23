#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs login.sh directly, without Vault or the network. A fake curl on PATH
# answers the OIDC token request and the Vault login with canned JSON, and
# records its argv. Checks:
#   - the login request (role, JWT in the body from stdin, audience);
#   - the message for each refusal (role not found for each role source,
#     claim mismatch, rate limit, other errors), with the facts of the run;
#   - timeouts and a Vault URL that is not allowed;
#   - every '::add-mask::' comes before the first write to GITHUB_OUTPUT;
#   - the JWT, the Vault token and the request token never appear in the log
#     except in '::add-mask::' lines, and never in argv;
#   - one login request, no retry, no revoke-self;
#   - network-mode userspace (VAULT_PROXY): the Vault login goes through the
#     loopback proxy and ignores NO_PROXY, the OIDC request keeps the runner's
#     proxy environment, and a proxy that is not on loopback gets no request.
# Uses only dummy values: no token and no secret.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
login="$here/../login.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
url='https://vault-ospo.eng-svc.aws.tenstorrent.com'
request_token='dummy-request-token-5a1d0c3e'
vault_token='hvs.dummy-vault-token-7f3e9b21'

b64url() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}
claims='{"repository":"tenstorrent/.github","ref":"refs/pull/7/merge","environment":"vault-action-test","event_name":"pull_request","job_workflow_ref":"tenstorrent/.github/.github/workflows/test.yml@refs/pull/7/merge","aud":"x"}'
jwt="$(b64url '{"alg":"RS256","typ":"JWT"}').$(b64url "$claims").dummysignature0123456789"
claims_noenv='{"repository":"tenstorrent/.github","ref":"refs/heads/main","event_name":"push","job_workflow_ref":"tenstorrent/.github/.github/workflows/test.yml@refs/heads/main"}'
jwt_noenv="$(b64url '{"alg":"RS256","typ":"JWT"}').$(b64url "$claims_noenv").dummysignature9876543210"

# ── Fake curl ───────────────────────────────────────────────────────────────
# Answers by URL. FAKE_OIDC and FAKE_LOGIN choose the answer. Writes argv (one
# line per call) to FAKE_ARGV, headers read from '-H @file' to FAKE_HEADERS,
# and the request body to FAKE_BODY.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_ARGV"
target="" prev="" data=false
for a in "$@"; do
  case "$a" in http://* | https://*) target="$a" ;; esac
  if [ "$prev" = -H ] && [ "${a#@}" != "$a" ]; then cat "${a#@}" >>"$FAKE_HEADERS"; fi
  [ "$a" = --data-binary ] && data=true
  prev="$a"
done
if [ "$data" = true ]; then cat >>"$FAKE_BODY"; printf '\n' >>"$FAKE_BODY"; fi
printf '%s https_proxy=%s\n' "$target" "${HTTPS_PROXY:-}" >>"$FAKE_ENV"
answer() { printf '%s\n%s' "$2" "$1"; }
case "$target" in
  *'audience='*)
    case "$FAKE_OIDC" in
      ok) answer 200 "{\"count\":1,\"value\":\"$FAKE_JWT\"}" ;;
      empty) answer 200 '{}' ;;
      denied) answer 403 '{"message":"no"}' ;;
      timeout) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
    esac
    ;;
  */v1/auth/jwt-github/login)
    role="$(sed -n 's/.*"role":"\([^"]*\)".*/\1/p' "$FAKE_BODY" | tail -n 1)"
    case "$FAKE_LOGIN" in
      ok) answer 200 "{\"auth\":{\"client_token\":\"$FAKE_VAULT_TOKEN\",\"policies\":[\"default\"]}}" ;;
      notoken) answer 200 '{"auth":null}' ;;
      notfound) answer 400 "{\"errors\":[\"role \\\"$role\\\" could not be found\"]}" ;;
      claim-env) answer 400 '{"errors":["error validating claims: claim \"environment\" does not match any associated bound claim values"]}' ;;
      claim-wf) answer 400 '{"errors":["error validating claims: claim \"job_workflow_ref\" does not match any associated bound claim values"]}' ;;
      ratelimit) answer 429 '{"errors":["request path \"auth/jwt-github/login\": rate limit quota exceeded"]}' ;;
      e500) answer 500 '{"errors":["internal ::error::boom\nsecond line"]}' ;;
      nobody) answer 502 '<html>bad gateway</html>' ;;
      timeout) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
    esac
    ;;
  *) echo "fake curl: unexpected URL $target" >&2; exit 7 ;;
esac
FAKE
chmod +x "$work/bin/curl"

# Runs login.sh. Arguments (NAME=value) replace the defaults. stdout, stderr
# and GITHUB_OUTPUT go to one file in append mode, so the order of lines is
# the order of writes. Sets rc and log.
run_login() {
  local all="$work/all"
  : >"$all"
  : >"$work/argv"
  : >"$work/headers"
  : >"$work/body"
  : >"$work/env"
  rc=0
  env -i PATH="$work/bin:$PATH" \
    VAULT_URL="$url" \
    ROLE=tenstorrent--.github--vault-action-test \
    ROLE_SOURCE=full \
    ROLE_INPUT=tenstorrent--.github--vault-action-test \
    PREFIX=tenstorrent--.github \
    REPOSITORY=tenstorrent/.github \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://token.invalid/oidc?api-version=2.0' \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="$request_token" \
    GITHUB_OUTPUT="$all" \
    FAKE_ARGV="$work/argv" FAKE_HEADERS="$work/headers" FAKE_BODY="$work/body" FAKE_ENV="$work/env" \
    FAKE_JWT="$jwt" FAKE_VAULT_TOKEN="$vault_token" FAKE_OIDC=ok FAKE_LOGIN=ok \
    "$@" \
    bash "$login" >>"$all" 2>&1 || rc=$?
  log="$(cat "$all")"
}

bad() {
  echo "::error::$1"
  printf '%s\n' "$log" | sed 's/^::/: :/' # Shows the log without running its commands.
  status=1
}

# Fails if a secret value appears outside '::add-mask::' lines and outside the
# vault-token output block, or appears in argv.
no_leaks() {
  local title="$1" value
  for value in "$jwt" "$jwt_noenv" "$vault_token" "$request_token"; do
    if printf '%s\n' "$log" | awk -v v="$value" '
        /^vault-token<</ { d = substr($0, 14); on = 1; next }
        on && $0 == d { on = 0; next }
        on { next }
        /^::add-mask::/ { next }
        index($0, v) { found = 1 }
        END { exit !found }'; then
      bad "$title: a secret value appears in the log outside an ::add-mask:: line"
    fi
    if grep -q -F -- "$value" "$work/argv"; then
      bad "$title: a secret value appears in the argv of curl"
    fi
  done
  if grep -q -F -- 'revoke' "$work/argv"; then
    bad "$title: the action sent a revoke request"
  fi
}

# Number of login requests in this run.
login_calls() {
  grep -c -F -- '/v1/auth/jwt-github/login' "$work/argv" || true
}

# ── Success ─────────────────────────────────────────────────────────────────
run_login
first_output="$(printf '%s\n' "$log" | grep -n '^vault-token<<' | head -n 1 | cut -d: -f1)"
last_mask="$(printf '%s\n' "$log" | grep -n '^::add-mask::' | tail -n 1 | cut -d: -f1)"
got="$(printf '%s\n' "$log" | awk '
  /^vault-token<</ { d = substr($0, 14); on = 1; next }
  on && $0 == d { on = 0; next }
  on { print }')"
if [ "$rc" -ne 0 ]; then
  bad "login: login.sh failed (exit $rc), expected exit 0"
elif [ "$got" != "$vault_token" ]; then
  bad "login: output vault-token is not the Vault token"
elif ! printf '%s\n' "$log" | grep -q -x -F -- "::add-mask::$jwt"; then
  bad "login: no ::add-mask:: line for the JWT"
elif ! printf '%s\n' "$log" | grep -q -x -F -- "::add-mask::$vault_token"; then
  bad "login: no ::add-mask:: line for the Vault token"
elif [ -z "$first_output" ] || [ "$last_mask" -ge "$first_output" ]; then
  bad "login: an ::add-mask:: line comes after the write to GITHUB_OUTPUT"
elif ! printf '%s\n' "$log" | grep -q -F -- 'Logged in to Vault with role tenstorrent--.github--vault-action-test (full).'; then
  bad "login: no success line with the role"
elif ! grep -q -F -- "\"role\":\"tenstorrent--.github--vault-action-test\"" "$work/body" \
  || ! grep -q -F -- "\"jwt\":\"$jwt\"" "$work/body"; then
  bad "login: the login body does not have the role and the JWT"
elif ! grep -q -F -- 'audience=https%3A%2F%2Fvault-ospo.eng-svc.aws.tenstorrent.com' "$work/argv"; then
  bad "login: the OIDC request does not ask for the Vault URL as audience"
elif ! grep -q -x -F -- "Authorization: bearer $request_token" "$work/headers"; then
  bad "login: the OIDC request has no Authorization header from a pipe"
elif [ "$(login_calls)" -ne 1 ]; then
  bad "login: expected one login request, got $(login_calls)"
else
  echo "OK: login with role, masks before output, token in output vault-token"
fi
no_leaks login

# ── Refusals ────────────────────────────────────────────────────────────────
# Fails unless login.sh, with the replaced inputs $3..., fails with an error
# annotation that contains the text $2 and the facts of the run, writes no
# output, sends at most one login, and leaks nothing.
refused() {
  local title="$1" want="$2"
  shift 2
  run_login "$@"
  if [ "$rc" -eq 0 ]; then
    bad "$title: login.sh succeeded, expected a failure"
  elif ! printf '%s\n' "$log" | grep -F -- '::error title=vault-secrets::' | grep -q -F -- "$want"; then
    bad "$title: login.sh failed, but not with the message '$want'"
  elif printf '%s\n' "$log" | grep -q '^vault-token<<'; then
    bad "$title: login.sh wrote output vault-token"
  elif [ "$(login_calls)" -gt 1 ]; then
    bad "$title: login.sh sent $(login_calls) login requests, expected at most one"
  else
    echo "OK: refused: $title"
  fi
  no_leaks "$title"
}

facts='This run: repository=tenstorrent/.github, ref=refs/pull/7/merge, environment=vault-action-test, event=pull_request, workflow=tenstorrent/.github/.github/workflows/test.yml@refs/pull/7/merge.'

refused 'role not found, default role' \
  "This repository has no default Vault role (tenstorrent--.github): every workflow entry in its grant has a name." \
  FAKE_LOGIN=notfound ROLE=tenstorrent--.github ROLE_SOURCE=default ROLE_INPUT=
refused 'role not found, default role: facts and Vault text' \
  "Vault said: role \"tenstorrent--.github\" could not be found. $facts" \
  FAKE_LOGIN=notfound ROLE=tenstorrent--.github ROLE_SOURCE=default ROLE_INPUT=
refused 'role not found, short name' \
  "Vault has no role tenstorrent--.github--nightly (from role: nightly). Check the name of the workflow entry in grants/repos/tenstorrent/.github.yaml." \
  FAKE_LOGIN=notfound ROLE=tenstorrent--.github--nightly ROLE_SOURCE=short ROLE_INPUT=nightly
refused 'role not found, full name' \
  "Vault has no role tenstorrent--.github--nightly. Check the role name in grants/repos/tenstorrent/.github.yaml. You can also use the short name 'nightly'." \
  FAKE_LOGIN=notfound ROLE=tenstorrent--.github--nightly ROLE_SOURCE=full ROLE_INPUT=tenstorrent--.github--nightly
refused 'role not found, full default name' \
  "Vault has no role tenstorrent--.github. Check the role name in grants/repos/tenstorrent/.github.yaml. You can also leave role empty." \
  FAKE_LOGIN=notfound ROLE=tenstorrent--.github ROLE_SOURCE=full ROLE_INPUT=tenstorrent--.github
refused 'claim mismatch, environment' \
  "This run does not match role tenstorrent--.github--vault-action-test: Vault refused claim environment. $facts Run from the bound branch" \
  FAKE_LOGIN=claim-env
refused 'claim mismatch, job_workflow_ref' \
  "Vault refused claim job_workflow_ref. $facts" \
  FAKE_LOGIN=claim-wf
refused 'claim mismatch, job without environment' \
  'environment=none, event=push' \
  FAKE_LOGIN=claim-env FAKE_JWT="$jwt_noenv"
refused 'rate limit' \
  "Vault refused the login: too many logins (rate limit). Run the job again in a minute. Role tried: tenstorrent--.github--vault-action-test. $facts" \
  FAKE_LOGIN=ratelimit
refused 'other error, :: removed, one line' \
  "Vault refused the login with role tenstorrent--.github--vault-action-test (HTTP 500). Vault said: internal errorboom second line. $facts" \
  FAKE_LOGIN=e500
refused 'other error without JSON' \
  'Vault refused the login with role tenstorrent--.github--vault-action-test (HTTP 502). Vault said: (no error text).' \
  FAKE_LOGIN=nobody
refused 'answer without a token' \
  'Vault answered the login with role tenstorrent--.github--vault-action-test without a token.' \
  FAKE_LOGIN=notoken
refused 'login timeout' \
  'Vault did not answer the login within 15 seconds.' \
  FAKE_LOGIN=timeout
refused 'OIDC timeout' \
  'GitHub did not give the OIDC token in 3 tries of 15 seconds each.' \
  FAKE_OIDC=timeout
refused 'OIDC refused' \
  'GitHub did not give an OIDC token (HTTP 403).' \
  FAKE_OIDC=denied
refused 'OIDC answer without a token' \
  'GitHub did not give an OIDC token (HTTP 200).' \
  FAKE_OIDC=empty
refused 'no OIDC request token' \
  'job needs permissions: id-token: write' \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=
refused 'empty role' 'no Vault role to log in with' ROLE=

# A refused login must not contain the JWT anywhere except its mask line.
run_login FAKE_LOGIN=claim-env
if [ "$(printf '%s\n' "$log" | grep -c -F -- "$jwt")" -ne 1 ]; then
  bad "refusal: the JWT appears in more than its ::add-mask:: line"
else
  echo "OK: refusal: the JWT appears only in its ::add-mask:: line"
fi

# The allow-list: no request at all for another URL.
for other in https://vault-ospo.invalid http://vault-ospo.eng-svc.aws.tenstorrent.com \
  https://vault-ospo.eng-svc.aws.tenstorrent.com.invalid ''; do
  refused "vault URL '$other'" 'is not an OSPO Vault URL' VAULT_URL="$other"
  if [ -s "$work/argv" ]; then
    bad "vault URL '$other': login.sh sent a request"
  fi
done
run_login VAULT_URL=https://vault-ospo-staging.eng-svc.aws.tenstorrent.com
if [ "$rc" -ne 0 ] || ! grep -q -F -- 'https://vault-ospo-staging.eng-svc.aws.tenstorrent.com/v1/auth/jwt-github/login' "$work/argv"; then
  bad "staging URL: login.sh did not log in to the staging URL"
else
  echo "OK: staging URL is allowed"
fi

# ── Network mode userspace (release 1.2) ────────────────────────────────────
# Kernel mode (VAULT_PROXY not set): curl gets no proxy option, as in 1.1.
run_login
if [ "$rc" -ne 0 ]; then
  bad "kernel: login.sh failed (exit $rc), expected exit 0"
elif grep -q -E -- '--(no)?proxy' "$work/argv"; then
  bad "kernel: curl got a proxy option"
else
  echo "OK: kernel: no proxy option on any request"
fi

# Userspace: the login goes through the loopback proxy, also with NO_PROXY=*.
# The OIDC request has no proxy option, so curl uses the runner's HTTPS_PROXY.
proxy='http://127.0.0.1:1055'
run_login VAULT_PROXY="$proxy" HTTPS_PROXY=http://egress.invalid:3128 NO_PROXY='*' no_proxy='*'
oidc_argv="$(grep -F -- 'audience=' "$work/argv" || true)"
login_argv="$(grep -F -- '/v1/auth/jwt-github/login' "$work/argv" || true)"
if [ "$rc" -ne 0 ]; then
  bad "userspace: login.sh failed (exit $rc), expected exit 0"
elif [[ "$login_argv" != *"--proxy $proxy --noproxy "* ]]; then
  bad "userspace: the Vault login does not go through $proxy with --noproxy"
elif [[ "$oidc_argv" == *--proxy* || "$oidc_argv" == *--noproxy* ]]; then
  bad "userspace: the OIDC request got a proxy option"
elif ! grep -q -F -- 'audience=' "$work/env" \
  || grep -F -- 'audience=' "$work/env" | grep -v -q -F -- 'https_proxy=http://egress.invalid:3128'; then
  bad "userspace: the OIDC request did not keep the runner's HTTPS_PROXY"
elif [ "$(login_calls)" -ne 1 ]; then
  bad "userspace: expected one login request, got $(login_calls)"
else
  echo "OK: userspace: Vault login through $proxy, OIDC with the runner's proxy"
fi
no_leaks userspace
refused 'userspace: claim mismatch' 'Vault refused claim environment.' \
  VAULT_PROXY="$proxy" FAKE_LOGIN=claim-env
refused 'userspace: login timeout' 'Vault did not answer the login within 15 seconds.' \
  VAULT_PROXY="$proxy" FAKE_LOGIN=timeout

# Only a proxy on 127.0.0.1 gets the OIDC token: no request at all otherwise.
for other in http://10.0.0.1:1055 http://localhost:1055 socks5://127.0.0.1:1055 \
  http://127.0.0.1:1055/x http://127.0.0.1: 'http://127.0.0.1:1055 -k'; do
  refused "proxy '$other'" 'is not a loopback Tailscale proxy' VAULT_PROXY="$other"
  if [ -s "$work/argv" ]; then
    bad "proxy '$other': login.sh sent a request"
  fi
done

# No 'set -x' and no echo of a secret variable in the script.
if grep -n -E '^[[:space:]]*set[[:space:]]+-[a-z]*x' "$login"; then
  echo "::error::login.sh uses set -x"
  status=1
fi

exit "$status"

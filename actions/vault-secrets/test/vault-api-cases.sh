#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs login.sh, read-token.sh and check-values.sh directly, without Vault or
# the network. A fake curl on PATH answers the OIDC token request, the Vault
# login and the token reads with canned JSON, and records its argv.
# Checks of login.sh:
#   - the login request (role, JWT in the body from stdin, audience);
#   - the message for each refusal (role not found for each role source,
#     claim mismatch, rate limit, other errors), with the facts of the run;
#   - timeouts and a Vault URL that is not allowed;
#   - every '::add-mask::' comes before the first write to GITHUB_OUTPUT;
#   - the JWT, the Vault token and the request token never appear in the log
#     except in '::add-mask::' lines, and never in argv;
#   - one login request, no retry, no revoke-self. The one exception (release
#     1.2): curl did not send the login (name lookup or connection failed or
#     timed out, or the proxy could not open a tunnel). Then up to 3 tries,
#     with one log line per new try. A sent login, any HTTP answer, a TLS
#     error and a missing -w line get no new try;
#   - network-mode userspace (VAULT_PROXY): the Vault login goes through the
#     loopback proxy and ignores NO_PROXY, the OIDC request keeps the runner's
#     proxy environment, and a proxy that is not on loopback gets no request.
# Checks of read-token.sh (github-token without '/'):
#   - the engines in the order github, github-members, github-admin; 403 and
#     404 go on to the next engine; the first token stops the search, so each
#     path is read at most once;
#   - other errors and timeouts stop at once with their own message; a read
#     that curl did not send gets up to 3 tries (the same rule as the login);
#   - 403 in every engine gives the message that the role has no grant;
#   - the GitHub token is masked before the write to GITHUB_OUTPUT, and no
#     secret value is in the log or in argv;
#   - network-mode userspace (VAULT_PROXY): every token read goes through the
#     loopback proxy and ignores NO_PROXY; a proxy that is not on loopback gets
#     no request.
# Checks of check-values.sh: output secrets holds the vault-action outputs and
# the token of the token step; an empty value fails.
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
gh_token='ghs_dummyGitHubToken0123456789abcdef'
gh_token2='ghs_dummySecondToken9876543210fedcba'

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
# Like curl, it writes the -w line also when it fails, with the values that
# real curl gives (checked with curl 8.5 and 8.7):
#   not sent    time_pretransfer 0; time_namelookup 0 for a name lookup timeout
#   sent        time_pretransfer > 0
# An answer can be a list 'a,b,c': call n of that URL gets word n, the last
# word repeats. Counts are kept in FAKE_COUNT.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_ARGV"
target="" prev="" data=false wout=""
for a in "$@"; do
  case "$a" in http://* | https://*) target="$a" ;; esac
  if [ "$prev" = -H ] && [ "${a#@}" != "$a" ]; then cat "${a#@}" >>"$FAKE_HEADERS"; fi
  [ "$prev" = -w ] && wout="$a"
  [ "$a" = --data-binary ] && data=true
  prev="$a"
done
if [ "$data" = true ]; then cat >>"$FAKE_BODY"; printf '\n' >>"$FAKE_BODY"; fi
printf '%s https_proxy=%s\n' "$target" "${HTTPS_PROXY:-}" >>"$FAKE_ENV"
# Word n of the list $1 for call n of this URL.
pick() {
  local n words
  n="$(grep -c -x -F -- "$target" "$FAKE_COUNT" || true)"
  printf '%s\n' "$target" >>"$FAKE_COUNT"
  IFS=, read -r -a words <<<"$1"
  [ "$n" -lt "${#words[@]}" ] || n=$((${#words[@]} - 1))
  printf '%s' "${words[$n]}"
}
# Writes the -w line: HTTP code $1, CONNECT code $2, name lookup time $3,
# pretransfer time $4.
wline() {
  local w="$wout"
  w="${w//'%{http_code}'/$1}"
  w="${w//'%{http_connect}'/$2}"
  w="${w//'%{time_namelookup}'/$3}"
  w="${w//'%{time_pretransfer}'/$4}"
  printf '%b' "$w"
}
answer() { printf '%s' "$2"; wline "$1" 000 0.001200 0.010500; }
# Fails like curl: exit code $1, stderr text $2, then the -w values $3...
fails() { echo "curl: ($1) $2" >&2; wline "${@:3}"; exit "$1"; }
# The failures of a Vault request. Not sent: time_pretransfer 0.
vault_fail() {
  case "$1" in
    timeout) fails 28 'Operation timed out after 15000 milliseconds with 0 bytes received' 000 000 0.001200 0.010500 ;;
    lookup-timeout) fails 28 'Resolving timed out after 5000 milliseconds' 000 000 0.000000 0.000000 ;;
    lookup-failed) fails 6 'Could not resolve host: vault-ospo.eng-svc.aws.tenstorrent.com' 000 000 0.000000 0.000000 ;;
    refused) fails 7 'Failed to connect' 000 000 0.001200 0.000000 ;;
    connect-timeout) fails 28 'Failed to connect after 5002 ms: Timeout was reached' 000 000 0.001200 0.000000 ;;
    proxy-502) fails 56 'CONNECT tunnel failed, response 502' 000 502 0.000100 0.000000 ;;
    proxy-403) fails 56 'CONNECT tunnel failed, response 403' 000 403 0.000100 0.000000 ;;
    reset) fails 56 'Recv failure: Connection reset by peer' 000 000 0.001200 0.010500 ;;
    tls) fails 35 'TLS connect error' 000 000 0.001200 0.000000 ;;
    no-w) echo "curl: (28) Resolving timed out after 5000 milliseconds" >&2; exit 28 ;;
    *) echo "fake curl: unknown answer $1" >&2; exit 99 ;;
  esac
}
case "$target" in
  *'audience='*)
    case "$FAKE_OIDC" in
      ok) answer 200 "{\"count\":1,\"value\":\"$FAKE_JWT\"}" ;;
      empty) answer 200 '{}' ;;
      denied) answer 403 '{"message":"no"}' ;;
      timeout) fails 28 'Operation timed out' 000 000 0.001200 0.010500 ;;
    esac
    ;;
  */v1/auth/jwt-github/login)
    role="$(sed -n 's/.*"role":"\([^"]*\)".*/\1/p' "$FAKE_BODY" | tail -n 1)"
    mode="$(pick "$FAKE_LOGIN")"
    case "$mode" in
      ok) answer 200 "{\"auth\":{\"client_token\":\"$FAKE_VAULT_TOKEN\",\"policies\":[\"default\"]}}" ;;
      notoken) answer 200 '{"auth":null}' ;;
      notfound) answer 400 "{\"errors\":[\"role \\\"$role\\\" could not be found\"]}" ;;
      claim-env) answer 400 '{"errors":["error validating claims: claim \"environment\" does not match any associated bound claim values"]}' ;;
      claim-wf) answer 400 '{"errors":["error validating claims: claim \"job_workflow_ref\" does not match any associated bound claim values"]}' ;;
      ratelimit) answer 429 '{"errors":["request path \"auth/jwt-github/login\": rate limit quota exceeded"]}' ;;
      e500) answer 500 '{"errors":["internal ::error::boom\nsecond line"]}' ;;
      e503) answer 503 '{"errors":["Vault is sealed"]}' ;;
      nobody) answer 502 '<html>bad gateway</html>' ;;
      *) vault_fail "$mode" ;;
    esac
    ;;
  */v1/*/token/*)
    # FAKE_ENGINES: '<engine>=<answer>' words; an engine not listed is denied.
    # A word '<engine>:<token set>=<answer>' is for that token set only.
    engine="${target#*/v1/}"
    engine="${engine%%/*}"
    tset="${target##*/}"
    mode=denied
    for w in $FAKE_ENGINES; do
      [ "${w%%=*}" = "$engine" ] && mode="${w#*=}"
    done
    for w in $FAKE_ENGINES; do
      [ "${w%%=*}" = "$engine:$tset" ] && mode="${w#*=}"
    done
    mode="$(pick "$mode")"
    case "$mode" in
      ok) answer 200 "{\"lease_id\":\"\",\"data\":{\"token\":\"$FAKE_GH_TOKEN\",\"permissions\":{\"contents\":\"read\"}}}" ;;
      ok2) answer 200 "{\"lease_id\":\"\",\"data\":{\"token\":\"$FAKE_GH_TOKEN2\",\"permissions\":{\"metadata\":\"read\"}}}" ;;
      quote) answer 200 '{"data":{"token":"ghs_a\"b"}}' ;;
      notoken) answer 200 '{"data":{}}' ;;
      denied) answer 403 '{"errors":["1 error occurred:\n\t* permission denied\n\n"]}' ;;
      notfound) answer 404 '{"errors":[]}' ;;
      ratelimit) answer 429 '{"errors":["rate limit quota exceeded"]}' ;;
      e500) answer 500 '{"errors":["installation ::error:: not found\nsecond line"]}' ;;
      nobody) answer 502 '<html>bad gateway</html>' ;;
      *) vault_fail "$mode" ;;
    esac
    ;;
  *) echo "fake curl: unexpected URL $target" >&2; exit 7 ;;
esac
FAKE
chmod +x "$work/bin/curl"
# A fake sleep: records the seconds, does not wait.
cat >"$work/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SLEEP"
FAKE
chmod +x "$work/bin/sleep"
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
  : >"$work/count"
  : >"$work/sleep"
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
    FAKE_ARGV="$work/argv" FAKE_HEADERS="$work/headers" FAKE_BODY="$work/body" FAKE_ENV="$work/env" FAKE_COUNT="$work/count" FAKE_SLEEP="$work/sleep" \
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

# ── Login tries when curl did not send the login (release 1.2) ─────────────
# Fails unless login.sh, with the replaced inputs $5..., exits with success
# ($2 = ok) or failure ($2 = fail), sends $3 login requests with the same body,
# waits 2 seconds before each new try, logs one line per new try, and logs the
# text $4. A failure must write no output.
login_tries() {
  local title="$1" want="$2" calls="$3" text="$4" n retries
  shift 4
  run_login "$@"
  n="$(login_calls)"
  retries="$(printf '%s\n' "$log" | grep -c -E '^Could not reach Vault \(.*\)\. Try [23] of 3\.$' || true)"
  if [ "$want" = ok ] && [ "$rc" -ne 0 ]; then
    bad "$title: login.sh failed (exit $rc), expected exit 0"
  elif [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
    bad "$title: login.sh succeeded, expected a failure"
  elif [ "$want" = fail ] && printf '%s\n' "$log" | grep -q '^vault-token<<'; then
    bad "$title: login.sh wrote output vault-token"
  elif [ "$n" -ne "$calls" ]; then
    bad "$title: login.sh sent $n login requests, expected $calls"
  elif [ "$retries" -ne $((calls - 1)) ]; then
    bad "$title: $retries lines 'Could not reach Vault ... Try n of 3.', expected $((calls - 1))"
  elif [ "$(grep -c -x -F -- 2 "$work/sleep" || true)" -ne $((calls - 1)) ] \
    || [ "$(wc -l <"$work/sleep" | tr -d ' ')" -ne $((calls - 1)) ]; then
    bad "$title: expected $((calls - 1)) waits of 2 seconds, got: $(tr '\n' ' ' <"$work/sleep")"
  elif [ "$(sort -u "$work/body" | grep -c . || true)" -ne 1 ]; then
    bad "$title: the login body is not the same in each try"
  elif [ "$(grep -c -F -- 'audience=' "$work/argv")" -ne 1 ]; then
    bad "$title: expected one OIDC request"
  elif ! printf '%s\n' "$log" | grep -q -F -- "$text"; then
    bad "$title: the log does not have '$text'"
  else
    echo "OK: login tries: $title"
  fi
  no_leaks "$title"
}

not_reached="the action could not reach Vault $url in 3 tries"
login_tries 'name lookup timeout, then success' ok 2 \
  'Could not reach Vault (name lookup timed out). Try 2 of 3.' \
  FAKE_LOGIN=lookup-timeout,ok
login_tries 'connection failed, connection timeout, then success' ok 3 \
  'Could not reach Vault (connection timed out). Try 3 of 3.' \
  FAKE_LOGIN=refused,connect-timeout,ok
login_tries 'name lookup timeout 3 times (run 45458169437)' fail 3 \
  "$not_reached (name lookup timed out, curl exit 28). Vault did not get the login. The likely cause is a short network problem on the tailnet. Run the job again." \
  FAKE_LOGIN=lookup-timeout
login_tries 'name lookup failed 3 times' fail 3 \
  "$not_reached (name lookup failed, curl exit 6). Vault did not get the login." \
  FAKE_LOGIN=lookup-failed
login_tries 'connection failed 3 times' fail 3 "$not_reached (connection failed, curl exit 7)." \
  FAKE_LOGIN=refused
login_tries 'connection timeout 3 times' fail 3 "$not_reached (connection timed out, curl exit 28)." \
  FAKE_LOGIN=connect-timeout
login_tries 'not sent, then sent and refused: no more tries' fail 2 'Vault refused claim environment.' \
  FAKE_LOGIN=lookup-timeout,claim-env,ok
# Sent, or not certain that it was not sent: one login, no new try.
login_tries 'sent, no answer in time: no new try' fail 1 \
  'Vault did not answer the login within 15 seconds. The likely cause is a stalled network connection on the tailnet. Run the job again.' \
  FAKE_LOGIN=timeout,ok
login_tries 'HTTP 400: no new try' fail 1 'Vault refused claim environment.' FAKE_LOGIN=claim-env,ok
login_tries 'HTTP 429: no new try' fail 1 'too many logins (rate limit)' FAKE_LOGIN=ratelimit,ok
login_tries 'HTTP 500: no new try' fail 1 '(HTTP 500)' FAKE_LOGIN=e500,ok
login_tries 'HTTP 503: no new try' fail 1 '(HTTP 503). Vault said: Vault is sealed.' FAKE_LOGIN=e503,ok
login_tries 'HTTP 502 of Vault: no new try' fail 1 '(HTTP 502)' FAKE_LOGIN=nobody,ok
login_tries 'connection reset after send: no new try' fail 1 '(curl exit 56)' FAKE_LOGIN=reset,ok
login_tries 'TLS error: no new try' fail 1 '(curl exit 35)' FAKE_LOGIN=tls,ok
login_tries 'no -w line from curl: no new try' fail 1 'Vault did not answer the login within 15 seconds.' \
  FAKE_LOGIN=no-w,ok
# Userspace: the proxy does the name lookup and the connection to Vault. A 5xx
# answer to CONNECT means that no tunnel opened, so Vault did not get the login.
login_tries 'userspace: proxy cannot connect to Vault, then success' ok 2 \
  'Could not reach Vault (the Tailscale proxy could not connect to Vault, HTTP 502). Try 2 of 3.' \
  VAULT_PROXY="$proxy" FAKE_LOGIN=proxy-502,ok
login_tries 'userspace: proxy cannot connect to Vault 3 times' fail 3 \
  "$not_reached (the Tailscale proxy could not connect to Vault, HTTP 502, curl exit 56)." \
  VAULT_PROXY="$proxy" FAKE_LOGIN=proxy-502
login_tries 'userspace: proxy not listening, then success' ok 2 \
  'Could not reach Vault (connection to the Tailscale proxy failed). Try 2 of 3.' \
  VAULT_PROXY="$proxy" FAKE_LOGIN=refused,ok
login_tries 'userspace: CONNECT timeout, then success' ok 2 \
  'Could not reach Vault (connection through the Tailscale proxy timed out). Try 2 of 3.' \
  VAULT_PROXY="$proxy" FAKE_LOGIN=connect-timeout,ok
login_tries 'userspace: proxy refuses CONNECT (403): no new try' fail 1 '(curl exit 56)' \
  VAULT_PROXY="$proxy" FAKE_LOGIN=proxy-403,ok
login_tries 'userspace: sent, no answer in time: no new try' fail 1 \
  'Vault did not answer the login within 15 seconds.' \
  VAULT_PROXY="$proxy" FAKE_LOGIN=timeout,ok

# Only a proxy on 127.0.0.1 gets the OIDC token: no request at all otherwise.
for other in http://10.0.0.1:1055 http://localhost:1055 socks5://127.0.0.1:1055 \
  http://127.0.0.1:1055/x http://127.0.0.1: http://127.0.0.1:65536 'http://127.0.0.1:1055 -k'; do
  refused "proxy '$other'" 'is not a loopback Tailscale proxy' VAULT_PROXY="$other"
  if [ -s "$work/argv" ]; then
    bad "proxy '$other': login.sh sent a request"
  fi
done

# ── read-token.sh ───────────────────────────────────────────────────────────
read_token="$here/../read-token.sh"
set_name='tenstorrent--.github--contents-read'

# Runs read-token.sh like run_login. Sets rc and log.
run_read() {
  local all="$work/all"
  : >"$all"
  : >"$work/argv"
  : >"$work/headers"
  : >"$work/body"
  : >"$work/env"
  : >"$work/count"
  : >"$work/sleep"
  rc=0
  env -i PATH="$work/bin:$PATH" \
    VAULT_URL="$url" \
    VAULT_TOKEN="$vault_token" \
    TOKEN_SET="$set_name" \
    TOKEN_INPUT=contents-read \
    ROLE=tenstorrent--.github--vault-action-test \
    REPOSITORY=tenstorrent/.github \
    GITHUB_OUTPUT="$all" \
    FAKE_ARGV="$work/argv" FAKE_HEADERS="$work/headers" FAKE_BODY="$work/body" FAKE_ENV="$work/env" FAKE_COUNT="$work/count" FAKE_SLEEP="$work/sleep" \
    FAKE_JWT="$jwt" FAKE_VAULT_TOKEN="$vault_token" FAKE_OIDC=ok FAKE_LOGIN=ok \
    FAKE_GH_TOKEN="$gh_token" FAKE_GH_TOKEN2="$gh_token2" FAKE_ENGINES='github=ok' \
    "$@" \
    bash "$read_token" >>"$all" 2>&1 || rc=$?
  log="$(cat "$all")"
}

# The engines that read-token.sh asked, in order, one word each.
asked() {
  sed -n 's|.*/v1/\([^/]*\)/token/.*|\1|p' "$work/argv" | tr '\n' ' ' | sed 's/ $//'
}

# Fails if a secret value appears outside '::add-mask::' lines and outside the
# token output block, or appears in argv.
no_read_leaks() {
  local title="$1" value
  for value in "$vault_token" "$gh_token"; do
    if printf '%s\n' "$log" | awk -v v="$value" '
        /^token<</ { d = substr($0, 8); on = 1; next }
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
}

# Fails unless read-token.sh, with the replaced inputs $3..., gets the token
# after asking the engines $2 (in this order).
found() {
  local title="$1" want_asked="$2" got first_output last_mask
  shift 2
  run_read "$@"
  got="$(printf '%s\n' "$log" | awk '
    /^token<</ { d = substr($0, 8); on = 1; next }
    on && $0 == d { on = 0; next }
    on { print }')"
  first_output="$(printf '%s\n' "$log" | grep -n '^token<<' | head -n 1 | cut -d: -f1)"
  last_mask="$(printf '%s\n' "$log" | grep -n '^::add-mask::' | tail -n 1 | cut -d: -f1)"
  if [ "$rc" -ne 0 ]; then
    bad "$title: read-token.sh failed (exit $rc), expected exit 0"
  elif [ "$got" != "$gh_token" ]; then
    bad "$title: output token is not the GitHub token"
  elif ! printf '%s\n' "$log" | grep -q -x -F -- "::add-mask::$gh_token"; then
    bad "$title: no ::add-mask:: line for the GitHub token"
  elif [ -z "$first_output" ] || [ "$last_mask" -ge "$first_output" ]; then
    bad "$title: the ::add-mask:: line comes after the write to GITHUB_OUTPUT"
  elif [ "$(asked)" != "$want_asked" ]; then
    bad "$title: asked engines '$(asked)', expected '$want_asked'"
  elif [ "$(grep -c -x -F -- "X-Vault-Token: $vault_token" "$work/headers")" -ne "$(wc -l <"$work/argv" | tr -d ' ')" ]; then
    bad "$title: a token read has no X-Vault-Token header from a pipe"
  elif ! printf '%s\n' "$log" | grep -q -x -F -- "Found GitHub token set $set_name (from github-token: contents-read)."; then
    bad "$title: no success line with the token set name"
  elif printf '%s\n' "$log" | grep -v '^::add-mask::' | grep -q -E 'github-(members|admin)/|github/token'; then
    bad "$title: the log shows the engine"
  else
    echo "OK: token read: $title"
  fi
  no_read_leaks "$title"
}

found 'found in the 1st engine (github)' 'github' FAKE_ENGINES='github=ok'
found 'found in the 2nd engine (github-members)' 'github github-members' \
  FAKE_ENGINES='github=denied github-members=ok github-admin=ok'
found 'found in the 3rd engine (github-admin)' 'github github-members github-admin' \
  FAKE_ENGINES='github=denied github-members=denied github-admin=ok'
found '404 goes on to the next engine' 'github github-members github-admin' \
  FAKE_ENGINES='github=notfound github-members=denied github-admin=ok'
found 'input with blanks' 'github' 'TOKEN_INPUT= contents-read '

run_read TOKEN_INPUT="$set_name"
if [ "$rc" -ne 0 ] || ! printf '%s\n' "$log" | grep -q -x -F -- "Found GitHub token set $set_name."; then
  bad "full name: no success line without '(from github-token: ...)'"
else
  echo "OK: token read: full name gives a success line without the input"
fi

# Fails unless read-token.sh, with the replaced inputs $4..., fails with an
# error annotation that contains $3, after asking the engines $2, and writes
# no output.
read_refused() {
  local title="$1" want_asked="$2" want="$3"
  shift 3
  run_read "$@"
  if [ "$rc" -eq 0 ]; then
    bad "$title: read-token.sh succeeded, expected a failure"
  elif ! printf '%s\n' "$log" | grep -F -- '::error title=vault-secrets::' | grep -q -F -- "$want"; then
    bad "$title: read-token.sh failed, but not with the message '$want'"
  elif printf '%s\n' "$log" | grep -q '^token<<'; then
    bad "$title: read-token.sh wrote output token"
  elif [ "$(asked)" != "$want_asked" ]; then
    bad "$title: asked engines '$(asked)', expected '$want_asked'"
  else
    echo "OK: token read refused: $title"
  fi
  no_read_leaks "$title"
}

no_grant="Role tenstorrent--.github--vault-action-test has no grant for GitHub token set $set_name (from github-token: contents-read). Check the token key in github_tokens of your workflow entry in grants/repos/tenstorrent/.github.yaml in github-vault-iac."
read_refused 'not found in any engine' 'github github-members github-admin' "$no_grant" \
  FAKE_ENGINES=''
read_refused 'not found, full name' 'github github-members github-admin' \
  "Role tenstorrent--.github--vault-action-test has no grant for GitHub token set $set_name. Check" \
  FAKE_ENGINES='' TOKEN_INPUT="$set_name"
read_refused 'not found, 404 and 403' 'github github-members github-admin' "$no_grant" \
  FAKE_ENGINES='github=notfound github-admin=notfound'
read_refused '5xx in the 1st engine stops' 'github' \
  "Vault refused the read of GitHub token set $set_name (from github-token: contents-read) (HTTP 500). Vault said: installation error not found second line. Role: tenstorrent--.github--vault-action-test." \
  FAKE_ENGINES='github=e500 github-members=ok'
read_refused '5xx in the 2nd engine stops' 'github github-members' '(HTTP 500)' \
  FAKE_ENGINES='github=denied github-members=e500 github-admin=ok'
read_refused 'answer without JSON' 'github' '(HTTP 502). Vault said: .' \
  FAKE_ENGINES='github=nobody'
read_refused 'rate limit stops' 'github' '(HTTP 429). Vault said: rate limit quota exceeded.' \
  FAKE_ENGINES='github=ratelimit github-members=ok'
read_refused 'timeout stops' 'github' \
  "Vault did not answer the read of GitHub token set $set_name (from github-token: contents-read) within 15 seconds." \
  FAKE_ENGINES='github=timeout github-members=ok'
read_refused 'timeout in the 3rd engine' 'github github-members github-admin' 'within 15 seconds' \
  FAKE_ENGINES='github-admin=timeout'
read_refused 'connection error: 3 tries, then stops' 'github github github' \
  "the action could not reach Vault $url for the read of GitHub token set $set_name (from github-token: contents-read) in 3 tries (connection failed, curl exit 7). Vault did not get the read." \
  FAKE_ENGINES='github=refused github-members=ok'
read_refused 'answer without a token' 'github' \
  "Vault answered the read of GitHub token set $set_name (from github-token: contents-read) without a token." \
  FAKE_ENGINES='github=notoken github-members=ok'
read_refused 'no Vault token' '' 'internal error: no Vault token' VAULT_TOKEN=
read_refused 'bad token set name' '' 'internal error: no valid token set name' 'TOKEN_SET=a/b'
read_refused 'empty token set name' '' 'internal error: no valid token set name' TOKEN_SET=
for other in https://vault-ospo.invalid http://vault-ospo.eng-svc.aws.tenstorrent.com ''; do
  read_refused "token read, vault URL '$other'" '' 'is not an OSPO Vault URL' VAULT_URL="$other"
done

# Each path at most once: no engine is asked twice in any case above. Checked
# here once more for the longest search.
run_read FAKE_ENGINES='github-admin=ok'
if [ "$(sort "$work/argv" | uniq -d | wc -l | tr -d ' ')" -ne 0 ]; then
  bad "token read: a path was read more than once"
else
  echo "OK: token read: each path read at most once"
fi

# ── check-values.sh ─────────────────────────────────────────────────────────
check="$here/../check-values.sh"

# Runs check-values.sh with VAULT_OUTPUTS=$1 and TOKEN_VALUE=$2. Sets rc, log
# and secrets_out (the output secrets).
run_check() {
  local all="$work/all"
  : >"$all"
  rc=0
  env -i PATH="$PATH" VAULT_OUTPUTS="$1" TOKEN_VALUE="$2" GITHUB_OUTPUT="$all" \
    bash "$check" >>"$all" 2>&1 || rc=$?
  log="$(cat "$all")"
  secrets_out="$(awk '
    /^secrets<</ { d = substr($0, 10); on = 1; next }
    on && $0 == d { on = 0; next }
    on { print }' "$all")"
}

# Fails unless check-values.sh succeeds and output secrets equals the JSON $4.
check_gives() {
  local title="$1"
  run_check "$2" "$3"
  if [ "$rc" -ne 0 ]; then
    bad "check $title: check-values.sh failed (exit $rc)"
  elif ! jq -e --argjson want "$4" '. == $want' <<<"$secrets_out" >/dev/null 2>&1; then
    bad "check $title: output secrets is not as expected"
  else
    echo "OK: check: $title"
  fi
}
check_gives 'secrets and token from the token step' '{"KV_TEST":"kv-dummy"}' "$gh_token" \
  "{\"KV_TEST\":\"kv-dummy\",\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}"
check_gives 'token from the token step only (read step skipped)' '{}' "$gh_token" \
  "{\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}"
check_gives 'token path read by vault-action' "{\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}" '' \
  "{\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}"
check_gives 'secrets only' '{"KV_TEST":"kv-dummy"}' '' '{"KV_TEST":"kv-dummy"}'
check_gives 'multi-line value' '{"KEY":"line1\nline2"}' '' '{"KEY":"line1\nline2"}'

run_check '{"KV_TEST":""}' "$gh_token"
if [ "$rc" -eq 0 ] || ! printf '%s\n' "$log" | grep -q -F -- 'Vault gave an empty value for KV_TEST.' \
  || printf '%s\n' "$log" | grep -q '^secrets<<'; then
  bad "check: an empty value did not fail, or output secrets was written"
else
  echo "OK: check: an empty value fails and writes no output"
fi
run_check '{"VAULT_SECRETS_GITHUB_TOKEN":""}' ''
if [ "$rc" -eq 0 ] || ! printf '%s\n' "$log" | grep -q -F -- 'Vault gave an empty value for github-token.'; then
  bad "check: an empty token from vault-action did not fail with the github-token message"
else
  echo "OK: check: an empty token fails with the github-token message"
fi
# No value in the log: the log holds only the output block.
run_check '{"KV_TEST":"kv-dummy"}' "$gh_token"
if printf '%s\n' "$log" | awk '/^secrets<</ { d = substr($0, 10); on = 1; next } on && $0 == d { on = 0; next } on { next } { print }' \
  | grep -q -F -e "$gh_token" -e kv-dummy; then
  bad "check: a value appears in the log outside the output block"
else
  echo "OK: check: no value in the log"
fi

# ── read-token.sh in network-mode userspace (release 1.2) ──────────────────
# Kernel mode (VAULT_PROXY not set): no proxy option, as in 1.1.
run_read FAKE_ENGINES='github=denied github-members=ok'
if [ "$rc" -ne 0 ]; then
  bad "token read, kernel: read-token.sh failed (exit $rc), expected exit 0"
elif grep -q -E -- '--(no)?proxy' "$work/argv"; then
  bad "token read, kernel: curl got a proxy option"
else
  echo "OK: token read, kernel: no proxy option on any request"
fi

# Userspace: every token read goes through the loopback proxy, also with NO_PROXY=*.
found 'userspace, 2nd engine' 'github github-members' \
  VAULT_PROXY="$proxy" NO_PROXY='*' no_proxy='*' FAKE_ENGINES='github=denied github-members=ok'
if [ "$(wc -l <"$work/argv" | tr -d ' ')" -ne 2 ] \
  || [ "$(grep -c -F -- "--proxy $proxy --noproxy " "$work/argv")" -ne 2 ]; then
  bad "token read, userspace: a token read did not go through $proxy with --noproxy"
else
  echo "OK: token read, userspace: both reads through $proxy"
fi
read_refused 'userspace, timeout' 'github' 'within 15 seconds' \
  VAULT_PROXY="$proxy" FAKE_ENGINES='github=timeout'

# Only a proxy on 127.0.0.1 gets the Vault token: no request at all otherwise.
for other in http://10.0.0.1:1055 http://localhost:1055 socks5://127.0.0.1:1055 \
  http://127.0.0.1:1055/x http://127.0.0.1:65536 'http://127.0.0.1:1055 -k'; do
  read_refused "proxy '$other'" '' 'is not a loopback Tailscale proxy' VAULT_PROXY="$other"
  if [ -s "$work/argv" ]; then
    bad "token read, proxy '$other': read-token.sh sent a request"
  fi
done

# ── Token read tries when curl did not send the read (release 1.2) ─────────
# Prints the number of lines 'Could not reach Vault (...). Try n of 3.'.
read_retries() {
  printf '%s\n' "$log" | grep -c -E '^Could not reach Vault \(.*\)\. Try [23] of 3\.$' || true
}
found 'name lookup timeout, then found' 'github github' FAKE_ENGINES='github=lookup-timeout,ok'
if [ "$(read_retries)" -ne 1 ] || ! printf '%s\n' "$log" | grep -q -x -F -- 'Could not reach Vault (name lookup timed out). Try 2 of 3.' \
  || [ "$(tr '\n' ' ' <"$work/sleep")" != '2 ' ]; then
  bad "token read tries: expected one retry line and one wait of 2 seconds"
else
  echo "OK: token read tries: one retry line, one wait of 2 seconds"
fi
found 'denied, then 2 connection timeouts in the 2nd engine, then the 3rd engine' \
  'github github-members github-members github-members github-admin' \
  FAKE_ENGINES='github=denied github-members=connect-timeout,refused,denied github-admin=ok'
read_refused 'name lookup timeout 3 times' 'github github github' \
  "for the read of GitHub token set $set_name (from github-token: contents-read) in 3 tries (name lookup timed out, curl exit 28). Vault did not get the read. The likely cause is a short network problem on the tailnet. Run the job again." \
  FAKE_ENGINES='github=lookup-timeout github-members=ok'
read_refused 'sent, no answer in time: no new try' 'github' 'within 15 seconds' \
  FAKE_ENGINES='github=timeout,ok'
read_refused 'HTTP 500: no new try' 'github' '(HTTP 500)' FAKE_ENGINES='github=e500,ok'
read_refused 'HTTP 429: no new try' 'github' '(HTTP 429)' FAKE_ENGINES='github=ratelimit,ok'
read_refused 'connection reset after send: no new try' 'github' '(curl exit 56)' \
  FAKE_ENGINES='github=reset,ok'
found 'userspace: proxy cannot connect to Vault, then found' 'github github' \
  VAULT_PROXY="$proxy" FAKE_ENGINES='github=proxy-502,ok'
read_refused 'userspace: proxy refuses CONNECT (403): no new try' 'github' '(curl exit 56)' \
  VAULT_PROXY="$proxy" FAKE_ENGINES='github=proxy-403,ok'

# ── read-token.sh with a list of token sets (release 1.2) ──────────────────
set2='tenstorrent--.github--metadata-read'
list2="[{\"set\":\"$set_name\",\"key\":\"contents-read\",\"input\":\"contents-read\"},{\"set\":\"$set2\",\"key\":\"metadata-read\",\"input\":\"Metadata-Read\"}]"
# contents-read is in github, metadata-read in github-members.
two_engines="github:$set_name=ok github-members:$set2=ok2"

# Prints the block of output $1 in the log.
out_block() {
  printf '%s\n' "$log" | awk -v n="$1" '
    index($0, n "<<") == 1 && !on { d = substr($0, length(n) + 3); on = 1; next }
    on && $0 == d { on = 0; next }
    on { print }'
}
# Fails if a secret value appears outside '::add-mask::' lines and outside the
# token and tokens output blocks, or appears in argv.
no_list_leaks() {
  local title="$1" value
  for value in "$vault_token" "$gh_token" "$gh_token2"; do
    if printf '%s\n' "$log" | awk -v v="$value" '
        /^tokens?<</ { d = substr($0, index($0, "<<") + 2); on = 1; next }
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
}
# Number of reads of the token set $1 in this run.
reads_of() {
  grep -c -F -- "/token/$1" "$work/argv" || true
}

# Fails unless read-token.sh, with the list and the replaced inputs $3...,
# gets both tokens after the requests $2 (engines, in order).
list_found() {
  local title="$1" want_asked="$2" first_output last_mask
  shift 2
  run_read TOKEN_LIST="$list2" "$@"
  first_output="$(printf '%s\n' "$log" | grep -n -E '^tokens?<<' | head -n 1 | cut -d: -f1)"
  last_mask="$(printf '%s\n' "$log" | grep -n '^::add-mask::' | tail -n 1 | cut -d: -f1)"
  if [ "$rc" -ne 0 ]; then
    bad "list $title: read-token.sh failed (exit $rc), expected exit 0"
  elif [ "$(out_block token)" != "$gh_token" ]; then
    bad "list $title: output token is not the token of the first entry"
  elif ! out_block tokens | jq -e --arg a "$gh_token" --arg b "$gh_token2" \
    '. == {"contents-read": $a, "metadata-read": $b} and (keys_unsorted == ["contents-read", "metadata-read"])' >/dev/null; then
    bad "list $title: output tokens is not {contents-read, metadata-read} with both tokens"
  elif [ "$(out_block tokens | grep -c .)" -ne 1 ]; then
    bad "list $title: output tokens is not one line of JSON"
  elif ! printf '%s\n' "$log" | grep -q -x -F -- "::add-mask::$gh_token" \
    || ! printf '%s\n' "$log" | grep -q -x -F -- "::add-mask::$gh_token2"; then
    bad "list $title: no ::add-mask:: line for each token"
  elif [ -z "$first_output" ] || [ "$last_mask" -ge "$first_output" ]; then
    bad "list $title: an ::add-mask:: line comes after the first write to GITHUB_OUTPUT"
  elif [ "$(asked)" != "$want_asked" ]; then
    bad "list $title: asked engines '$(asked)', expected '$want_asked'"
  elif ! printf '%s\n' "$log" | grep -q -x -F -- "Found GitHub token set $set_name (from github-token: contents-read)." \
    || ! printf '%s\n' "$log" | grep -q -x -F -- "Found GitHub token set $set2 (from github-token: Metadata-Read)." \
    || ! printf '%s\n' "$log" | grep -q -x -F -- "Found 2 GitHub token sets."; then
    bad "list $title: no success line for each token set"
  elif [ "$(grep -c -x -F -- "X-Vault-Token: $vault_token" "$work/headers")" -ne "$(wc -l <"$work/argv" | tr -d ' ')" ]; then
    bad "list $title: a token read has no X-Vault-Token header from a pipe"
  elif printf '%s\n' "$log" | grep -v '^::add-mask::' | grep -q -E 'github-(members|admin)/|github/token'; then
    bad "list $title: the log shows the engine"
  else
    echo "OK: list: $title"
  fi
  no_list_leaks "list $title"
}

list_found 'two keys in two engines' 'github github github-members' FAKE_ENGINES="$two_engines"
# Each token set is read until its first success, and never again.
ok_reads="$(grep -c -E "/(github|github-members)/token/" "$work/argv" || true)"
if [ "$(reads_of "$set_name")" -ne 1 ] || [ "$(grep -c -F -- "/github-members/token/$set2" "$work/argv")" -ne 1 ] \
  || [ "$(sort "$work/argv" | uniq -d | wc -l | tr -d ' ')" -ne 0 ] || [ "$ok_reads" -ne 3 ]; then
  bad "list: a token set was read more than once"
else
  echo "OK: list: each token read exactly once, no path read twice"
fi
# The engine of the first key is not a hint: the second key starts in github again.
list_found 'first key in github-members, second key in github' 'github github-members github' \
  FAKE_ENGINES="github-members:$set_name=ok github:$set2=ok2"
list_found 'second key in github-admin' 'github github github-members github-admin' \
  FAKE_ENGINES="github:$set_name=ok github-admin:$set2=ok2"
# A read that curl did not send gets new tries, for each entry on its own.
list_found 'pre-send retry in the second entry' 'github github github-members github-members' \
  FAKE_ENGINES="github:$set_name=ok github-members:$set2=lookup-timeout,ok2"
if [ "$(read_retries)" -ne 1 ] || ! printf '%s\n' "$log" | grep -q -x -F -- 'Could not reach Vault (name lookup timed out). Try 2 of 3.'; then
  bad "list: pre-send retry: expected one retry line"
else
  echo "OK: list: pre-send retry of the second entry, one retry line"
fi
list_found 'pre-send retry in both entries' 'github github github github github-members github-members' \
  FAKE_ENGINES="github:$set_name=refused,connect-timeout,ok github-members:$set2=lookup-failed,ok2"

# Fails unless read-token.sh, with the list and the replaced inputs $4...,
# fails with an error that contains $3 after the requests $2, and writes no
# output at all.
list_refused() {
  local title="$1" want_asked="$2" want="$3"
  shift 3
  run_read TOKEN_LIST="$list2" "$@"
  if [ "$rc" -eq 0 ]; then
    bad "list $title: read-token.sh succeeded, expected a failure"
  elif ! printf '%s\n' "$log" | grep -F -- '::error title=vault-secrets::' | grep -q -F -- "$want"; then
    bad "list $title: read-token.sh failed, but not with the message '$want'"
  elif printf '%s\n' "$log" | grep -q -E '^tokens?<<'; then
    bad "list $title: read-token.sh wrote an output"
  elif [ "$(asked)" != "$want_asked" ]; then
    bad "list $title: asked engines '$(asked)', expected '$want_asked'"
  else
    echo "OK: list refused: $title"
  fi
  no_list_leaks "list $title"
}
list_refused 'second key has no grant' 'github github github-members github-admin' \
  "Role tenstorrent--.github--vault-action-test has no grant for GitHub token set $set2 (from github-token: Metadata-Read). Check the token key in github_tokens of your workflow entry in grants/repos/tenstorrent/.github.yaml in github-vault-iac." \
  FAKE_ENGINES="github:$set_name=ok"
# The first token was read and masked: its mask stays, but no output has it.
if ! printf '%s\n' "$log" | grep -q -x -F -- "::add-mask::$gh_token"; then
  bad "list: second key has no grant: the first token has no ::add-mask:: line"
else
  echo "OK: list: second key has no grant: first token masked, no output"
fi
list_refused 'first key has no grant: no read of the second' 'github github-members github-admin' \
  "has no grant for GitHub token set $set_name (from github-token: contents-read)." \
  FAKE_ENGINES="github:$set2=ok2"
list_refused 'second key: 5xx stops' 'github github' \
  "Vault refused the read of GitHub token set $set2 (from github-token: Metadata-Read) (HTTP 500)." \
  FAKE_ENGINES="github:$set_name=ok github:$set2=e500"
list_refused 'second key: not reached in 3 tries' 'github github github github' \
  "for the read of GitHub token set $set2 (from github-token: Metadata-Read) in 3 tries (name lookup timed out, curl exit 28)." \
  FAKE_ENGINES="github:$set_name=ok github:$set2=lookup-timeout"
list_refused 'second key: token with a quote' 'github github' \
  "Vault gave a token with characters that the action cannot put in output tokens, for GitHub token set $set2 (from github-token: Metadata-Read). Report this to OSPO." \
  FAKE_ENGINES="github:$set_name=ok github:$set2=quote"
list_refused 'list that does not start with TOKEN_SET' '' 'internal error: the token list does not start with token set' \
  TOKEN_SET="$set2" FAKE_ENGINES="github=ok"
list_refused 'list with a bad key' '' 'internal error: entry 2 of the token list is not valid.' \
  TOKEN_LIST="[{\"set\":\"$set_name\",\"key\":\"contents-read\",\"input\":\"x\"},{\"set\":\"$set2\",\"key\":\"a\\\"b\",\"input\":\"x\"}]"
list_refused 'token-list that is not JSON' '' 'internal error: output token-list of the prepare step is not a JSON array.' \
  TOKEN_LIST='not json'

# A list of one entry works as in release 1.1: output token only.
run_read TOKEN_LIST="[{\"set\":\"$set_name\",\"key\":\"contents-read\",\"input\":\"contents-read\"}]" \
  'TOKEN_INPUT=contents-read,'
if [ "$rc" -ne 0 ] || [ "$(out_block token)" != "$gh_token" ] || printf '%s\n' "$log" | grep -q '^tokens<<' \
  || ! printf '%s\n' "$log" | grep -q -x -F -- "Found GitHub token set $set_name (from github-token: contents-read)."; then
  bad "list of one entry: not the result of release 1.1"
else
  echo "OK: list of one entry: output token only, success line of release 1.1"
fi

# ── check-values.sh with output tokens (release 1.2) ───────────────────────
one_list="[{\"set\":\"$set_name\",\"key\":\"contents-read\",\"input\":\"contents-read\"}]"
both="{\"contents-read\":\"$gh_token\",\"metadata-read\":\"$gh_token2\"}"
# Runs check-values.sh with VAULT_OUTPUTS=$1, TOKEN_VALUE=$2, TOKEN_LIST=$3 and
# TOKENS_VALUE=$4. Sets rc, log, secrets_out and tokens_out.
run_check2() {
  local all="$work/all"
  : >"$all"
  rc=0
  env -i PATH="$PATH" VAULT_OUTPUTS="$1" TOKEN_VALUE="$2" TOKEN_LIST="$3" TOKENS_VALUE="$4" GITHUB_OUTPUT="$all" \
    bash "$check" >>"$all" 2>&1 || rc=$?
  log="$(cat "$all")"
  secrets_out="$(out_block secrets)"
  tokens_out="$(out_block tokens)"
}
tokens_give() {
  local title="$1" want_secrets="$6" want_tokens="$7"
  run_check2 "$2" "$3" "$4" "$5"
  if [ "$rc" -ne 0 ]; then
    bad "check tokens $title: check-values.sh failed (exit $rc)"
  elif ! jq -e --argjson want "$want_secrets" '. == $want' <<<"$secrets_out" >/dev/null 2>&1; then
    bad "check tokens $title: output secrets is not as expected"
  elif ! jq -e --argjson want "$want_tokens" '. == $want' <<<"$tokens_out" >/dev/null 2>&1; then
    bad "check tokens $title: output tokens is not as expected"
  else
    echo "OK: check tokens: $title"
  fi
}
tokens_give 'no github-token' '{"KV_TEST":"kv-dummy"}' '' '' '' '{"KV_TEST":"kv-dummy"}' '{}'
tokens_give 'path (read by vault-action)' "{\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}" '' '' '' \
  "{\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}" '{}'
tokens_give 'one key' '{}' "$gh_token" "$one_list" '' \
  "{\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}" "{\"contents-read\":\"$gh_token\"}"
tokens_give 'two keys' '{"KV_TEST":"kv-dummy"}' "$gh_token" "$list2" "$both" \
  "{\"KV_TEST\":\"kv-dummy\",\"VAULT_SECRETS_GITHUB_TOKEN\":\"$gh_token\"}" "$both"

# Fails unless check-values.sh fails with the text $6 and writes no output.
check_refused() {
  local title="$1" want="$6"
  run_check2 "$2" "$3" "$4" "$5"
  if [ "$rc" -eq 0 ]; then
    bad "check tokens $title: check-values.sh succeeded, expected a failure"
  elif ! printf '%s\n' "$log" | grep -q -F -- "$want"; then
    bad "check tokens $title: no message '$want'"
  elif printf '%s\n' "$log" | grep -q -E '^(secrets|tokens)<<'; then
    bad "check tokens $title: check-values.sh wrote an output"
  else
    echo "OK: check tokens refused: $title"
  fi
}
check_refused 'two keys, one empty' '{}' "$gh_token" "$list2" "{\"contents-read\":\"$gh_token\",\"metadata-read\":\"\"}" \
  '::error::Vault gave an empty value for github-token key metadata-read. Report this to OSPO.'
check_refused 'two keys, one missing' '{}' "$gh_token" "$list2" "{\"contents-read\":\"$gh_token\"}" \
  'Vault gave an empty value for github-token key metadata-read.'
check_refused 'two keys, no tokens output' '{}' "$gh_token" "$list2" '' \
  'Vault gave an empty value for github-token key contents-read.'
check_refused 'two keys, an extra key' '{}' "$gh_token" "$list2" \
  "{\"contents-read\":\"$gh_token\",\"metadata-read\":\"$gh_token2\",\"x\":\"y\"}" \
  'internal error: the tokens of the token step do not match the list in github-token.'
check_refused 'two keys, token is not the first' '{}' "$gh_token2" "$list2" "$both" \
  'internal error: the tokens of the token step do not match the list in github-token.'
check_refused 'one key, empty token' '{}' '' "$one_list" '' \
  '::error::Vault gave an empty value for github-token.'
# No value in the log: the log holds only the output blocks.
run_check2 '{"KV_TEST":"kv-dummy"}' "$gh_token" "$list2" "$both"
if printf '%s\n' "$log" | awk '/^(secrets|tokens)<</ { d = substr($0, index($0, "<<") + 2); on = 1; next } on && $0 == d { on = 0; next } on { next } { print }' \
  | grep -q -F -e "$gh_token" -e "$gh_token2" -e kv-dummy; then
  bad "check tokens: a value appears in the log outside the output blocks"
else
  echo "OK: check tokens: no value in the log"
fi

# No 'set -x' and no echo of a secret variable in the scripts.
for script in "$login" "$read_token" "$check"; do
  if grep -n -E '^[[:space:]]*set[[:space:]]+-[a-z]*x' "$script"; then
    echo "::error::$(basename "$script") uses set -x"
    status=1
  fi
done

exit "$status"

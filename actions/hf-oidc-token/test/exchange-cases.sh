#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # ok never fails; backticks are Markdown text.
# Test helper for .github/workflows/hf-oidc-token-test.yml. Not used by the action.
# Runs exchange.sh and check-models.sh directly, without GitHub, Hugging Face
# or the network. A fake curl on PATH answers the OIDC token request, the
# exchange and the auth-check requests with canned answers, and records its
# argv, the headers it read from '-H @file' and the request body.
# Checks of exchange.sh:
#   - the OIDC request asks for audience https://huggingface.co;
#   - the exchange request: endpoint, method, JSON body (grant_type,
#     subject_token_type, subject_token = the JWT, resource), JWT from stdin;
#   - every '::add-mask::' comes before the first write to GITHUB_OUTPUT;
#   - the JWT, the HF token and the request token never appear in the log
#     except in '::add-mask::' lines and the token output block, never in argv,
#     and the job summary never holds them;
#   - one exchange request, no retry;
#   - each failure class has its own message, with the identity values and
#     the Request ID for invalid_grant, and warns in mode warn (stopped=exchange);
#   - outputs token and expires-at.
# Checks of check-models.sh:
#   - one auth-check request per repository, with the token in a header from
#     a pipe; models and datasets paths;
#   - gated without access, not found, other errors: listed in
#     models-without-access with their reason; fail or warn by mode.
# Checks of both scripts: every curl call starts with -q (no .curlrc); with a
# real curl and a .curlrc that sets trace-ascii, no trace file is written
# (requests go to a closed local port, no network).
# Uses only dummy values: no real token.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exchange="$here/../exchange.sh"
models_sh="$here/../check-models.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
pass=0
request_token='dummy-request-token-5a1d0c3e'
hf_token='hf_oauth_dummyHuggingFaceToken0123456789'

b64url() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}
claims='{"repository":"tenstorrent/.github","ref":"refs/heads/main","event_name":"workflow_dispatch","workflow_ref":"tenstorrent/.github/.github/workflows/nightly.yml@refs/heads/main","job_workflow_ref":"tenstorrent/.github/.github/workflows/nightly.yml@refs/heads/main","iss":"https://token.actions.githubusercontent.com","aud":"https://huggingface.co"}'
jwt="$(b64url '{"alg":"RS256","typ":"JWT"}').$(b64url "$claims").dummysignature0123456789"
claims_called='{"repository":"tenstorrent/tt-metal","ref":"refs/heads/main","event_name":"schedule","workflow_ref":"tenstorrent/tt-metal/.github/workflows/caller.yml@refs/heads/main","job_workflow_ref":"tenstorrent/.github/.github/workflows/hf.yml@refs/heads/main","iss":"https://token.actions.githubusercontent.com","aud":"https://huggingface.co"}'
jwt_called="$(b64url '{"alg":"RS256","typ":"JWT"}').$(b64url "$claims_called").dummysignature9876543210"

# ── Fake curl ───────────────────────────────────────────────────────────────
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set +x
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_ARGV"
# -q must be the first argument: else curl reads ~/.curlrc first.
[ "${1:-}" = -q ] || printf '%s\n' "$*" >>"$FAKE_NOQ"
target="" prev="" data=false dump="" out=""
for a in "$@"; do
  case "$a" in http://* | https://*) target="$a" ;; esac
  if [ "$prev" = -H ] && [ "${a#@}" != "$a" ]; then cat "${a#@}" >>"$FAKE_HEADERS"; fi
  [ "$prev" = -D ] && dump="$a"
  [ "$prev" = -o ] && out="$a"
  [ "$a" = --data-binary ] && data=true
  prev="$a"
done
if [ "$data" = true ]; then cat >>"$FAKE_BODY"; printf '\n' >>"$FAKE_BODY"; fi
# answer <code> <body> [header line...]
answer() {
  local c="$1" b="$2"; shift 2
  if [ -n "$dump" ]; then
    { printf 'HTTP/2 %s\r\n' "$c"; for h in "$@"; do printf '%s\r\n' "$h"; done; printf '\r\n'; } >"$dump"
  fi
  if [ "$out" = /dev/null ]; then printf '%s' "$c"; else printf '%s\n%s' "$b" "$c"; fi
}
case "$target" in
  *'audience='*)
    case "$FAKE_OIDC" in
      ok) answer 200 "{\"count\":1,\"value\":\"$FAKE_JWT\"}" ;;
      empty) answer 200 '{}' ;;
      denied) answer 403 '{"message":"no"}' ;;
      timeout) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
    esac
    ;;
  https://huggingface.co/oauth/token)
    case "$FAKE_EXCHANGE" in
      ok) answer 200 "{\"access_token\":\"$FAKE_HF_TOKEN\",\"token_type\":\"bearer\",\"expires_in\":3600,\"issued_token_type\":\"urn:ietf:params:oauth:token-type:access_token\"}" 'x-request-id: Root=1-ok' ;;
      noexpiry) answer 200 "{\"access_token\":\"$FAKE_HF_TOKEN\"}" ;;
      notoken) answer 200 '{"token_type":"bearer"}' ;;
      multiline) answer 200 "{\"access_token\":\"$FAKE_HF_TOKEN\\n::set-env name=EVIL::1\"}" ;;
      carriage) answer 200 "{\"access_token\":\"$FAKE_HF_TOKEN\\r::set-env name=EVIL::1%0A::set-env name=EVIL::2\"}" ;;
      objtoken) answer 200 "{\"access_token\":{\"a\":\"$FAKE_HF_TOKEN\"}}" ;;
      badtoken) answer 200 '{"access_token":"has space"}' ;;
      grant) answer 400 '{"error":"invalid_grant","error_description":"No matching ::error:: publisher\nsecond"}' 'X-Request-Id: Root=1-abc-123' ;;
      request) answer 400 '{"error":"invalid_request","error_description":"bad resource"}' 'x-request-id: Root=1-req' ;;
      ratelimit) answer 429 '{"error":"rate_limited"}' ;;
      e500) answer 503 '<html>bad gateway</html>' ;;
      timeout) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
      refused) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
    esac
    ;;
  https://huggingface.co/api/*/auth-check)
    repo="${target#https://huggingface.co/api/}"
    repo="${repo%/auth-check}"
    case "$repo" in
      *gated*) answer 403 '{"error":"x"}' 'X-Error-Code: GatedRepo' 'X-Error-Message: Access to model is restricted' ;;
      *missing*) answer 401 '{"error":"x"}' 'X-Error-Code: RepoNotFound' ;;
      *broken*) answer 500 '{"error":"x"}' ;;
      *offline*) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
      *) answer 200 '{}' ;;
    esac
    ;;
  *) echo "fake curl: unexpected URL $target" >&2; exit 7 ;;
esac
FAKE
chmod +x "$work/bin/curl"

ok() { pass=$((pass + 1)); }
bad() {
  echo "FAIL: $1"
  printf '%s\n' "$log" | sed 's/^::/: :/; s/^/  | /'
  status=1
}

# Runs a script. stdout, stderr and GITHUB_OUTPUT go to one file in append
# mode, so the order of lines is the order of writes. Sets rc and log.
run_script() {
  local script="$1"; shift
  local all="$work/all"
  : >"$all"; : >"$work/argv"; : >"$work/headers"; : >"$work/body"; : >"$work/summary"; : >"$work/noq"
  rc=0
  env -i PATH="$work/bin:$PATH" \
    RESOURCE=ospo-ci-account \
    MODE=fail \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://token.invalid/oidc?api-version=2.0' \
GITHUB_REPOSITORY=tenstorrent/.github \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="$request_token" \
    HF_TOKEN=stored-token-must-not-be-used \
    GITHUB_OUTPUT="$all" \
    GITHUB_STEP_SUMMARY="$work/summary" \
    FAKE_ARGV="$work/argv" FAKE_HEADERS="$work/headers" FAKE_BODY="$work/body" FAKE_NOQ="$work/noq" \
    FAKE_JWT="$jwt" FAKE_HF_TOKEN="$hf_token" FAKE_OIDC=ok FAKE_EXCHANGE=ok \
    "$@" \
    bash "$script" >>"$all" 2>&1 || rc=$?
  log="$(cat "$all")"
  curl_calls=$((curl_calls + $(wc -l <"$work/argv")))
  if [ -s "$work/noq" ]; then
    noq_calls=$((noq_calls + $(wc -l <"$work/noq")))
    noq_first="${noq_first:-$(head -n 1 "$work/noq")}"
  fi
}
curl_calls=0
noq_calls=0
noq_first=""

output() {
  printf '%s\n' "$log" | awk -v k="$1" '
    index($0, k "<<") == 1 { d = substr($0, length(k) + 3); on = 1; next }
    on && $0 == d { on = 0; next }
    on { print; next }
    index($0, k "=") == 1 { print substr($0, length(k) + 2) }'
}

# A secret value must not appear outside '::add-mask::' lines and the token
# output block, nor in argv, nor in the job summary.
no_leaks() {
  local title="$1" value
  for value in "$jwt" "$jwt_called" "$hf_token" "$request_token" stored-token-must-not-be-used; do
    if printf '%s\n' "$log" | awk -v v="$value" '
        /^token<</ { d = substr($0, 8); on = 1; next }
        on && $0 == d { on = 0; next }
        on { next }
        /^::add-mask::/ { next }
        index($0, v) { found = 1 }
        END { exit !found }'; then
      bad "$title: a secret value appears in the log outside an ::add-mask:: line"
      return
    fi
    if grep -q -F -- "$value" "$work/argv" "$work/summary"; then
      bad "$title: a secret value appears in the argv of curl or in the job summary"
      return
    fi
  done
  ok
}

exchange_calls() { grep -c -F -- 'https://huggingface.co/oauth/token' "$work/argv" || true; }

# ── Exchange: success ───────────────────────────────────────────────────────
run_script "$exchange"
first_output="$(printf '%s\n' "$log" | grep -n '^token<<' | head -n 1 | cut -d: -f1)"
last_mask="$(printf '%s\n' "$log" | grep -n '^::add-mask::' | tail -n 1 | cut -d: -f1)"
body="$(head -n 1 "$work/body")"
if [ "$rc" -ne 0 ]; then
  bad "exchange ok: exit $rc"
elif [ "$(output token)" != "$hf_token" ]; then
  bad "exchange ok: output token is not the HF token"
elif ! printf '%s\n' "$log" | grep -qxF -- "::add-mask::$jwt"; then
  bad "exchange ok: no ::add-mask:: for the JWT"
elif ! printf '%s\n' "$log" | grep -qxF -- "::add-mask::$hf_token"; then
  bad "exchange ok: no ::add-mask:: for the HF token"
elif [ -z "$first_output" ] || [ "$last_mask" -ge "$first_output" ]; then
  bad "exchange ok: an ::add-mask:: line comes after the write to GITHUB_OUTPUT"
elif ! [[ "$(output expires-at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  bad "exchange ok: expires-at '$(output expires-at)' is not an ISO time"
elif ! grep -qF -- 'audience=https%3A%2F%2Fhuggingface.co' "$work/argv"; then
  bad "exchange ok: the OIDC request does not ask for audience https://huggingface.co"
elif ! grep -qxF -- "Authorization: bearer $request_token" "$work/headers"; then
  bad "exchange ok: the OIDC request token is not in a header file"
elif [ "$(printf '%s' "$body" | jq -r '.grant_type')" != 'urn:ietf:params:oauth:grant-type:token-exchange' ] \
  || [ "$(printf '%s' "$body" | jq -r '.subject_token_type')" != 'urn:ietf:params:oauth:token-type:id_token' ] \
  || [ "$(printf '%s' "$body" | jq -r '.subject_token')" != "$jwt" ] \
  || [ "$(printf '%s' "$body" | jq -r '.resource')" != ospo-ci-account ] \
  || [ "$(printf '%s' "$body" | jq -r 'keys | length')" != 4 ]; then
  bad "exchange ok: the exchange body is not the RFC 8693 request: $body"
elif ! grep -F -- 'https://huggingface.co/oauth/token' "$work/argv" | grep -qF -- '-X POST --data-binary @-'; then
  bad "exchange ok: the exchange is not a POST with the body from stdin"
elif [ "$(exchange_calls)" != 1 ]; then
  bad "exchange ok: expected 1 exchange request, got $(exchange_calls)"
elif ! printf '%s\n' "$log" | grep -qF -- 'repository=tenstorrent/.github, branch=main, workflow=nightly.yml'; then
  bad "exchange ok: the log does not name the identity values"
else
  ok
fi
no_leaks "exchange ok"

run_script "$exchange" FAKE_EXCHANGE=noexpiry
{ [ "$rc" -eq 0 ] && [ -n "$(output expires-at)" ] && [ "$(output token)" = "$hf_token" ]; } \
  && ok || bad "exchange without expires_in: 60 minutes assumed"

# ── Exchange: failures ──────────────────────────────────────────────────────
# expect <message part> <env...>: exit 1 and an error with the message in mode
# fail; exit 0, a warning and stopped=exchange in mode warn. No token output.
expect() {
  local want="$1"; shift
  run_script "$exchange" MODE=fail "$@"
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$log" | grep -q '^::error title=hf-oidc-token::' \
    || ! printf '%s\n' "$log" | grep -qF -- "$want" || [ -n "$(output token)" ]; then
    bad "[fail] $*: expected exit 1 and an error with '$want' (exit $rc)"
  else ok; fi
  no_leaks "[fail] $*"
  run_script "$exchange" MODE=warn "$@"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$log" | grep -q '^::warning title=hf-oidc-token::' \
    || ! printf '%s\n' "$log" | grep -qF -- "$want" || [ -n "$(output token)" ] \
    || [ "$(output stopped)" != exchange ]; then
    bad "[warn] $*: expected exit 0, a warning with '$want' and stopped=exchange (exit $rc)"
  else ok; fi
}

expect "GitHub did not give an OIDC token (HTTP 403)" FAKE_OIDC=denied
expect "GitHub did not give an OIDC token (HTTP 200)" FAKE_OIDC=empty
expect "GitHub did not give the OIDC token in 3 tries" FAKE_OIDC=timeout
expect "id-token: write" ACTIONS_ID_TOKEN_REQUEST_TOKEN=
expect "no CI/CD identity on that account matches this run" FAKE_EXCHANGE=grant
expect "OSPO adds an identity with: repository=tenstorrent/.github, branch=main, workflow=nightly.yml" FAKE_EXCHANGE=grant
expect "(Request ID: Root=1-abc-123)" FAKE_EXCHANGE=grant
expect "Open an OSPO ticket" FAKE_EXCHANGE=grant
expect "Hugging Face refused the exchange (HTTP 400). Hugging Face said: invalid_request (bad resource)" FAKE_EXCHANGE=request
expect "too many requests" FAKE_EXCHANGE=ratelimit
expect "Hugging Face had an error (HTTP 503)" FAKE_EXCHANGE=e500
expect "did not answer the exchange within 20 seconds" FAKE_EXCHANGE=timeout
expect "could not send the exchange to https://huggingface.co (curl exit 7)" FAKE_EXCHANGE=refused

# invalid_grant: server text cannot inject a workflow command, and one request only.
run_script "$exchange" FAKE_EXCHANGE=grant
if printf '%s\n' "$log" | grep -q '^::error::boom\|::error:: publisher'; then
  bad "grant: server text injects a workflow command"
elif [ "$(exchange_calls)" != 1 ]; then
  bad "grant: expected 1 exchange request (no retry), got $(exchange_calls)"
elif ! grep -qF -- '| workflow | `nightly.yml` |' "$work/summary" || ! grep -qF -- '`ospo-ci-account`' "$work/summary"; then
  bad "grant: the job summary does not list the identity values"
else ok; fi

# A run in a reusable workflow: the message says the identity names the caller.
run_script "$exchange" FAKE_EXCHANGE=grant FAKE_JWT="$jwt_called" GITHUB_REPOSITORY=tenstorrent/tt-metal
printf '%s\n' "$log" | grep -qF -- 'repository=tenstorrent/tt-metal, branch=main, workflow=caller.yml' \
  && printf '%s\n' "$log" | grep -qF -- 'reusable workflow tenstorrent/.github/.github/workflows/hf.yml' \
  && ok || bad "reusable workflow: message must name the caller and the reusable workflow"
no_leaks "reusable workflow"

# Always errors, also in mode warn: the answer is not what the vendor documents.
for c in notoken badtoken; do
  run_script "$exchange" MODE=warn FAKE_EXCHANGE="$c"
  { [ "$rc" -eq 1 ] && [ -z "$(output token)" ]; } && ok || bad "exchange $c: expected exit 1 also in mode warn"
done

# A multi-line token: every line is masked on its own, and no line can be a
# workflow command. The runner ends a line at a carriage return too, and decodes
# '%0A' in command data. A non-string token is not a token. All fail in mode
# warn too.
for c in multiline carriage objtoken; do
  run_script "$exchange" MODE=warn FAKE_EXCHANGE="$c"
  if [ "$rc" -ne 1 ] || [ -n "$(output token)" ]; then
    bad "exchange $c: expected exit 1 and no token output"
  elif printf '%s\n' "$log" | tr '\r' '\n' | grep -q '^::set-env'; then
    bad "exchange $c: server text became a workflow command"
  elif printf '%s\n' "$log" | grep '^::add-mask::' | grep -q '%0A'; then
    bad "exchange $c: a mask line holds an encoded line break"
  elif printf '%s\n' "$log" | grep -v '^::add-mask::' | grep -qF -- "$hf_token"; then
    bad "exchange $c: the token is in the log outside an ::add-mask:: line"
  else ok; fi
done
run_script "$exchange" FAKE_EXCHANGE=multiline
printf '%s\n' "$log" | grep -qxF -- "::add-mask::$hf_token" && ok || bad "multiline: the first line is not masked on its own"

# A caller with SHELLOPTS=xtrace must not get a trace that holds a secret.
run_script "$exchange" SHELLOPTS=xtrace
{ [ "$rc" -eq 0 ] && [ "$(output token)" = "$hf_token" ]; } && ok || bad "xtrace: exchange must still work"
no_leaks "exchange with SHELLOPTS=xtrace"

# No redirect is followed: a redirect would send the Authorization header or the JWT on.
if grep -qE -- '(^| )(-L|--location|--location-trusted)( |$)' "$work/argv"; then
  bad "curl follows redirects"
else ok; fi

# Resource checks again before it sends the JWT.
run_script "$exchange" RESOURCE=acme/model
{ [ "$rc" -eq 1 ] && [ ! -s "$work/argv" ]; } && ok || bad "repository resource: no request may be sent"

# ── Models check ────────────────────────────────────────────────────────────
nl=$'\n'
run_script "$models_sh" HF_ACCESS_TOKEN="$hf_token" MODELS="meta-llama/open-ok${nl}datasets/acme/set-ok"
if [ "$rc" -ne 0 ]; then
  bad "models ok: exit $rc"
elif [ -n "$(output models-without-access)" ]; then
  bad "models ok: models-without-access is not empty"
elif ! grep -qF -- 'https://huggingface.co/api/models/meta-llama/open-ok/auth-check' "$work/argv" \
  || ! grep -qF -- 'https://huggingface.co/api/datasets/acme/set-ok/auth-check' "$work/argv"; then
  bad "models ok: wrong auth-check URLs"
elif [ "$(grep -c -xF -- "Authorization: Bearer $hf_token" "$work/headers")" != 2 ]; then
  bad "models ok: the token is not in a header file for each request"
else ok; fi
no_leaks "models ok"
grep -qE -- '(^| )(-L|--location|--location-trusted)( |$)' "$work/argv" && bad "models: curl follows redirects" || ok

run_script "$models_sh" HF_ACCESS_TOKEN="$hf_token" MODELS="acme/gated-a" SHELLOPTS=xtrace
no_leaks "models with SHELLOPTS=xtrace"

models="acme/gated-a${nl}acme/fine${nl}acme/missing-b${nl}acme/broken-c${nl}acme/offline-d"
want="acme/gated-a,acme/missing-b,acme/broken-c,acme/offline-d"
run_script "$models_sh" HF_ACCESS_TOKEN="$hf_token" MODELS="$models" MODE=fail
if [ "$rc" -ne 1 ]; then
  bad "models denied (fail): expected exit 1, got $rc"
elif [ "$(output models-without-access)" != "$want" ]; then
  bad "models denied (fail): models-without-access is '$(output models-without-access)'"
elif ! printf '%s\n' "$log" | grep -qF -- 'acme/gated-a: gated, no access yet' \
  || ! printf '%s\n' "$log" | grep -qF -- 'acme/missing-b: not found, or private' \
  || ! printf '%s\n' "$log" | grep -qF -- 'acme/broken-c: no access (HTTP 500)' \
  || ! printf '%s\n' "$log" | grep -qF -- 'acme/offline-d: could not check (curl exit 6)' \
  || ! printf '%s\n' "$log" | grep -qF -- 'OK: account ospo-ci-account can read acme/fine.'; then
  bad "models denied (fail): a reason is missing"
elif ! printf '%s\n' "$log" | grep -q '^::error title=hf-oidc-token::account ospo-ci-account cannot read 4 of 5'; then
  bad "models denied (fail): no error annotation"
elif ! grep -qF -- 'to accept the licence' "$work/summary"; then
  bad "models denied (fail): the job summary has no request for OSPO"
else ok; fi
no_leaks "models denied"

run_script "$models_sh" HF_ACCESS_TOKEN="$hf_token" MODELS="$models" MODE=warn
{ [ "$rc" -eq 0 ] && [ "$(output models-without-access)" = "$want" ] && [ "$(output stopped)" = models ] \
  && printf '%s\n' "$log" | grep -q '^::warning title=hf-oidc-token::'; } \
  && ok || bad "models denied (warn): expected exit 0, the list, stopped=models and a warning"

run_script "$models_sh" HF_ACCESS_TOKEN="$hf_token" MODELS='a/b?x=1'
{ [ "$rc" -eq 1 ] && [ ! -s "$work/argv" ]; } && ok || bad "models: a bad name must not reach a URL"

# ── curl reads no config file ───────────────────────────────────────────────
# Every curl call of the scripts above starts with -q (--disable).
if [ "$curl_calls" -eq 0 ]; then
  log="" bad "curl -q: the fake curl saw no call"
elif [ "$noq_calls" -ne 0 ]; then
  log="$noq_first" bad "curl -q: $noq_calls of $curl_calls curl calls do not start with -q (first one in the log)"
else ok; fi

# With a real curl: a .curlrc in HOME that sets trace-ascii must have no
# effect. The request goes to a closed local port; no network.
real_curl="$(PATH="${PATH#"$work/bin:"}" command -v curl || true)"
if [ -n "$real_curl" ]; then
  mkdir -p "$work/home"
  printf 'trace-ascii = "%s"\n' "$work/trace.txt" >"$work/home/.curlrc"
  # The control: without -q, this curl reads the file (proves the test works).
  HOME="$work/home" CURL_HOME="" "$real_curl" -sS --max-time 3 -o /dev/null http://127.0.0.1:9/ 2>/dev/null || true
  if [ ! -e "$work/trace.txt" ]; then
    log="" bad "real curl: the control run did not read ~/.curlrc; the test cannot prove -q"
  else
    rm -f "$work/trace.txt"
    # A curl wrapper that keeps the argv of the scripts (with -q first) but
    # sends every request to a closed local port.
    mkdir -p "$work/bin-real"
    cat >"$work/bin-real/curl" <<REAL
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in http://* | https://*) a=http://127.0.0.1:9/ ;; esac
  args+=("\$a")
done
exec "$real_curl" "\${args[@]}"
REAL
    chmod +x "$work/bin-real/curl"
    for script in "$exchange" "$models_sh"; do
      env -i PATH="$work/bin-real:$PATH" HOME="$work/home" \
        RESOURCE=ospo-ci-account MODE=warn HF_ACCESS_TOKEN="$hf_token" MODELS=acme/x \
        ACTIONS_ID_TOKEN_REQUEST_URL='https://token.invalid/oidc?api-version=2.0' \
GITHUB_REPOSITORY=tenstorrent/.github \
        ACTIONS_ID_TOKEN_REQUEST_TOKEN="$request_token" \
        GITHUB_OUTPUT="$work/real-out" bash "$script" </dev/null >/dev/null 2>&1 || true
    done
    # The wrapper really ran (else the check below proves nothing).
    [ -s "$work/real-out" ] || log="" bad "real curl: the scripts wrote no output"
    if [ -e "$work/trace.txt" ]; then
      log="" bad "real curl: a script read ~/.curlrc (trace file written)"
    else ok; fi
  fi
else
  echo "real curl: not found, test skipped"
fi

echo "exchange-cases: $pass checks passed."
[ "$status" -eq 0 ] || echo "exchange-cases: some checks FAILED."
exit "$status"

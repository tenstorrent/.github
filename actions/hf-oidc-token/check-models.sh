#!/usr/bin/env bash
# shellcheck disable=SC2016 # Backticks are Markdown in the job summary, not commands.
# Checks that the new Hugging Face token can read each repository in MODELS.
# For each one, it asks GET https://huggingface.co/api/<models|datasets>/<repo>/auth-check
# with the token (the same request as huggingface_hub HfApi.auth_check).
#   200                          the account can read it
#   403 X-Error-Code GatedRepo   gated, and the account has no access yet
#                                (licence not accepted, or approval pending)
#   401, 404, RepoNotFound       not found, or private (the token cannot read
#                                private repositories)
#   other                        could not check
#
# Secrets: the Hugging Face token (already masked by exchange.sh). It goes in a
# header from a pipe, never in argv or a file. Do not use 'set -x' here.
# Each request: 15 seconds, up to 3 tries (GET, no side effect).
#
# Reads:  HF_ACCESS_TOKEN MODELS (one per line) MODE RESOURCE GITHUB_OUTPUT
#         GITHUB_STEP_SUMMARY
# Writes: outputs models-without-access (comma-separated), stopped (models,
#         only in warn mode)
set -euo pipefail
set +x # a caller can set SHELLOPTS=xtrace: no trace may print the token

unset HF_TOKEN HUGGING_FACE_HUB_TOKEN

TITLE='hf-oidc-token'
HF_ENDPOINT_URL='https://huggingface.co'

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
resource="${RESOURCE:-?}"
token="${HF_ACCESS_TOKEN:-}"
[ -n "$token" ] || fail "internal error: no token to check the models with."

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

denied=()
details=()
checked=0
while IFS= read -r repo || [ -n "$repo" ]; do
  [ -n "$repo" ] || continue
  # The same pattern as prepare.sh. Never put an unchecked value in a URL.
  if ! [[ "$repo" =~ ^(datasets/)?[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] \
    || [[ "$repo" == *..* ]]; then
    fail "internal error: '$repo' is not a repository name."
  fi
  if [[ "$repo" == datasets/* ]]; then
    path="datasets/${repo#datasets/}"
  else
    path="models/$repo"
  fi
  checked=$((checked + 1))
  rc=0
  code="$(curl -sS --connect-timeout 5 --max-time 15 \
    --retry 2 --retry-delay 2 --retry-max-time 50 \
    -o /dev/null -w '%{http_code}' \
    -D "$work/headers" \
    -H @<(printf 'Authorization: Bearer %s\n' "$token") \
    "$HF_ENDPOINT_URL/api/$path/auth-check")" || rc=$?
  error_code="$(tr -d '\r' <"$work/headers" 2>/dev/null \
    | awk -F': *' 'tolower($1) == "x-error-code" { v = $2 } END { print v }' || true)"
  error_code="$(printf '%s' "$error_code" | tr -cd 'A-Za-z0-9_-')"
  rm -f "$work/headers"
  if [ "$rc" -ne 0 ]; then
    reason="could not check (curl exit $rc)"
  elif [ "$code" = 200 ]; then
    echo "OK: account $resource can read $repo."
    continue
  elif [ "$error_code" = GatedRepo ]; then
    reason="gated, no access yet: accept the licence on the account (or wait for the approval)"
  elif [ "$error_code" = RepoNotFound ] || [ "$code" = 401 ] || [ "$code" = 404 ]; then
    reason="not found, or private (the token cannot read private repositories)"
  else
    reason="no access (HTTP $code${error_code:+, $error_code})"
  fi
  echo "NO ACCESS: $repo: $reason."
  denied+=("$repo")
  details+=("$repo: $reason")
done <<<"${MODELS:-}"
token=""

list=""
for r in "${denied[@]+"${denied[@]}"}"; do list="${list:+$list,}$r"; done
printf 'models-without-access=%s\n' "$list" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

if [ "${#denied[@]}" -eq 0 ]; then
  echo "The token can read all $checked repositories in input models."
  exit 0
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Hugging Face account `%s` cannot read %d of %d repositories\n\n' "$resource" "${#denied[@]}" "$checked"
    for d in "${details[@]}"; do printf -- '- `%s`\n' "$d"; done
    printf '\nAsk OSPO on your ticket (or open one) to accept the licence of these repositories on the account `%s`.\n' "$resource"
  } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

msg="account $resource cannot read ${#denied[@]} of $checked repositories: $list. Ask OSPO on your ticket (or open an OSPO ticket) to accept the licence of these repositories on account $resource. Details are in the log and the job summary."
if [ "$mode" = warn ]; then
  printf '::warning title=%s::%s\n' "$TITLE" "$(escape "$msg The job continues; the token can read only the other repositories (if-no-token: warn).")"
  printf 'stopped=models\n' >>"$GITHUB_OUTPUT"
  exit 0
fi
fail "$msg"

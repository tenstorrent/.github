#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # ok never fails; backticks are Markdown text.
# Test helper for .github/workflows/hf-oidc-token-test.yml. Not used by the action.
# Runs prepare.sh directly, without the network. Checks:
#   - each bad input fails with its own message, also with if-no-token warn;
#   - the tripwires (pull_request_target, workflow_run, a branch or resource
#     that starts with '-' or holds a line break) always fail, with their own
#     annotation, and never show the value;
#   - other refusals (event, also push, branch, unprotected branch, no
#     resource, no id-token) fail with
#     if-no-token fail, and warn and succeed (go=false, stopped=prepare) with warn;
#   - the models list: newline and comma forms, blanks, duplicates, datasets;
#   - a valid run gives go=true and the outputs.
# Uses no token.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare="$here/../prepare.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
pass=0
nl=$'\n'

# Runs prepare.sh with valid values. Each argument (NAME=value) replaces one.
run() {
  : >"$work/out"
  rc=0
  env -i PATH="$PATH" \
    ACTIONS_ID_TOKEN_REQUEST_URL=https://test.actions.githubusercontent.com/not-used \
    GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_REF_PROTECTED=true \
    GITHUB_REPOSITORY=tenstorrent/.github \
    GITHUB_WORKFLOW_REF=tenstorrent/.github/.github/workflows/test.yml@refs/heads/main \
    IN_RESOURCE=ospo-ci-account \
    IN_MODELS= \
    IN_IF_NO_TOKEN=fail \
    IN_BRANCH=main \
    GITHUB_OUTPUT="$work/out" \
    "$@" \
    bash "$prepare" >"$work/log" 2>&1 || rc=$?
}

output() {
  awk -v k="$1" '
    index($0, k "<<") == 1 { d = substr($0, length(k) + 3); on = 1; next }
    on && $0 == d { on = 0; next }
    on { print; next }
    index($0, k "=") == 1 { print substr($0, length(k) + 2) }
  ' "$work/out"
}

ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; sed 's/^/  | /' "$work/log"; status=1; }

# expect_fail <message part> <env...>: fails in both modes with the message.
expect_fail() {
  local want="$1"; shift
  for m in fail warn; do
    run IN_IF_NO_TOKEN="$m" "$@"
    if [ "$rc" -ne 1 ]; then bad "[$m] $* : expected exit 1, got $rc"; continue; fi
    grep -q '^::error title=hf-oidc-token::' "$work/log" || { bad "[$m] $*: no error annotation"; continue; }
    grep -qF -- "$want" "$work/log" || { bad "[$m] $*: message lacks '$want'"; continue; }
    [ "$(output go)" != true ] || { bad "[$m] $*: go=true after a failure"; continue; }
    ok
  done
}

# expect_trip <message start> <env...>: fails in both modes with exactly one
# line, the tripwire annotation. A value with CANARY must not be in the log.
expect_trip() {
  local want="$1"; shift
  for m in fail warn; do
    run IN_IF_NO_TOKEN="$m" "$@"
    if [ "$rc" -ne 1 ]; then bad "[$m] tripwire $want: expected exit 1, got $rc"; continue; fi
    [ "$(wc -l <"$work/log" | tr -d ' ')" -eq 1 ] || { bad "[$m] tripwire $want: expected one line"; continue; }
    grep -q -x -F -- "::error title=hf-oidc-token: input not supported::$want. No token was requested." "$work/log" \
      || { bad "[$m] tripwire $want: annotation is not as expected"; continue; }
    ! grep -q CANARY "$work/log" || { bad "[$m] tripwire $want: the annotation shows the value"; continue; }
    [ ! -s "$work/out" ] || { bad "[$m] tripwire $want: outputs after a tripwire"; continue; }
    ok
  done
}

# expect_stop <message part> <env...>: fails in mode fail, warns in mode warn.
expect_stop() {
  local want="$1"; shift
  run IN_IF_NO_TOKEN=fail "$@"
  if [ "$rc" -ne 1 ] || ! grep -qF -- "$want" "$work/log" || ! grep -q '^::error ' "$work/log"; then
    bad "[fail] $*: expected an error with '$want' (exit $rc)"
  else ok; fi
  run IN_IF_NO_TOKEN=warn "$@"
  if [ "$rc" -ne 0 ] || ! grep -q '^::warning title=hf-oidc-token::' "$work/log" \
    || ! grep -qF -- "$want" "$work/log" || grep -q '^::error ' "$work/log"; then
    bad "[warn] $*: expected a warning with '$want' and exit 0 (exit $rc)"
  elif [ "$(output go)" != false ] || [ "$(output stopped)" != prepare ]; then
    bad "[warn] $*: expected go=false and stopped=prepare"
  else ok; fi
}

# ── Bad inputs ───────────────────────────────────────────────────────────────
run IN_IF_NO_TOKEN=maybe
{ [ "$rc" -eq 1 ] && grep -qF 'if-no-token must be fail or warn' "$work/log"; } && ok || bad "if-no-token=maybe"
expect_fail "has a '/'" IN_RESOURCE=acme/model
expect_fail "not a valid Hugging Face user name" 'IN_RESOURCE=bad name'
expect_fail "not a valid Hugging Face user name" 'IN_RESOURCE=x;y'
expect_fail "not a Hugging Face repository name" IN_MODELS=no-slash
expect_fail "not a Hugging Face repository name" 'IN_MODELS=a/b/c'
expect_fail "not a Hugging Face repository name" 'IN_MODELS=a/../b'
expect_fail "not a Hugging Face repository name" 'IN_MODELS=a/b?x=1'
expect_fail "not a Hugging Face repository name" 'IN_MODELS=spaces/a/b'
expect_fail "not a valid branch name" 'IN_BRANCH=refs/heads/../x'
expect_fail "not a valid branch name" 'IN_BRANCH=a b'
expect_fail "more than 50" "IN_MODELS=$(for i in $(seq 1 51); do printf 'o/m%s,' "$i"; done)"

# ── Tripwires: always fail ───────────────────────────────────────────────────
outside="where code from outside the repository can reach the job's secrets"
expect_trip "the workflow runs on pull_request_target, $outside" GITHUB_EVENT_NAME=pull_request_target
expect_trip "the workflow runs on workflow_run, $outside" GITHUB_EVENT_NAME=workflow_run
# Before every other check: no resource, wrong branch, no id-token.
expect_trip "the workflow runs on pull_request_target, $outside" GITHUB_EVENT_NAME=pull_request_target \
  IN_RESOURCE= GITHUB_REF=refs/heads/feature ACTIONS_ID_TOKEN_REQUEST_URL=
option="starts with '-' and would be read as a command-line option"
line="contains a line break or control character and could inject a line or a command"
expect_trip "resource $option" IN_RESOURCE=-CANARY
expect_trip "BASH_ENV is set, so every bash script of the job first runs the file it names" BASH_ENV=/nonexistent/CANARY
expect_trip "an exported shell function can replace a command in every bash script of the job" 'BASH_FUNC_jq%%=() { echo CANARY; }'
expect_trip "an exported shell function can replace a command in every bash script of the job" 'BASH_FUNC_module%%=() { echo CANARY; }'
# Functions named like the commands that could start the check itself, or stop
# the script after it: the check still runs, and the script still stops.
expect_trip "an exported shell function can replace a command in every bash script of the job" \
  'BASH_FUNC_env%%=() { return 0; }' 'BASH_FUNC_python3%%=() { return 0; }' 'BASH_FUNC_exec%%=() { return 0; }' \
  'BASH_FUNC_unset%%=() { return 0; }' 'BASH_FUNC_export%%=() { return 0; }' 'BASH_FUNC_exit%%=() { return 0; }' \
  'BASH_FUNC_dirname%%=() { return 0; }' 'BASH_FUNC_pwd%%=() { return 0; }' 'BASH_FUNC_cd%%=() { return 0; }'
# PATH: an entry that means the current directory, and a curl that a pull
# request could have placed. The same curl outside the workspace passes.
expect_trip "PATH has an empty or relative entry, so commands are looked up in the current directory" "PATH=$PATH:"
mkdir -p "$work/ws/bin"
printf '#!/bin/sh\necho CANARY\n' >"$work/ws/bin/curl"
chmod +x "$work/ws/bin/curl"
expect_trip "the first curl on PATH is inside the workspace, where a pull request can place it" \
  GITHUB_WORKSPACE="$work/ws" PATH="$work/ws/bin:$PATH"
run GITHUB_WORKSPACE="$work/elsewhere" PATH="$work/ws/bin:$PATH"
grep -q ': input not supported::' "$work/log" && bad "a curl outside the workspace must pass the tripwire" || ok
# A python3 that a pull request placed in the workspace, first on PATH, must
# not stand in for the checks: it never runs, and the real checks still fire.
# The same for another spelling of the workspace (a link to it).
mkdir -p "$work/pr/bin"
printf '#!/bin/sh\necho ran >>"%s"\nexit 0\n' "$work/fake-python-ran" >"$work/pr/bin/python3"
chmod +x "$work/pr/bin/python3"
ln -s "$work/pr" "$work/pr-link"
for spelled in "$work/pr/bin" "$work/pr-link/bin"; do
  expect_trip "resource $option" IN_RESOURCE=-CANARY GITHUB_WORKSPACE="$work/pr" PATH="$spelled:$PATH"
done
[ ! -e "$work/fake-python-ran" ] && ok || bad "a python3 from the workspace ran in place of the checks"
# Without Python the checks cannot run: the pinned title, in both modes.
mkdir -p "$work/no-python-bin"
ln -s "$(command -v bash)" "$work/no-python-bin/bash"
for mode in fail warn; do
  run IN_IF_NO_TOKEN="$mode" PATH="$work/no-python-bin"
  if [ "$rc" -ne 1 ] || ! grep -q -x -F -- '::error title=hf-oidc-token: checks could not run::There is no Python on PATH. The checks need Python 3.9 or newer on PATH, outside the workspace.' "$work/log"; then
    bad "[$mode] runner without python3: expected the annotation 'hf-oidc-token: checks could not run' (exit $rc)"
  else ok; fi
done
expect_trip "GIT_TRACE_REDACT is off, so Git traces print credentials" GIT_TRACE_REDACT=false
# A bash that a pull request placed in the workspace, first on PATH. This one
# hands over to the real bash, so the check runs and reports it.
mkdir -p "$work/shell/bin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v bash)" >"$work/shell/bin/bash"
chmod +x "$work/shell/bin/bash"
expect_trip "the first bash on PATH is inside the workspace, where a pull request can place it" \
  GITHUB_WORKSPACE="$work/shell" PATH="$work/shell/bin:$PATH"
# Certificates that a pull request placed in the workspace: with a proxy
# variable they would let another server read the requests of the action.
# The runner's own certificates (here: outside the workspace) pass.
for name in CURL_CA_BUNDLE SSL_CERT_FILE; do
  expect_trip "$name names certificates inside the workspace, where a pull request can place them, so a request that carries a secret would trust any server" \
    GITHUB_WORKSPACE="$work/pr" "$name=$work/pr/CANARY.pem" HTTPS_PROXY=http://CANARY.invalid:3128
done
run GITHUB_WORKSPACE="$work/pr" CURL_CA_BUNDLE="$work/runner-ca.pem" SSL_CERT_FILE=/etc/ssl/cert.pem HTTPS_PROXY=http://proxy.invalid:3128
{ [ "$rc" -eq 0 ] && [ "$(output go)" = true ]; } && ok || bad "certificates outside the workspace must pass"
expect_trip "ACTIONS_ID_TOKEN_REQUEST_URL is not a GitHub OIDC endpoint and would have received the OIDC request token" \
  ACTIONS_ID_TOKEN_REQUEST_URL=https://CANARY.invalid/oidc
expect_trip "resource $option" 'IN_RESOURCE=  --CANARY'
expect_trip "resource $line" "IN_RESOURCE=x${nl}CANARY"
expect_trip "branch $option" IN_BRANCH=--CANARY
expect_trip "branch $line" "IN_BRANCH=main${nl}CANARY"

# ── Refusals that depend on if-no-token ──────────────────────────────────────
expect_stop "only for the events schedule and workflow_dispatch" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge
expect_stop "only for the events" GITHUB_EVENT_NAME=issue_comment
# push on the allowed branch: not an allowed event (owner decision).
expect_stop "only for the events schedule and workflow_dispatch. This run: push." GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main
expect_stop "only on branch main" GITHUB_REF=refs/heads/feature
expect_stop "only on branch main" GITHUB_REF=refs/tags/v1
expect_stop "only on branch release" IN_BRANCH=release
expect_stop "input resource is empty" IN_RESOURCE=
expect_stop "input resource is empty" 'IN_RESOURCE=   '
expect_stop "id-token: write" ACTIONS_ID_TOKEN_REQUEST_URL=
# Unprotected branch: a stop (owner decision). Empty or missing counts as not
# protected. The branch check comes first: a wrong branch gives its own message.
expect_stop "branch main has no branch protection or ruleset (GITHUB_REF_PROTECTED is 'false')" GITHUB_REF_PROTECTED=false
expect_stop "branch main has no branch protection or ruleset (GITHUB_REF_PROTECTED is '')" GITHUB_REF_PROTECTED=
expect_stop "must name a protected branch" GITHUB_REF_PROTECTED=TRUE
expect_stop "only on branch main" GITHUB_REF=refs/heads/feature GITHUB_REF_PROTECTED=false

# ── Valid runs ───────────────────────────────────────────────────────────────
for ev in schedule workflow_dispatch; do
  run GITHUB_EVENT_NAME="$ev"
  { [ "$rc" -eq 0 ] && [ "$(output go)" = true ] && [ "$(output resource)" = ospo-ci-account ] \
    && [ "$(output mode)" = fail ]; } && ok || bad "valid run with event $ev"
done

run IN_IF_NO_TOKEN=warn IN_RESOURCE=' Ospo_CI.account-2 '
{ [ "$rc" -eq 0 ] && [ "$(output resource)" = Ospo_CI.account-2 ] && [ "$(output mode)" = warn ]; } \
  && ok || bad "resource is trimmed, mode warn"

run IN_BRANCH=release/1.2 GITHUB_REF=refs/heads/release/1.2
[ "$rc" -eq 0 ] && ok || bad "branch with '/'"

run IN_BRANCH=
[ "$rc" -eq 0 ] && ok || bad "empty branch means main"

run "IN_MODELS=meta-llama/Llama-3.1-8B-Instruct${nl}  google/gemma-2b , datasets/acme/gated_set${nl}${nl}meta-llama/Llama-3.1-8B-Instruct"
want="meta-llama/Llama-3.1-8B-Instruct${nl}google/gemma-2b${nl}datasets/acme/gated_set"
{ [ "$rc" -eq 0 ] && [ "$(output models)" = "$want" ]; } && ok || bad "models list: got '$(output models)'"

run IN_MODELS=
{ [ "$rc" -eq 0 ] && [ -z "$(output models)" ]; } && ok || bad "empty models"


echo "prepare-cases: $pass checks passed."
[ "$status" -eq 0 ] || echo "prepare-cases: some checks FAILED."
exit "$status"

#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # ok never fails; backticks are Markdown text.
# Test helper for .github/workflows/hf-oidc-token-test.yml. Not used by the action.
# Runs prepare.sh directly, without the network. Checks:
#   - each bad input fails with its own message, also with if-no-token warn;
#   - pull_request_target and workflow_run always fail;
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
    ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/not-used \
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
expect_fail "not a valid Hugging Face user name" 'IN_RESOURCE=-start'
expect_fail "not a valid Hugging Face user name" 'IN_RESOURCE=x;y'
expect_fail "not a Hugging Face repository name" IN_MODELS=no-slash
expect_fail "not a Hugging Face repository name" 'IN_MODELS=a/b/c'
expect_fail "not a Hugging Face repository name" 'IN_MODELS=a/../b'
expect_fail "not a Hugging Face repository name" 'IN_MODELS=a/b?x=1'
expect_fail "not a Hugging Face repository name" 'IN_MODELS=spaces/a/b'
expect_fail "not a valid branch name" 'IN_BRANCH=refs/heads/../x'
expect_fail "not a valid branch name" 'IN_BRANCH=a b'
expect_fail "more than 50" "IN_MODELS=$(for i in $(seq 1 51); do printf 'o/m%s,' "$i"; done)"

# ── Events that always fail ──────────────────────────────────────────────────
expect_fail "refused on pull_request_target" GITHUB_EVENT_NAME=pull_request_target
expect_fail "refused on workflow_run" GITHUB_EVENT_NAME=workflow_run

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

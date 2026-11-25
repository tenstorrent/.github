#!/usr/bin/env bash
# Pre-checks for the hf-oidc-token action. No network call. Stops early with a
# plain message.
# Every input arrives through env (never through ${{ }} in shell text).
#
# Two kinds of stop:
#   fail  An input has a bad value, or the run uses an event that must never
#         get a token (pull_request_target, workflow_run). Always an error.
#   stop  This run cannot get a token (no resource, wrong branch, branch not
#         protected, event not allowed, no id-token: write). Error when if-no-token is `fail`;
#         warning and success when it is `warn` (output stopped=prepare).
#
# Reads:  IN_RESOURCE IN_MODELS IN_IF_NO_TOKEN IN_BRANCH
#         GITHUB_EVENT_NAME GITHUB_REF GITHUB_REPOSITORY GITHUB_WORKFLOW_REF
#         GITHUB_REF_PROTECTED ACTIONS_ID_TOKEN_REQUEST_URL GITHUB_OUTPUT
# Writes: outputs go (true/false), resource, mode, models (list, one per
#         line), stopped (prepare, only in warn mode)
set -euo pipefail

TITLE='hf-oidc-token'
MAX_MODELS=50

# Escapes the characters that end or change a workflow command.
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

mode="${IN_IF_NO_TOKEN:-fail}"
case "$mode" in
  fail | warn) ;;
  *) fail "input if-no-token must be fail or warn." ;;
esac

# No token for this run. The message names the cause and what to do.
stop() {
  if [ "$mode" = warn ]; then
    printf '::warning title=%s::%s\n' "$TITLE" "$(escape "$1 The job continues without a Hugging Face token (if-no-token: warn).")"
    {
      printf 'go=false\n'
      printf 'stopped=prepare\n'
    } >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
    exit 0
  fi
  fail "$1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ── Inputs: check every value before use ───────────────────────────────────
branch="$(trim "${IN_BRANCH:-main}")"
[ -n "$branch" ] || branch=main
# A git branch name, with the common characters only.
if ! [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$branch" == [-./]* ]] || [[ "$branch" == */ ]] \
  || [[ "$branch" == *..* ]] || [ "${#branch}" -gt 200 ]; then
  fail "input branch is not a valid branch name. Use the branch name without refs/heads/, for example main."
fi

resource="$(trim "${IN_RESOURCE:-}")"
if [ -n "$resource" ]; then
  # A repository resource gives a token that can WRITE to that repository.
  # This action gives read-only tokens only, so a resource is a user name.
  if [[ "$resource" == */* ]]; then
    fail "input resource '$resource' has a '/'. It must be the name of the Hugging Face service account (a user name), not a repository. Pass vars.HF_OIDC_RESOURCE."
  fi
  if ! [[ "$resource" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,94}[A-Za-z0-9])?$ ]]; then
    fail "input resource is not a valid Hugging Face user name. Allowed: letters, digits, '.', '_', '-'. Pass vars.HF_OIDC_RESOURCE."
  fi
fi

# models: one repository per line or per comma. A model is <owner>/<name>;
# a dataset is datasets/<owner>/<name>.
models=()
raw="${IN_MODELS:-}"
raw="${raw//,/$'\n'}"
while IFS= read -r line || [ -n "$line" ]; do
  line="$(trim "$line")"
  [ -n "$line" ] || continue
  if ! [[ "$line" =~ ^(datasets/)?[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] \
    || [[ "$line" == *..* ]]; then
    fail "input models: '$line' is not a Hugging Face repository name. Use <owner>/<name> for a model or datasets/<owner>/<name> for a dataset, one per line or separated by commas."
  fi
  dup=false
  for m in "${models[@]+"${models[@]}"}"; do [ "$m" != "$line" ] || dup=true; done
  [ "$dup" = true ] || models+=("$line")
done <<<"$raw"
[ "${#models[@]}" -le "$MAX_MODELS" ] || fail "input models has more than $MAX_MODELS repositories."

# ── Tools ──────────────────────────────────────────────────────────────────
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "this runner has no $tool; the action needs bash, curl and jq."
done

# ── The run ────────────────────────────────────────────────────────────────
event="${GITHUB_EVENT_NAME:-}"
ref="${GITHUB_REF:-}"
workflow_ref="${GITHUB_WORKFLOW_REF:-}"
workflow_file="${workflow_ref%@*}"
workflow_file="${workflow_file##*/}"

# These events run on the default branch, with the workflow file of the default
# branch, so they can match the CI/CD identity. But code or data from outside
# (a pull request, another workflow run) controls them. Never a token.
case "$event" in
  pull_request_target | workflow_run)
    fail "refused on $event: this event runs on the default branch but can be started by code from outside, for example a pull request from a fork. Hugging Face cannot tell this run from a trusted run. Use schedule or workflow_dispatch."
    ;;
esac

case "$event" in
  schedule | workflow_dispatch) ;;
  *) stop "the action gives a token only for the events schedule and workflow_dispatch. This run: $event." ;;
esac

if [ "$ref" != "refs/heads/$branch" ]; then
  stop "the action gives a token only on branch $branch (input branch). This run: ${ref:-unknown ref}."
fi

# GitHub sets GITHUB_REF_PROTECTED to true when branch protection or a ruleset
# applies to the ref. Empty or missing counts as not protected. On an
# unprotected branch, anyone who can push to it can change this workflow and
# use the Hugging Face identity.
if [ "${GITHUB_REF_PROTECTED:-}" != true ]; then
  stop "branch $branch has no branch protection or ruleset (GITHUB_REF_PROTECTED is '${GITHUB_REF_PROTECTED:-}'). The Hugging Face identity must name a protected branch: anyone who can push to an unprotected branch can change this workflow and use the identity. Run the workflow on a protected branch (normally main), or ask the repository admins to protect branch $branch."
fi

if [ -z "$resource" ]; then
  stop "input resource is empty. Pass resource: \${{ vars.HF_OIDC_RESOURCE }}. If the repository has no variable HF_OIDC_RESOURCE, OSPO has not set up Hugging Face access for it yet: open an OSPO ticket."
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  stop "the job has no OIDC token. Add 'permissions: id-token: write' to this job (job level, not workflow level)."
fi

delimiter="hf_oidc_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
{
  printf 'go=true\n'
  printf 'resource=%s\n' "$resource"
  printf 'mode=%s\n' "$mode"
  printf 'models<<%s\n' "$delimiter"
  for m in "${models[@]+"${models[@]}"}"; do printf '%s\n' "$m"; done
  printf '%s\n' "$delimiter"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

echo "Checks passed: event $event, branch $branch, workflow ${workflow_file:-?}, account $resource, ${#models[@]} model(s) to check."

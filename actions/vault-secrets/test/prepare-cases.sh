#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs prepare.sh directly, without Vault or the network. Checks that each
# pre-check refuses its case with its own message, and checks the reserved
# output name rule: prepare.sh accepts a `secrets` value that only contains the
# reserved name, and refuses a value that uses it as an output name. Checks
# the role resolution (default, short and full names, role-from) and its refusals, and
# the github-token resolution (key, full name, full path) and its refusals.
# Uses no token and no secret.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare="$here/../prepare.sh"
work="$(mktemp -d)"
listener_pid=""
# shellcheck disable=SC2329 # Called by the EXIT trap.
cleanup() {
  [ -z "$listener_pid" ] || kill "$listener_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

status=0
nl=$'\n'

# Runs prepare.sh with valid inputs. Each argument (NAME=value) replaces one
# of them; NAME= gives an empty value, which prepare.sh treats as not set.
# Sets rc and spec (the spec output, empty if prepare.sh failed).
run_env() {
  local out="$work/out" log="$work/log"
  : >"$out"
  rc=0
  env -i PATH="$PATH" \
    ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/not-used \
    EVENT_NAME=workflow_dispatch \
    REPOSITORY=tenstorrent/.github \
    IN_ROLE=test-role \
    IN_SECRETS= \
    IN_GITHUB_TOKEN=test-token \
    IN_VAULT_URL= \
    IN_JOIN_TAILNET=false \
    IN_TS_CLIENT_ID=test-client \
    IN_TS_AUDIENCE=test-audience \
    IN_TS_TAGS=tag:test \
    IN_VAULT_TIMEOUT= \
    GITHUB_OUTPUT="$out" \
    "$@" \
    bash "$prepare" >"$log" 2>&1 || rc=$?
  spec="$(awk '
    /^spec<</ { d = substr($0, 7); on = 1; next }
    on && $0 == d { on = 0; next }
    on { print }
  ' "$out")"
}

# Runs prepare.sh with IN_SECRETS=$1 and IN_GITHUB_TOKEN=$2.
run_prepare() {
  run_env IN_SECRETS="$1" IN_GITHUB_TOKEN="$2"
}

# Fails unless prepare.sh, with the replaced inputs $3..., fails with one
# '::error' line that contains the text $2.
refuses_with() {
  local title="$1" want="$2"
  shift 2
  run_env "$@"
  if [ "$rc" -eq 0 ]; then
    echo "::error::$title: prepare.sh accepted it, expected a refusal"
    status=1
  elif ! grep -F -- '::error title=vault-secrets::' "$work/log" | grep -q -F -- "$want"; then
    echo "::error::$title: prepare.sh failed, but not with the message '$want'"
    cat "$work/log"
    status=1
  elif [ -s "$work/out" ]; then
    echo "::error::$title: prepare.sh wrote outputs before it failed"
    status=1
  else
    echo "OK: refused: $title"
  fi
}

accepts() {
  local title="$1" secrets="$2" token="$3" want="$4"
  run_prepare "$secrets" "$token"
  if [ "$rc" -ne 0 ]; then
    echo "::error::$title: prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif [ "$spec" != "$want" ]; then
    echo "::error::$title: spec output is not as expected"
    printf 'got:\n%s\nwant:\n%s\n' "$spec" "$want"
    status=1
  else
    echo "OK: accepted: $title"
  fi
}

refuses() {
  local title="$1" secrets="$2"
  refuses_with "$title" 'which this action keeps for github-token' \
    IN_SECRETS="$secrets" IN_GITHUB_TOKEN=test-token
}

# A github-token with '/' goes to vault-action in the spec. A github-token
# without '/' goes to output token-set (read-token.sh), not to the spec.
path_token='github/token/test-token'
token_line="$path_token token | VAULT_SECRETS_GITHUB_TOKEN"

# One case for each pre-check, in the order of prepare.sh.
refuses_with 'pull_request_target' 'refused on pull_request_target' \
  EVENT_NAME=pull_request_target
refuses_with 'no OIDC token' 'job needs permissions: id-token: write' \
  ACTIONS_ID_TOKEN_REQUEST_URL=
refuses_with 'empty REPOSITORY' 'github.repository is empty' REPOSITORY=
refuses_with 'REPOSITORY without owner' "github.repository '.github' is not in the form" \
  REPOSITORY=.github
chars='input role has characters that a Vault role name cannot have'
refuses_with 'role with a space' "$chars" 'IN_ROLE=test role'
refuses_with 'role with a /' "$chars" IN_ROLE=test/role
refuses_with 'role with a ;' "$chars" 'IN_ROLE=x;y'
refuses_with 'role that starts with -' "$chars" IN_ROLE=-x
refuses_with 'role that starts with .' "$chars" IN_ROLE=.x
refuses_with 'role of another repository' \
  "input role 'tenstorrent--other--x' is not a role of tenstorrent/.github" \
  IN_ROLE=tenstorrent--other--x
refuses_with 'role with -- but without the prefix' \
  "input role 'a--b' is not a role of tenstorrent/.github" IN_ROLE=a--b
refuses_with 'full role with an empty name' 'does not give a valid Vault role name' \
  IN_ROLE=tenstorrent--.github--
refuses_with 'short role that ends with -' 'does not give a valid Vault role name' \
  IN_ROLE=x-
refuses_with 'nothing to get' 'nothing to get' IN_GITHUB_TOKEN= IN_SECRETS=
refuses_with 'nothing to get, secrets only blanks and ;' 'nothing to get' \
  IN_GITHUB_TOKEN= "IN_SECRETS= ;${nl} ;"
refuses_with 'token name with ;' 'input github-token is not a valid token name or path' \
  'IN_GITHUB_TOKEN=bad;name'
refuses_with 'token path with //' 'input github-token is not a valid token name or path' \
  IN_GITHUB_TOKEN=github//token
refuses_with 'token key with a space' 'input github-token is not a valid token name or path' \
  'IN_GITHUB_TOKEN=contents read'
refuses_with 'token key that starts with -' 'input github-token is not a valid token name or path' \
  IN_GITHUB_TOKEN=-x
refuses_with 'token key that starts with .' 'input github-token is not a valid token name or path' \
  IN_GITHUB_TOKEN=.x
refuses_with 'token key with a quote' 'input github-token is not a valid token name or path' \
  "IN_GITHUB_TOKEN=x'y"
refuses_with 'token of another repository' \
  "input github-token 'tenstorrent--other--contents-read' is not a token of tenstorrent/.github. Its token names start with tenstorrent--.github--." \
  IN_GITHUB_TOKEN=tenstorrent--other--contents-read
refuses_with 'token of another org' \
  "input github-token 'other--.github--contents-read' is not a token of tenstorrent/.github" \
  IN_GITHUB_TOKEN=other--.github--contents-read
refuses_with 'token with -- but without the prefix' \
  "input github-token 'a--b' is not a token of tenstorrent/.github" IN_GITHUB_TOKEN=a--b
refuses_with 'token name that is only the prefix' \
  "input github-token 'tenstorrent--.github' is not a token of tenstorrent/.github" \
  IN_GITHUB_TOKEN=tenstorrent--.github
refuses_with 'full token name with an empty key' 'does not give a valid token name (tenstorrent--.github--)' \
  IN_GITHUB_TOKEN=tenstorrent--.github--
refuses_with 'token key that ends with -' 'does not give a valid token name (tenstorrent--.github--x-)' \
  IN_GITHUB_TOKEN=x-
refuses_with 'nothing to get, github-token only blanks' 'nothing to get' \
  'IN_GITHUB_TOKEN=   ' IN_SECRETS=
for url in \
  http://vault-ospo.eng-svc.aws.tenstorrent.com \
  https://vault-ospo.invalid \
  https://vault-ospo.eng-svc.aws.tenstorrent.com.invalid \
  https://vault-ospo.eng-svc.aws.tenstorrent.com/v1 \
  https://vault-ospo.eng-svc.aws.tenstorrent.com:8200 \
  https://user@vault-ospo.eng-svc.aws.tenstorrent.com; do
  refuses_with "vault-url $url" 'input vault-url is not an OSPO Vault URL' IN_VAULT_URL="$url"
done
for t in abc 0 9 601 -1 12.5 ' 60' 0060 99999; do
  refuses_with "vault-timeout-seconds '$t'" 'input vault-timeout-seconds must be a whole number from 10 to 600' \
    IN_VAULT_TIMEOUT="$t"
done
refuses_with 'join-tailnet maybe' 'input join-tailnet must be auto, true or false' \
  IN_JOIN_TAILNET=maybe
refuses_with 'join without client id' 'input tailscale-client-id is empty' \
  IN_JOIN_TAILNET=true IN_TS_CLIENT_ID=
refuses_with 'join without audience' 'input tailscale-audience is empty' \
  IN_JOIN_TAILNET=true IN_TS_AUDIENCE=
refuses_with 'join without tags' 'input tailscale-tags is empty' \
  IN_JOIN_TAILNET=true IN_TS_TAGS=

# The valid inputs above pass, so each refusal comes from its own check.
accepts 'valid inputs' '' test-token ''
accepts 'valid inputs, token path' '' "$path_token" "$token_line"

accepts 'reserved name inside a path' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN_backup value | API_KEY' "$path_token" \
  "kv/data/VAULT_SECRETS_GITHUB_TOKEN_backup value | API_KEY ;${nl}${token_line}"
accepts 'reserved name inside a path, no github-token' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN/x value | API_KEY ;' '' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN/x value | API_KEY'
accepts 'output name that only starts with the reserved name' \
  "kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN_2 ;${nl}kv/data/app other | B" "$path_token" \
  "kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN_2 ;${nl}kv/data/app other | B ;${nl}${token_line}"
accepts 'default name with a dash is not the reserved name' \
  'kv/data/app VAULT-SECRETS_GITHUB_TOKEN' "$path_token" \
  "kv/data/app VAULT-SECRETS_GITHUB_TOKEN ;${nl}${token_line}"

# Fails unless prepare.sh, in repository $2 with IN_ROLE=$3, writes role=$4
# and role-source=$5.
role_is() {
  local title="$1" repo="$2" in="$3" want_role="$4" want_source="$5"
  run_env REPOSITORY="$repo" IN_ROLE="$in"
  if [ "$rc" -ne 0 ]; then
    echo "::error::role $title: prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif ! grep -q -x -F -- "role=$want_role" "$work/out" \
    || ! grep -q -x -F -- "role-source=$want_source" "$work/out"; then
    echo "::error::role $title: expected role=$want_role role-source=$want_source"
    grep -E '^(role|role-source|prefix)=' "$work/out" || true
    status=1
  else
    echo "OK: role $title gives $want_role ($want_source)"
  fi
}
role_is 'empty' tenstorrent/.member-history '' tenstorrent--.member-history default
role_is 'only blanks' tenstorrent/.member-history '  ' tenstorrent--.member-history default
role_is 'short name' tenstorrent/.member-history nightly tenstorrent--.member-history--nightly short
role_is 'short name with blanks' tenstorrent/.member-history ' saml ' tenstorrent--.member-history--saml short
role_is 'short name in upper case' tenstorrent/.github Vault-Action-Test tenstorrent--.github--vault-action-test short
role_is 'index form' tenstorrent/.github 2 tenstorrent--.github--2 short
role_is 'full name' tenstorrent/.github tenstorrent--.github--vault-action-test \
  tenstorrent--.github--vault-action-test full
role_is 'full default name' tenstorrent/.github tenstorrent--.github tenstorrent--.github full
role_is 'full name in mixed case' tenstorrent/.github Tenstorrent--.GitHub--X tenstorrent--.github--x full
role_is 'repository in upper case' tenstorrent/LLM_Perf '' tenstorrent--llm_perf default

# role-from (release 1.2). Fails unless prepare.sh, in repository $2 with
# IN_ROLE_FROM=workflow-file, IN_ROLE empty and GITHUB_WORKFLOW_REF=$3, writes
# role=$4 and role-source=workflow-file.
wf_role_is() {
  local title="$1" repo="$2" ref="$3" want_role="$4"
  run_env REPOSITORY="$repo" IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="$ref"
  if [ "$rc" -ne 0 ]; then
    echo "::error::role-from $title: prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif ! grep -q -x -F -- "role=$want_role" "$work/out" \
    || ! grep -q -x -F -- "role-source=workflow-file" "$work/out"; then
    echo "::error::role-from $title: expected role=$want_role role-source=workflow-file"
    grep -E '^(role|role-source|prefix)=' "$work/out" || true
    status=1
  else
    echo "OK: role-from $title gives $want_role (workflow-file)"
  fi
}
ir=tenstorrent/internal-requests
wf_role_is '.yml' $ir 'tenstorrent/internal-requests/.github/workflows/create-repo.yml@refs/heads/main' \
  tenstorrent--internal-requests--create-repo
wf_role_is '.yaml' $ir 'tenstorrent/internal-requests/.github/workflows/create-repo.yaml@refs/heads/main' \
  tenstorrent--internal-requests--create-repo
wf_role_is 'file name in upper case' $ir 'tenstorrent/internal-requests/.github/workflows/Create-Repo.YML@refs/heads/main' \
  tenstorrent--internal-requests--create-repo
wf_role_is 'repository in upper case' tenstorrent/LLM_Perf 'Tenstorrent/LLM_Perf/.github/workflows/nightly.yml@refs/heads/main' \
  tenstorrent--llm_perf--nightly
wf_role_is 'file name with . and _' tenstorrent/.github 'tenstorrent/.github/.github/workflows/vault_secrets.v2.yml@refs/pull/7/merge' \
  tenstorrent--.github--vault_secrets.v2
wf_role_is 'ref with @ and /' tenstorrent/.github 'tenstorrent/.github/.github/workflows/vault-secrets-test.yml@refs/heads/a@b/c' \
  tenstorrent--.github--vault-secrets-test
wf_role_is 'tag ref' tenstorrent/.github 'tenstorrent/.github/.github/workflows/release.yml@refs/tags/v1.0' \
  tenstorrent--.github--release
# A job of a called reusable workflow gets the same GITHUB_WORKFLOW_REF as
# the caller: the file of the caller. The action cannot
# see the called file, so the role is that of the caller file.
wf_role_is 'reusable workflow: the caller file' $ir 'tenstorrent/internal-requests/.github/workflows/create-repo.yml@refs/heads/main' \
  tenstorrent--internal-requests--create-repo

wf_ref='tenstorrent/.github/.github/workflows/vault-secrets-test.yml@refs/heads/main'
not_short='does not give a valid short role name'
refuses_with 'role-from with role also set' \
  "input role-from workflow-file makes the role name from the workflow file name, so input role must be empty (role: 'nightly')" \
  IN_ROLE_FROM=workflow-file IN_ROLE=nightly GITHUB_WORKFLOW_REF="$wf_ref"
refuses_with 'role-from with a full role also set' 'so input role must be empty' \
  IN_ROLE_FROM=workflow-file IN_ROLE=tenstorrent--.github--vault-secrets-test GITHUB_WORKFLOW_REF="$wf_ref"
for v in Workflow-File workflow_file file auto 'input ' ' workflow-file'; do
  refuses_with "role-from '$v'" 'input role-from must be input or workflow-file.' \
    IN_ROLE_FROM="$v" GITHUB_WORKFLOW_REF="$wf_ref"
done
refuses_with 'role-from without GITHUB_WORKFLOW_REF' \
  'input role-from workflow-file needs the runner variable GITHUB_WORKFLOW_REF, but it is empty.' \
  IN_ROLE= IN_ROLE_FROM=workflow-file
odd='is not in the form <owner>/<repo>/.github/workflows/<file>@<ref>'
for r in \
  'tenstorrent/.github/.github/workflows/vault-secrets-test.yml' \
  'vault-secrets-test.yml@refs/heads/main' \
  '.github/workflows/vault-secrets-test.yml@refs/heads/main' \
  'tenstorrent/.github/.github/workflows/sub/x.yml@refs/heads/main' \
  'tenstorrent/.github/workflows/x.yml@refs/heads/main' \
  'tenstorrent/.github/.github/workflows/@refs/heads/main' \
  'tenstorrent/.github/.github/workflows/x.yml@' \
  "tenstorrent/.github/.github/workflows/x.yml${nl}@refs/heads/main" \
  "tenstorrent/.github/.github/workflows/x.yml@refs/heads/main${nl}"; do
  refuses_with "role-from, GITHUB_WORKFLOW_REF '$r'" "$odd" \
    IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="$r"
done
refuses_with 'role-from, file of another repository' \
  'the workflow file tenstorrent/other/.github/workflows/x.yml is not in tenstorrent/.github.' \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF='tenstorrent/other/.github/workflows/x.yml@refs/heads/main'
refuses_with 'role-from, file of another org' 'is not in tenstorrent/.github.' \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF='other/.github/.github/workflows/x.yml@refs/heads/main'
refuses_with 'role-from, file without .yml' 'the workflow file x.json does not end with .yml or .yaml.' \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF='tenstorrent/.github/.github/workflows/x.json@refs/heads/main'
refuses_with 'role-from, stem with --' \
  "the name of the workflow file create--repo.yml does not give a valid short role name ('create--repo'). A short role name has only letters, digits, '.', '_' and '-', starts and ends with a letter, digit or '_', and has no '--'. Set role explicitly and remove role-from." \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF='tenstorrent/.github/.github/workflows/create--repo.yml@refs/heads/main'
# shellcheck disable=SC2016 # '$(id)' is a file name, not an expansion.
for f in 'a b.yml' 'a+b.yml' "a'b.yml" 'a;b.yml' 'a$(id).yml' '-x.yml' '.x.yml' 'x-.yml' 'x..yml' '.yml' 'ä.yml'; do
  refuses_with "role-from, file name '$f'" "$not_short" \
    IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="tenstorrent/.github/.github/workflows/$f@refs/heads/main"
done
long="$(printf 'x%.0s' $(seq 240))"
refuses_with 'role-from, role name too long' "$not_short" \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="tenstorrent/.github/.github/workflows/$long.yml@refs/heads/main"

# Values in role-from messages are escaped for the workflow command: '%' is
# %25, CR is %0D, LF is %0A, other control characters are blanks. Fails unless
# prepare.sh, with the replaced inputs $3..., fails with exactly one log line,
# an '::error' line that contains $2.
refuses_escaped() {
  local title="$1" want="$2"
  shift 2
  run_env "$@"
  if [ "$rc" -eq 0 ]; then
    echo "::error::$title: prepare.sh accepted it, expected a refusal"
    status=1
  elif [ "$(wc -l <"$work/log")" -ne 1 ] || ! grep -q '^::error title=vault-secrets::' "$work/log"; then
    echo "::error::$title: the log is not exactly one ::error line"
    sed 's/^::/: :/' "$work/log"
    status=1
  elif ! grep -q -F -- "$want" "$work/log"; then
    echo "::error::$title: the ::error line does not have the escaped text '$want'"
    sed 's/^::/: :/' "$work/log"
    status=1
  elif LC_ALL=C grep -q '[[:cntrl:]]' "$work/log"; then
    echo "::error::$title: the ::error line has a control character"
    status=1
  else
    echo "OK: refused, escaped: $title"
  fi
}
wf='tenstorrent/.github/.github/workflows'
refuses_escaped 'role with LF and a command' "(role: 'x%0A::warning::injected')" \
  IN_ROLE_FROM=workflow-file "IN_ROLE=x${nl}::warning::injected" GITHUB_WORKFLOW_REF="$wf/x.yml@refs/heads/main"
refuses_escaped 'role with %0A and CR' "(role: 'a%250Ab%0Dc')" \
  IN_ROLE_FROM=workflow-file "IN_ROLE=a%0Ab"$'\r'"c" GITHUB_WORKFLOW_REF="$wf/x.yml@refs/heads/main"
refuses_escaped 'ref with LF and a command' "GITHUB_WORKFLOW_REF '$wf/x.yml@refs/heads/main%0A::warning::injected'" \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="$wf/x.yml@refs/heads/main${nl}::warning::injected"
refuses_escaped 'ref with %0D%0A, %25 and ESC' "'$wf/x.yml%250D%250A%2525 x' is not in the form" \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="$wf/x.yml%0D%0A%25"$'\033'"x"
refuses_escaped 'file name with %0A' "the name of the workflow file a%250A::warning::b.yml does not give" \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="$wf/a%0A::warning::b.yml@refs/heads/main"
refuses_escaped 'file name with %0D, no .yml' "the workflow file a%250Db.json does not end" \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="$wf/a%0Db.json@refs/heads/main"
refuses_escaped 'other repository with %0A' "the workflow file tenstorrent/o%250Ax/.github/workflows/x.yml is not in" \
  IN_ROLE= IN_ROLE_FROM=workflow-file GITHUB_WORKFLOW_REF="tenstorrent/o%0Ax/.github/workflows/x.yml@refs/heads/main"
# role-from input and an empty role-from behave as no role-from (release 1.1).
role_from_input_is() {
  local title="$1" in="$2" want_role="$3" want_source="$4"
  run_env IN_ROLE_FROM=input IN_ROLE="$in" GITHUB_WORKFLOW_REF="$wf_ref"
  if [ "$rc" -ne 0 ] || ! grep -q -x -F -- "role=$want_role" "$work/out" \
    || ! grep -q -x -F -- "role-source=$want_source" "$work/out"; then
    echo "::error::role-from input, $title: expected role=$want_role role-source=$want_source"
    cat "$work/log"
    status=1
  else
    echo "OK: role-from input, $title gives $want_role ($want_source)"
  fi
}
role_from_input_is 'empty role' '' tenstorrent--.github default
role_from_input_is 'short role' nightly tenstorrent--.github--nightly short
role_from_input_is 'full role' tenstorrent--.github--x tenstorrent--.github--x full
run_env IN_ROLE_FROM= IN_ROLE=nightly GITHUB_WORKFLOW_REF="$wf_ref"
if [ "$rc" -ne 0 ] || ! grep -q -x -F -- 'role=tenstorrent--.github--nightly' "$work/out"; then
  echo "::error::empty role-from: expected the role from input role"
  status=1
else
  echo "OK: empty role-from uses input role"
fi
refuses_with 'role-from input keeps the role checks' "$chars" \
  IN_ROLE_FROM=input 'IN_ROLE=test role'

# Fails unless prepare.sh, in repository $2 with IN_GITHUB_TOKEN=$3 and
# IN_SECRETS=$4, writes token-set=$5 and spec $6.
token_is() {
  local title="$1" repo="$2" in="$3" secrets="$4" want_set="$5" want_spec="$6"
  run_env REPOSITORY="$repo" IN_GITHUB_TOKEN="$in" IN_SECRETS="$secrets"
  if [ "$rc" -ne 0 ]; then
    echo "::error::github-token $title: prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif ! grep -q -x -F -- "token-set=$want_set" "$work/out"; then
    echo "::error::github-token $title: expected token-set=$want_set"
    grep -E '^token-set=' "$work/out" || true
    status=1
  elif [ "$spec" != "$want_spec" ]; then
    echo "::error::github-token $title: spec output is not as expected"
    printf 'got:\n%s\nwant:\n%s\n' "$spec" "$want_spec"
    status=1
  else
    echo "OK: github-token $title gives token-set '$want_set'"
  fi
}
kv='kv/data/app value | API_KEY'
token_is 'short key' tenstorrent/.github contents-read '' tenstorrent--.github--contents-read ''
token_is 'short key without hyphen' tenstorrent/.github admin '' tenstorrent--.github--admin ''
token_is 'short key with . and _' tenstorrent/.github members_read.v2 '' tenstorrent--.github--members_read.v2 ''
token_is 'short key in upper case' tenstorrent/.github Contents-Read '' tenstorrent--.github--contents-read ''
token_is 'short key with blanks' tenstorrent/.github ' contents-read ' '' tenstorrent--.github--contents-read ''
token_is 'short key, repository in upper case' tenstorrent/LLM_Perf tt-blaze-read '' \
  tenstorrent--llm_perf--tt-blaze-read ''
token_is 'full name' tenstorrent/.github tenstorrent--.github--contents-read '' \
  tenstorrent--.github--contents-read ''
token_is 'full name in mixed case' tenstorrent/.github Tenstorrent--.GitHub--Contents-Read '' \
  tenstorrent--.github--contents-read ''
token_is 'full path, used as is' tenstorrent/.github github-admin/token/tenstorrent--internal-requests--org-read '' \
  '' 'github-admin/token/tenstorrent--internal-requests--org-read token | VAULT_SECRETS_GITHUB_TOKEN'
token_is 'short key and secrets' tenstorrent/.github contents-read "$kv ;" \
  tenstorrent--.github--contents-read "$kv"
token_is 'full path and secrets' tenstorrent/.github "$path_token" "$kv" \
  '' "$kv ;${nl}${token_line}"
token_is 'secrets only' tenstorrent/.github '' "$kv" '' "$kv"

# Fails unless prepare.sh refuses to run without $1 on PATH. The PATH holds
# links to the other tools that prepare.sh and this test need.
refuses_without_tool() {
  local missing="$1" bin="$work/bin-no-$1" tool path
  mkdir -p "$bin"
  for tool in bash env od tr curl jq; do
    [ "$tool" = "$missing" ] && continue
    path="$(command -v "$tool")"
    ln -sf "$path" "$bin/$tool"
  done
  refuses_with "runner without $missing" "this runner has no $missing" PATH="$bin"
}
refuses_without_tool jq
refuses_without_tool curl

# Fails unless prepare.sh, with IN_VAULT_TIMEOUT=$1, writes vault-timeout=$2.
timeout_is() {
  run_env IN_VAULT_TIMEOUT="$1"
  if [ "$rc" -ne 0 ]; then
    echo "::error::vault-timeout-seconds '$1': prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif ! grep -q -x -- "vault-timeout=$2" "$work/out"; then
    echo "::error::vault-timeout-seconds '$1': output vault-timeout is not $2"
    status=1
  else
    echo "OK: accepted: vault-timeout-seconds '$1' gives $2"
  fi
}
timeout_is '' 120
timeout_is 10 10
timeout_is 600 600

refuses 'exact output name' 'kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN'
refuses 'exact output name with blanks and ;' "kv/data/app value |  VAULT_SECRETS_GITHUB_TOKEN  ;${nl}"
refuses 'output name in lower case' 'kv/data/app value | vault_secrets_github_token'
refuses 'output name in the second entry' \
  "kv/data/app a | A ;${nl}kv/data/app b | VAULT_SECRETS_GITHUB_TOKEN"
refuses 'default name from the selector' 'kv/data/app VAULT_SECRETS_GITHUB_TOKEN'
refuses 'default name from a quoted selector' 'kv/data/app "vault_secrets_github_token"'

# Network mode (release 1.2).
refuses_with 'bad network mode' 'input network-mode must be kernel or userspace' IN_NETWORK_MODE=auto
refuses_with 'network mode in upper case' 'input network-mode must be kernel or userspace' IN_NETWORK_MODE=USERSPACE
refuses_with 'userspace on macOS' 'input network-mode userspace needs a Linux runner' \
  IN_NETWORK_MODE=userspace RUNNER_OS=macOS
refuses_with 'userspace without RUNNER_OS' 'input network-mode userspace needs a Linux runner' \
  IN_NETWORK_MODE=userspace
for port in 0 65536 99999 -1 12.5 01055 ' 1055' '1055;echo bad' x; do
  refuses_with "proxy-port '$port'" 'input proxy-port must be a whole number from 1 to 65535' \
    IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT="$port"
done

# Fails unless the kernel outputs are the same as in release 1.1: no
# tailscaled arguments, no proxy, no environment change for vault-action.
kernel_is_plain() {
  local title="$1"
  shift
  run_env "$@"
  if [ "$rc" -ne 0 ]; then
    echo "::error::$title: prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif ! grep -q -x 'proxy-env={}' "$work/out" || ! grep -q -x 'proxy-url=' "$work/out" \
    || ! grep -q -x 'tailscaled-args=' "$work/out"; then
    echo "::error::$title: kernel mode has proxy or tailscaled outputs"
    status=1
  elif [ -s "$work/log" ]; then
    echo "::error::$title: kernel mode printed a message"
    cat "$work/log"
    status=1
  else
    echo "OK: $title: no proxy, no tailscaled arguments"
  fi
}
kernel_is_plain 'network-mode not set'
kernel_is_plain 'network-mode kernel' IN_NETWORK_MODE=kernel
kernel_is_plain 'kernel ignores proxy-port' IN_NETWORK_MODE=kernel IN_PROXY_PORT=x
kernel_is_plain 'kernel on macOS' IN_NETWORK_MODE=kernel RUNNER_OS=macOS

# Fails unless userspace mode with proxy-port $1 gives the proxy on loopback
# port $2, only an HTTP proxy (no SOCKS5), and an environment for vault-action
# that holds only the preload. The runner's own proxy variables stay out of it.
userspace_is() {
  local port="$1" want="$2" proxy_env
  run_env IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT="$port" IN_JOIN_TAILNET=true \
    NODE_OPTIONS=--trace-warnings NO_PROXY='*' no_proxy='*' HTTPS_PROXY=http://egress.invalid:3128
  proxy_env="$(sed -n 's/^proxy-env=//p' "$work/out")"
  if [ "$rc" -ne 0 ]; then
    echo "::error::userspace proxy-port '$port': prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif ! grep -q -x "proxy-url=http://127.0.0.1:$want" "$work/out"; then
    echo "::error::userspace proxy-port '$port': output proxy-url is not http://127.0.0.1:$want"
    status=1
  elif ! grep -q -x -- "tailscaled-args=--tun=userspace-networking --outbound-http-proxy-listen=127.0.0.1:$want" "$work/out"; then
    echo "::error::userspace proxy-port '$port': output tailscaled-args is not as expected"
    status=1
  elif ! printf '%s' "$proxy_env" | jq -e --arg url "http://127.0.0.1:$want" '
    (keys == ["NODE_OPTIONS", "VAULT_SECRETS_PROXY_URL"]) and
    .VAULT_SECRETS_PROXY_URL == $url and
    (.NODE_OPTIONS | startswith("--trace-warnings --require=\"")) and
    (.NODE_OPTIONS | endswith("/proxy-agent.cjs\""))' >/dev/null; then
    echo "::error::userspace proxy-port '$port': output proxy-env is not as expected: $proxy_env"
    status=1
  else
    echo "OK: userspace proxy-port '$port' gives 127.0.0.1:$want"
  fi
}
userspace_is '' 1055
userspace_is 1 1
userspace_is 21055 21055
userspace_is 65535 65535

# Userspace without a join uses a Tailscale HTTP proxy that already runs.
# prepare.sh refuses when nothing answers on proxy-port, and never joins a
# second time. A local listener stands in for the proxy; a fake tailscale
# whose status succeeds stands in for a runner already on the tailnet.
python3 -c '
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
print(s.getsockname()[1], flush=True)
while True:
    c, _ = s.accept()
    c.recv(4096)
    c.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    c.close()
' >"$work/listener.port" &
listener_pid=$!
disown "$listener_pid" 2>/dev/null || true
for _ in $(seq 50); do [ -s "$work/listener.port" ] && break; sleep 0.1; done
live_port="$(cat "$work/listener.port")"
free_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
mkdir -p "$work/ts-on" "$work/ts-off"
printf '#!/bin/sh\nexit 0\n' >"$work/ts-on/tailscale"
printf '#!/bin/sh\nexit 1\n' >"$work/ts-off/tailscale"
chmod +x "$work/ts-on/tailscale" "$work/ts-off/tailscale"
on_tailnet="$work/ts-on:$PATH"
off_tailnet="$work/ts-off:$PATH"

# Fails unless prepare.sh, with the replaced inputs $3..., succeeds with
# output join=$2 and proxy-url on port $4.
userspace_join_is() {
  local title="$1" want_join="$2" port="$3"
  shift 3
  run_env IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT="$port" "$@"
  if [ "$rc" -ne 0 ]; then
    echo "::error::$title: prepare.sh failed (exit $rc), expected exit 0"
    cat "$work/log"
    status=1
  elif ! grep -q -x "join=$want_join" "$work/out" \
    || ! grep -q -x "proxy-url=http://127.0.0.1:$port" "$work/out"; then
    echo "::error::$title: outputs join and proxy-url are not join=$want_join, port $port"
    status=1
  else
    echo "OK: $title: join=$want_join"
  fi
}
refuses_with 'userspace, join false, no proxy' \
  "join-tailnet false: no Tailscale HTTP proxy answers on 127.0.0.1:$free_port" \
  IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT="$free_port" IN_JOIN_TAILNET=false
userspace_join_is 'userspace, join false, proxy runs' false "$live_port" IN_JOIN_TAILNET=false
refuses_with 'userspace, auto, on the tailnet, no proxy' \
  "already on the tailnet, but no Tailscale HTTP proxy answers on 127.0.0.1:$free_port" \
  IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT="$free_port" IN_JOIN_TAILNET=auto PATH="$on_tailnet"
refuses_with 'userspace, auto, refusal names the ways out' 'Use join-tailnet: true on a runner without Tailscale' \
  IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT="$free_port" IN_JOIN_TAILNET=auto PATH="$on_tailnet"
userspace_join_is 'userspace, auto, on the tailnet, proxy runs' false "$live_port" \
  IN_JOIN_TAILNET=auto PATH="$on_tailnet"
userspace_join_is 'userspace, auto, not on the tailnet' true "$free_port" \
  IN_JOIN_TAILNET=auto PATH="$off_tailnet"
userspace_join_is 'userspace, join true, no probe' true "$free_port" IN_JOIN_TAILNET=true
run_env IN_NETWORK_MODE=kernel IN_PROXY_PORT="$free_port" IN_JOIN_TAILNET=auto PATH="$on_tailnet"
if [ "$rc" -ne 0 ] || ! grep -q -x 'join=false' "$work/out" || grep -q 'proxy' "$work/log"; then
  echo "::error::kernel, auto, on the tailnet: expected join=false and no proxy check"
  cat "$work/log"
  status=1
else
  echo "OK: kernel, auto, on the tailnet: join=false, no proxy check"
fi

exit "$status"

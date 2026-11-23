#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs prepare.sh directly, without Vault or the network. Checks that each
# pre-check refuses its case with its own message, and checks the reserved
# output name rule: prepare.sh accepts a `secrets` value that only contains the
# reserved name, and refuses a value that uses it as an output name. Checks
# the role resolution (default, short and full names) and its refusals.
# Uses no token and no secret.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare="$here/../prepare.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

token_line='github/token/test-token token | VAULT_SECRETS_GITHUB_TOKEN'

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
accepts 'valid inputs' '' test-token "$token_line"

accepts 'reserved name inside a path' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN_backup value | API_KEY' test-token \
  "kv/data/VAULT_SECRETS_GITHUB_TOKEN_backup value | API_KEY ;${nl}${token_line}"
accepts 'reserved name inside a path, no github-token' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN/x value | API_KEY ;' '' \
  'kv/data/VAULT_SECRETS_GITHUB_TOKEN/x value | API_KEY'
accepts 'output name that only starts with the reserved name' \
  "kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN_2 ;${nl}kv/data/app other | B" test-token \
  "kv/data/app value | VAULT_SECRETS_GITHUB_TOKEN_2 ;${nl}kv/data/app other | B ;${nl}${token_line}"
accepts 'default name with a dash is not the reserved name' \
  'kv/data/app VAULT-SECRETS_GITHUB_TOKEN' test-token \
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

refuses_with 'bad network mode' 'network-mode must be kernel or userspace' IN_NETWORK_MODE=auto
refuses_with 'userspace on unsupported OS' 'requires a Linux runner' IN_NETWORK_MODE=userspace RUNNER_OS=macOS
for port in 0 65536 -1 12.5 01055 '1055;echo bad'; do
  refuses_with "bad proxy port $port" 'proxy-port must be a whole number' \
    IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT="$port"
done
run_env IN_NETWORK_MODE=kernel
if ! grep -q -x 'proxy-env={}' "$work/out" || ! grep -q -x 'proxy-url=' "$work/out"; then
  echo '::error::kernel mode changed the proxy environment'
  status=1
fi
run_env IN_NETWORK_MODE=userspace RUNNER_OS=Linux IN_PROXY_PORT=21055 \
  NODE_OPTIONS=--trace-warnings NO_PROXY='*' no_proxy='*' HTTPS_PROXY=http://egress.invalid:3128
if [ "$rc" -ne 0 ]; then
  cat "$work/log"
  status=1
else
  proxy_env="$(sed -n 's/^proxy-env=//p' "$work/out")"
  if ! printf '%s' "$proxy_env" | jq -e '
    .VAULT_SECRETS_PROXY_URL == "http://127.0.0.1:21055" and
    .VAULT_SECRETS_OIDC_HOST == "example.invalid" and
    (has("http_proxy") | not) and (has("https_proxy") | not) and (has("no_proxy") | not) and
    (has("HTTP_PROXY") | not) and (has("HTTPS_PROXY") | not) and (has("NO_PROXY") | not) and
    (.NODE_OPTIONS | startswith("--trace-warnings --require=\"")) and
    (.NODE_OPTIONS | endswith("/proxy-agent.cjs\""))' >/dev/null; then
    echo '::error::userspace mode did not scope proxy settings correctly'
    status=1
  fi
  grep -q -x 'proxy-url=http://127.0.0.1:21055' "$work/out" || status=1
  grep -q -- '--tun=userspace-networking' "$work/out" || status=1
fi

exit "$status"

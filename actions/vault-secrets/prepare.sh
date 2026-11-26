#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
# (The tripwires run in a subshell that exports defaults for the inputs; the
# rest of the script reads the inputs themselves.)
# Pre-checks for the vault-secrets action. Fails early with a plain message.
# Every input arrives through env (never through ${{ }} in shell text).
#
# Reads:  IN_ROLE IN_GITHUB_TOKEN IN_SECRETS IN_VAULT_URL IN_JOIN_TAILNET
#         IN_TS_CLIENT_ID IN_TS_AUDIENCE IN_TS_TAGS IN_VAULT_TIMEOUT EVENT_NAME
#         REPOSITORY (github.repository) ACTIONS_ID_TOKEN_REQUEST_URL GITHUB_OUTPUT
# Optional: IN_NETWORK_MODE IN_PROXY_PORT RUNNER_OS NODE_OPTIONS
# Runs:   ../tripwires/tripwires.py (python3), from the same download of this
#         repository as the action
# Writes: outputs url, join, spec, vault-timeout, role, role-source, prefix,
#         token-set, tailscaled-args, proxy-url, proxy-env
set -euo pipefail

DEFAULT_URL='https://vault-ospo.eng-svc.aws.tenstorrent.com'
TOKEN_OUTPUT='VAULT_SECRETS_GITHUB_TOKEN'

fail() {
  printf '::error title=vault-secrets::%s\n' "$1"
  exit 1
}

for tool in curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "this runner has no $tool; the action needs bash, curl, jq and python3."
done

# Tripwires (../tripwires/README.md): values that only make sense as an attack.
# No fallback and no hint: the annotation is titled "vault-secrets: possible
# security compromise attempt" and never shows the value.
# - pull_request_target runs with base-branch rights on untrusted pull request
#   code. Use pull_request, push, workflow_dispatch or schedule.
# - The action sends the OIDC token of the job to vault-url. Only OSPO Vault
#   gets it.
# - A name that starts with '-' or holds a line break is no role, token or
#   Tailscale setting.
# The checks below still give each unsupported value its own message.
# - The environment must not be prepared to run code in the action's scripts
#   or to print their secrets (BASH_ENV, LD_PRELOAD, any exported shell
#   function, tracing, a PATH that finds curl, jq or bash in the workspace, a
#   library of theirs or a certificate file in the workspace), and the OIDC
#   request must go to GitHub.
# Python (-I: no PYTHON* variables, no user site) gets neither the step outputs
# nor the OIDC request token.
#
# Test fixture only (test/proxy/fixture.py, which serves a local OIDC endpoint):
# the OIDC URL check is skipped for the one URL in a file that the fixture
# writes into this action's own directory. A value in GITHUB_ENV cannot write
# that file, and whoever can write there can change this script as well.
# The launch itself must not depend on a command that an exported shell
# function can replace (env, python3, dirname): in POSIX mode bash finds unset,
# export, exec and exit before any function, and exec runs a file from PATH.
# POSIXLY_CORRECT=1 is on a line of its own on purpose: bash reads the rest of
# that line before the mode changes.
tripwires_here="${BASH_SOURCE[0]%/*}"
[[ "$tripwires_here" != "${BASH_SOURCE[0]}" ]] || tripwires_here=.
# The interpreter of the checks, never one from the workspace (see the file).
# shellcheck disable=SC2034
tripwires_python_names=python3
# shellcheck source=/dev/null
. "$tripwires_here/../tripwires/trusted-python.sh"
[[ -n "$tripwires_python" ]] || fail "this runner has python3 only inside the workspace; the action needs Python 3.9+ on PATH outside it to run its checks."
[[ "$tripwires_here" == /* ]] || tripwires_here="$PWD/$tripwires_here"
oidc_check='oidc-url       ACTIONS_ID_TOKEN_REQUEST_URL'
fixture_url="$tripwires_here/test/proxy/oidc-request-url"
if [[ -f "$fixture_url" && -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  IFS= read -r fixture_url <"$fixture_url" || true
  if [[ "$fixture_url" == "$ACTIONS_ID_TOKEN_REQUEST_URL" ]]; then
    echo "Test fixture: the OIDC request goes to the local endpoint of test/proxy/fixture.py."
    oidc_check='# oidc-url: local test fixture'
  fi
fi
tripwire_fired=""
(
  POSIXLY_CORRECT=1
  unset GITHUB_OUTPUT ACTIONS_ID_TOKEN_REQUEST_TOKEN
  export GITHUB_EVENT_NAME="${EVENT_NAME:-}"
  export IN_VAULT_URL="${IN_VAULT_URL:-}" IN_ROLE="${IN_ROLE:-}" IN_GITHUB_TOKEN="${IN_GITHUB_TOKEN:-}"
  export ACTIONS_ID_TOKEN_REQUEST_URL="${ACTIONS_ID_TOKEN_REQUEST_URL:-}"
  export IN_TS_CLIENT_ID="${IN_TS_CLIENT_ID:-}" IN_TS_AUDIENCE="${IN_TS_AUDIENCE:-}" IN_TS_TAGS="${IN_TS_TAGS:-}"
  exec "$tripwires_python" -I "$tripwires_here/../tripwires/tripwires.py" \
    --title vault-secrets --consequence "No request was sent to Vault."
) <<EOF || tripwire_fired=1
event          pull_request_target
environment    curl jq tailscale bash
$oidc_check
trusted-origin IN_VAULT_URL=vault-url https://vault-ospo.eng-svc.aws.tenstorrent.com https://vault-ospo-staging.eng-svc.aws.tenstorrent.com
no-option      IN_ROLE=role
single-line    IN_ROLE=role
no-option      IN_GITHUB_TOKEN=github-token
single-line    IN_GITHUB_TOKEN=github-token
no-option      IN_TS_CLIENT_ID=tailscale-client-id
single-line    IN_TS_CLIENT_ID=tailscale-client-id
no-option      IN_TS_AUDIENCE=tailscale-audience
single-line    IN_TS_AUDIENCE=tailscale-audience
no-option      IN_TS_TAGS=tailscale-tags
single-line    IN_TS_TAGS=tailscale-tags
EOF
if [[ -n "$tripwire_fired" ]]; then
  POSIXLY_CORRECT=1
  exit 1
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  fail "job needs permissions: id-token: write (not available on fork pull requests)"
fi

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Vault role (jwt-github). The grant module names roles
#   <org>--<repo>          first workflow entry without a name (default role)
#   <org>--<repo>--<name>  entry with a name (or --<i+1> for a later entry without one)
# always in lower case. Vault binds the OIDC claim `repository`, which is
# github.repository (also in a called reusable workflow), so only roles with
# this prefix can work. The action builds one name and tries one login.
repository="${REPOSITORY:-}"
[ -n "$repository" ] || fail "github.repository is empty. The action needs it to build the Vault role name."
[[ "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] \
  || fail "github.repository '$repository' is not in the form <owner>/<repo>."
prefix="$(lower "${repository/\//--}")"

role_in="${IN_ROLE:-}"
role_in="${role_in#"${role_in%%[![:space:]]*}"}"
role_in="${role_in%"${role_in##*[![:space:]]}"}"
role_lower="$(lower "$role_in")"
if [ -z "$role_in" ]; then
  role="$prefix"
  role_source=default
elif ! [[ "$role_in" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$role_in" == [-.]* ]]; then
  fail "input role has characters that a Vault role name cannot have. Allowed: letters, digits, '.', '_', '-'. Use the short name of your workflow entry (for example nightly) or leave role empty."
elif [ "$role_lower" = "$prefix" ] || [[ "$role_lower" == "$prefix--"* ]]; then
  role="$role_lower"
  role_source=full
elif [[ "$role_in" == *--* ]]; then
  fail "input role '$role_in' is not a role of $repository. Its roles start with $prefix. Use the short name, the part after '$prefix--'."
else
  role="$prefix--$role_lower"
  role_source=short
fi
# Strict check of the result: the prefix, optionally '--' and a name that
# starts and ends with a letter, digit or '_'.
suffix="${role#"$prefix"}"
if [ -n "$suffix" ] && ! [[ "$suffix" =~ ^--[a-z0-9_]([a-z0-9._-]*[a-z0-9_])?$ ]]; then
  fail "input role '$role_in' does not give a valid Vault role name ($role). Use the short name of your workflow entry (for example nightly) or leave role empty."
fi
[ "${#role}" -le 255 ] || fail "input role is too long for a Vault role name."

# Trim trailing blanks and ';' so that the token line can be appended.
secrets="${IN_SECRETS:-}"
while [[ "$secrets" =~ [[:space:]\;]$ ]]; do secrets="${secrets%?}"; done
while [[ "$secrets" =~ ^[[:space:]\;] ]]; do secrets="${secrets#?}"; done

github_token="${IN_GITHUB_TOKEN:-}"
github_token="${github_token#"${github_token%%[![:space:]]*}"}"
github_token="${github_token%"${github_token##*[![:space:]]}"}"
if [ -z "$github_token" ] && [ -z "$secrets" ]; then
  fail "nothing to get: set github-token, secrets, or both."
fi

# The output name that hashicorp/vault-action v4.0.0 gives one `secrets` entry
# (src/action.js parseSecretsInput, src/utils.js normalizeOutputKey):
# - Entries are split on ';', not on lines.
# - With '|', the name is the text after the last '|', trimmed. It is used as is.
# - Without '|', the name is the selector (second word) without '"', with '.'
#   changed to '__', '-' removed, and other characters that are not letters,
#   digits or '_' removed.
# A wildcard selector ('*') takes its names from the keys in Vault. This
# check cannot see those names.
output_name() {
  local entry="$1" name selector
  local -a words=()
  if [[ "$entry" == *'|'* ]]; then
    name="${entry##*|}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
  else
    read -r -d '' -a words <<<"$entry" || true
    selector="${words[1]:-}"
    name="${selector//\"/}"
    name="${name//./__}"
    name="${name//-/}"
    name="${name//[^[:alnum:]_]/}"
  fi
  printf '%s' "$name"
}

# Step output names do not depend on case in expressions, so compare in upper case.
entries=()
IFS=';' read -r -d '' -a entries <<<"$secrets" || true
for entry in "${entries[@]+"${entries[@]}"}"; do
  [[ "$entry" =~ [^[:space:]] ]] || continue
  name="$(output_name "$entry" | tr '[:lower:]' '[:upper:]')"
  if [ "$name" = "$TOKEN_OUTPUT" ]; then
    fail "secrets uses the output name $TOKEN_OUTPUT, which this action keeps for github-token. Choose another name."
  fi
done

# GitHub token. The grant module names token sets <org>--<repo>--<key> (lower
# case), and a role can only have token sets of its own repository. So the
# rules are the same as for role:
#   key (no '--')            <prefix>--<key>; read-token.sh finds the engine
#   <prefix>--<key>          full name; read-token.sh finds the engine
#   name of another repo     refused here, before any request
#   value with '/'           full Vault path, read as is by vault-action (1.0 form)
token_set=""
spec="$secrets"
if [[ "$github_token" == */* ]]; then
  [[ "$github_token" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
    || fail "input github-token is not a valid token name or path. Use the key of the token in your grant, for example contents-read."
  token_line="$github_token token | $TOKEN_OUTPUT"
  if [ -n "$spec" ]; then
    spec="$spec ;"$'\n'"$token_line"
  else
    spec="$token_line"
  fi
elif [ -n "$github_token" ]; then
  if ! [[ "$github_token" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$github_token" == [-.]* ]]; then
    fail "input github-token is not a valid token name or path. Allowed: letters, digits, '.', '_', '-'. Use the key of the token in your grant, for example contents-read."
  fi
  token_lower="$(lower "$github_token")"
  if [[ "$token_lower" == "$prefix--"* ]]; then
    token_set="$token_lower"
  elif [ "$token_lower" = "$prefix" ] || [[ "$token_lower" == *--* ]]; then
    fail "input github-token '$github_token' is not a token of $repository. Its token names start with $prefix--. Use the key of the token in your grant, the part after '$prefix--'."
  else
    token_set="$prefix--$token_lower"
  fi
  token_key="${token_set#"$prefix--"}"
  if ! [[ "$token_key" =~ ^[a-z0-9_]([a-z0-9._-]*[a-z0-9_])?$ ]]; then
    fail "input github-token '$github_token' does not give a valid token name ($token_set). Use the key of the token in your grant, for example contents-read."
  fi
  [ "${#token_set}" -le 255 ] || fail "input github-token is too long for a token name."
fi

url="${IN_VAULT_URL:-$DEFAULT_URL}"
while [[ "$url" == */ ]]; do url="${url%/}"; done
# The tripwire above already refused every other host. This keeps the one
# spelling the later steps use (no port, no upper case).
case "$url" in
  https://vault-ospo.eng-svc.aws.tenstorrent.com | https://vault-ospo-staging.eng-svc.aws.tenstorrent.com) ;;
  *) fail "input vault-url is not an OSPO Vault URL. Remove the input to use the default. Allowed: https://vault-ospo.eng-svc.aws.tenstorrent.com, https://vault-ospo-staging.eng-svc.aws.tenstorrent.com." ;;
esac

# Time limit of the Vault step, in seconds (see watchdog.sh).
vault_timeout="${IN_VAULT_TIMEOUT:-120}"
if ! [[ "$vault_timeout" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$vault_timeout" -lt 10 ] || [ "$vault_timeout" -gt 600 ]; then
  fail "input vault-timeout-seconds must be a whole number from 10 to 600."
fi

join="${IN_JOIN_TAILNET:-auto}"
case "$join" in
  true | false) ;;
  auto)
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
      echo "This runner is already on the tailnet. The action does not join again."
      join=false
    else
      join=true
    fi
    ;;
  *) fail "input join-tailnet must be auto, true or false." ;;
esac

if [ "$join" = true ]; then
  [ -n "${IN_TS_CLIENT_ID:-}" ] || fail "input tailscale-client-id is empty. It is needed to join the tailnet."
  [ -n "${IN_TS_AUDIENCE:-}" ] || fail "input tailscale-audience is empty. It is needed to join the tailnet."
  [ -n "${IN_TS_TAGS:-}" ] || fail "input tailscale-tags is empty. It is needed to join the tailnet."
fi

# Network mode (release 1.2). kernel: the runner reaches Vault through its own
# routes (default, as in 1.1). userspace: tailscaled runs without TUN and
# NET_ADMIN, and Vault traffic goes through its loopback HTTP proxy. The
# action starts no SOCKS5 proxy: no client of the action uses one.
# The GitHub OIDC request keeps the runner's own proxy environment.
network_mode="${IN_NETWORK_MODE:-kernel}"
proxy_port="${IN_PROXY_PORT:-1055}"
proxy_url=""
tailscaled_args=""
proxy_env='{}'
case "$network_mode" in
  kernel)
    # proxy-port has no effect in kernel mode. Not set gives 1055 (the default
    # in action.yml) or empty (prepare.sh run directly): no warning for these.
    if [ -n "${IN_PROXY_PORT:-}" ] && [ "$IN_PROXY_PORT" != 1055 ]; then
      printf '::warning title=vault-secrets::%s\n' "input proxy-port has no effect without network-mode: userspace. The action ignores it in kernel mode."
    fi
    ;;
  userspace)
    [ "${RUNNER_OS:-}" = Linux ] || fail "input network-mode userspace needs a Linux runner (this runner: ${RUNNER_OS:-unknown})."
    if ! [[ "$proxy_port" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$proxy_port" -gt 65535 ]; then
      fail "input proxy-port must be a whole number from 1 to 65535."
    fi
    proxy_url="http://127.0.0.1:$proxy_port"
    tailscaled_args="--tun=userspace-networking --outbound-http-proxy-listen=127.0.0.1:$proxy_port"
    # hashicorp/vault-action has no proxy input. A step-local Node preload
    # gives its HTTP client (got, Node global agents) the Tailscale proxy.
    preload="$tripwires_here/proxy-agent.cjs"
    # NODE_OPTIONS accepts double-quoted paths; escape quotes and backslashes.
    preload="${preload//\\/\\\\}"
    preload="${preload//\"/\\\"}"
    proxy_env="$(jq -cn --arg proxy "$proxy_url" \
      --arg options "${NODE_OPTIONS:+$NODE_OPTIONS }--require=\"$preload\"" \
      '{VAULT_SECRETS_PROXY_URL:$proxy, NODE_OPTIONS:$options}')"
    ;;
  *) fail "input network-mode must be kernel or userspace." ;;
esac

# Userspace without a join (join-tailnet false, or auto on a runner that is
# already on the tailnet): the action uses a Tailscale HTTP proxy that already
# runs. Something must answer on that port now, else the later steps fail. The
# action never starts a second tailscaled next to a running one. curl exit 7
# (refused) and 28 (no answer in 2 seconds) mean that nothing listens; any
# other result means a listener. The wait step then checks the route to Vault.
if [ "$network_mode" = userspace ] && [ "$join" = false ]; then
  probe_rc=0
  curl -q -s --noproxy '*' --connect-timeout 2 --max-time 2 -o /dev/null "$proxy_url/" || probe_rc=$?
  if [ "$probe_rc" -eq 7 ] || [ "$probe_rc" -eq 28 ]; then
    if [ "${IN_JOIN_TAILNET:-auto}" = auto ]; then
      fail "network-mode userspace: this runner is already on the tailnet, but no Tailscale HTTP proxy answers on 127.0.0.1:$proxy_port. The action does not start a second Tailscale. Use join-tailnet: true on a runner without Tailscale, or set proxy-port to the port of the running Tailscale HTTP proxy (with join-tailnet: false), or use network-mode: kernel for a runner with a route to Vault."
    else
      fail "network-mode userspace with join-tailnet false: no Tailscale HTTP proxy answers on 127.0.0.1:$proxy_port. Set proxy-port to the port of the running Tailscale HTTP proxy, or use join-tailnet: true on a runner without Tailscale."
    fi
  fi
fi

delimiter="vault_secrets_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
{
  printf 'url=%s\n' "$url"
  printf 'join=%s\n' "$join"
  printf 'vault-timeout=%s\n' "$vault_timeout"
  printf 'role=%s\n' "$role"
  printf 'role-source=%s\n' "$role_source"
  printf 'prefix=%s\n' "$prefix"
  printf 'token-set=%s\n' "$token_set"
  printf 'tailscaled-args=%s\n' "$tailscaled_args"
  printf 'proxy-url=%s\n' "$proxy_url"
  printf 'proxy-env=%s\n' "$proxy_env"
  printf 'spec<<%s\n%s\n%s\n' "$delimiter" "$spec" "$delimiter"
} >>"$GITHUB_OUTPUT"

# vault-secrets

Gets an ephemeral GitHub token and secrets from OSPO Vault in one step.

The action does these steps:

1. It checks the job and the inputs.
2. It joins the tailnet, if the runner is not on it yet.
3. It waits until Vault answers.
4. It logs in to Vault with the job's GitHub OIDC token.
5. It reads the values.

The Vault grant for your repository must exist first. OSPO keeps the grants in
`github-vault-iac` (`grants/repos/<org>/<repo>.yaml`).

To change an existing workflow, read [RETROFIT.md](RETROFIT.md). To build a new
one, use the skill [vault-secrets-workflow](../../skills/vault-secrets-workflow/SKILL.md).

## Usage

The job needs this permission:

```yaml
    permissions:
      id-token: write
```

Pin the action to a full commit SHA. The current release is `vault-secrets-v1.1.0`. The section [Releases](#releases) gives its commit. Check that a commit is on `main` with `gh api repos/tenstorrent/.github/compare/main...<sha> --jq .status`. The status `identical` or `behind` means yes.

```yaml
      - id: vault
        uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha> # vault-secrets-v1.1.0
        with:
          github-token: lib-read
          secrets: |
            kv/data/tenstorrent/example-app/upload api_key | UPLOAD_API_KEY

      - name: Use the values
        env:
          GH_TOKEN: ${{ steps.vault.outputs.token }}
          KEY: ${{ fromJSON(steps.vault.outputs.secrets).UPLOAD_API_KEY }}
        run: ./upload.sh
```

Give values to later steps through `env:`. Do not put
`${{ steps.vault.outputs.* }}` in `run:` text.

This example has no `role`, so the action uses the default role of the
repository (`tenstorrent--example-app`). For a named workflow entry, set its
short name, for example `role: nightly`.

`github-token: lib-read` is the key of the token in the grant. The action
reads token set `tenstorrent--example-app--lib-read`. The full name and a full
Vault path also still work. See [Inputs](#inputs).

## Releases

Each release has a tag with the action name as prefix: `vault-secrets-vX.Y.Z`. The repository holds several actions, so the prefix is needed. There is no moving major tag such as `v1`.

Pin the full commit SHA of a release. Put the tag in the comment. Do not pin a branch.

```yaml
uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha> # vault-secrets-v1.1.0
```

Current release: [`vault-secrets-v1.1.0`](https://github.com/tenstorrent/.github/releases/tag/vault-secrets-v1.1.0). New releases are listed on the [Releases page](https://github.com/tenstorrent/.github/releases).
To get the commit of a tag, run
`gh api repos/tenstorrent/.github/commits/vault-secrets-v1.1.0 --jq .sha`.
This gives the commit also when the tag is an annotated tag.

| Release | Commit |
|---|---|
| `vault-secrets-v1.1.0` | The commit of the tag. Get it with the command above. |
| `vault-secrets-v1.0.0` | `a697f1bb22ad8b488b0ac63f9a261e462179fe13` |

### What is new in 1.1

- `role` is optional. Without `role`, the action uses the default role
  `<org>--<repo>` of the repository that runs the workflow.
- `role` accepts a short name. `role: nightly` is the role
  `<org>--<repo>--nightly`. A full name `<org>--<repo>--<name>` still works.
  The action uses lower case.
- The action refuses a role of another repository before it logs in.
- The action logs in to Vault itself (`login.sh`). It asks GitHub for the
  OIDC token up to 3 times, with a limit of 15 seconds for each request. It
  sends the Vault login one time, with a limit of 15 seconds.
  `hashicorp/vault-action` then only reads the values with the Vault token.
- `github-token` accepts the key of the token only. `github-token: lib-read`
  is the token set `<org>--<repo>--lib-read`, with the same rules as `role`.
  The full name `<org>--<repo>--<key>` and a full Vault path with `/` still
  work.
- For `github-token` without `/`, the action finds the token itself
  (`read-token.sh`). It asks the token engines `github`, `github-members` and
  `github-admin` in this order and reads the token one time.
  `hashicorp/vault-action` now reads only `secrets`.
- The action refuses a token name of another repository before it sends a
  request to Vault.
- The error messages for a login failure or a token read failure are new.
  They name the role, the token set and the facts of the run. See
  [Failures](#failures).
- No input or output was removed. The values of `failed-step` did not change.

### Upgrade from 1.0

To upgrade, change the pin to the commit of `vault-secrets-v1.1.0` and the
comment to `# vault-secrets-v1.1.0`. No change to the inputs or to the steps
that use the outputs is required.

You can simplify the inputs. All of these are optional:

- Remove `role` when it is the default role of the repository
  (`<org>--<repo>`).
- Change a full role name to its short name, for example
  `tenstorrent--example-app--nightly` to `nightly`.
- Change a full token name to its key, for example
  `github-token: tenstorrent--example-app--lib-read` to
  `github-token: lib-read`.
- Move a token on another engine (for example
  `github-members/token/<org>--<repo>--<key>`) from `secrets` to
  `github-token: <key>`, when the step gets only one token.

These changes occur without action:

- A full token name in `github-token` now also finds a token in the engines
  `github-members` and `github-admin`. In 1.0 the action looked only in
  `github`.
- A token name of another repository in `github-token` is refused before any
  request to Vault. In 1.0 Vault refused it.
- A full Vault path with `/` in `github-token` is read as is, as in 1.0.

If a workflow reads the error text of the Vault step, check it against the new
messages in [Failures](#failures).

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `role` | no | | Vault role of the workflow. Empty: the default role `<org>--<repo>` of the repository that runs the workflow. A short name, for example `nightly`: the role `<org>--<repo>--nightly` of a named workflow entry. A full name `<org>--<repo>--<name>` is used as is. The action uses lower case. A role of another repository is refused. |
| `github-token` | no | | Key of the token in the grant of this repository, for example `lib-read`. The action reads token set `<org>--<repo>--<key>` and finds where Vault keeps it. Still accepted: the full name `<org>--<repo>--<key>`, and (1.0 form) a full Vault path with `/`, which the action reads as is. A name of another repository is refused. |
| `secrets` | no | | Secrets in [hashicorp/vault-action](https://github.com/hashicorp/vault-action) `secrets` syntax: `<path> <field> \| <NAME> ;` per line. |
| `vault-url` | no | `https://vault-ospo.eng-svc.aws.tenstorrent.com` | Vault URL. Only the OSPO Vault production URL (default) and the staging URL are allowed. The JWT audience is always this URL. |
| `join-tailnet` | no | `auto` | `auto` joins unless the runner is already on the tailnet. `true` always joins. `false` never joins. |
| `network-mode` | no | `kernel` | Since release 1.2. `kernel`: the runner reaches Vault through its own routes, as in 1.1. `userspace`: for Linux runner pods without `/dev/net/tun` or `NET_ADMIN`; all Vault requests go through a Tailscale proxy on 127.0.0.1. See [Linux runner pods without TUN](#linux-runner-pods-without-tun-release-12). |
| `proxy-port` | no | `1055` | Since release 1.2. Port of the Tailscale proxy on 127.0.0.1 in `userspace` mode, from 1 to 65535. Not used in `kernel` mode. |
| `tailscale-client-id` | no | value of org variable `TS_VAULT_OSPO_CLIENT_ID` | Tailscale OAuth client ID. Not a secret. |
| `tailscale-audience` | no | value of org variable `TS_VAULT_OSPO_AUDIENCE` | Tailscale OIDC audience. Not a secret. |
| `tailscale-tags` | no | `tag:tt-gha-vault-ospo` | Tags of the runner node. |
| `vault-timeout-seconds` | no | `120` | Time limit of the Vault read, in seconds (10 to 600). After this time the action stops the Vault step and fails. Each request of the Vault login has its own limit of 15 seconds; the OIDC token request is tried up to 3 times. |

Set `github-token`, `secrets`, or both. If both are empty, the action fails.

The two Tailscale defaults are the values of the org variables. They are the
same in all six orgs. A composite action cannot read `vars`, so the action
holds a copy. If an org variable changes, pass the new value:

```yaml
          tailscale-client-id: ${{ vars.TS_VAULT_OSPO_CLIENT_ID }}
          tailscale-audience: ${{ vars.TS_VAULT_OSPO_AUDIENCE }}
```

## Linux runner pods without TUN (release 1.2)

`network-mode` and `proxy-port` come with release 1.2. Release 1.1 does not
have them.

Use `network-mode: userspace` only on a Linux runner pod that has no
`/dev/net/tun` or no `NET_ADMIN`, for example Exabox and CIv2 runner pods. On
all other runners, do not set it: the default `kernel` does the same steps as
release 1.1.

```yaml
          network-mode: userspace
          # proxy-port: '1055' # Change only if this port is already in use.
```

In `userspace` mode:

- The action starts Tailscale with `--tun=userspace-networking` and
  `--outbound-http-proxy-listen=127.0.0.1:<proxy-port>`
  ([userspace networking](https://tailscale.com/kb/1112/userspace-networking)).
  Tailscale then opens an HTTP proxy on 127.0.0.1. The action starts no SOCKS5
  proxy.
- All requests to Vault go through this proxy: the wait for Vault, the login
  (`login.sh`, curl `--proxy`), the GitHub token read (`read-token.sh`, curl
  `--proxy`) and the read of `secrets` (`hashicorp/vault-action`). A
  `NO_PROXY` value of the runner, also `NO_PROXY=*`, does not change this.
- The request for the GitHub OIDC token does not use the Tailscale proxy. It
  uses the proxy settings of the runner (`HTTPS_PROXY`, `NO_PROXY`), the same
  as in `kernel` mode. This works on runners that need an outbound proxy for
  GitHub (CIv2) and on runners with direct access.
- `hashicorp/vault-action` has no proxy input. The action loads a small Node
  preload (`proxy-agent.cjs`) into the read step only, and only when that step
  runs (when there are `secrets` or a `github-token` path with `/`). It gives
  the Node HTTP client of that step the Tailscale proxy.

Limits:

- Linux only. The action fails on other runners.
- The Actions runner must run actions with Node 24.5 or newer. `setup-node`
  does not change this Node. The preload stops the read step on an older Node.
- The Tailscale action still needs `sudo` to install Tailscale. Userspace mode
  removes only the need for TUN and `NET_ADMIN`.
- The runner's outbound proxy must let the Tailscale downloads and the
  Tailscale control plane (`*.tailscale.com`) through.

`join-tailnet` in `userspace` mode:

- `true`, or `auto` on a runner that is not on the tailnet: the action joins
  and starts the proxy on `proxy-port`.
- `auto` on a runner that is already on the tailnet (for example a second call
  in the same job), or `false`: the action does not join. It uses the
  Tailscale HTTP proxy that already runs on `proxy-port`. If nothing answers
  on that port, the first step stops with an error. The action never starts a
  second Tailscale next to a running one. On a runner with a kernel-mode
  Tailscale connection, use `network-mode: kernel`.

The action does not change a connection that it did not make. If something
answers on `proxy-port` but it is not a Tailscale proxy with a route to
Vault, the wait for Vault fails.

The `userspace-proxy` test jobs run the action on Ubuntu and in an Ubuntu
container against a fake Vault, a fake OIDC endpoint and fake proxies on
127.0.0.1, with fake values only. They test the Vault route through the proxy,
the OIDC route (direct and through an outbound proxy), a refused login, empty
outputs on failure and the time limit. They do not start Tailscale and do not
log in to OSPO Vault. The `userspace-live` and `fails-vault-denied-userspace`
jobs do that on a GitHub-hosted runner with the test role, after an approval
of the `vault-action-test` environment. Also test on the target runner.

## Outputs

| Output | Meaning |
|---|---|
| `token` | The GitHub token from `github-token`. Empty if `github-token` is not set. |
| `secrets` | JSON object with one key per `<NAME>` in `secrets`. Read a value with `fromJSON(steps.<id>.outputs.secrets).<NAME>`. |
| `failed-step` | The step of the action that failed: `prepare` (input and job checks), `join` (Tailscale join), `wait` (Vault not reachable), `vault` (Vault login or read, also when it took longer than `vault-timeout-seconds`), `check` (empty value). Empty when the action succeeds. Use it with `continue-on-error: true`. |

When `github-token` is set, `secrets` also has the key
`VAULT_SECRETS_GITHUB_TOKEN` (the same value as `token`). Do not use that name
as an output name in `secrets`; the action refuses it. This applies to the
name after `|` (in any case), and to the name that hashicorp/vault-action makes
from the field when a line has no `| <NAME>`. A path that only contains the
text is accepted.

When the action fails, `token` is empty and `secrets` is `{}`.
When the step is skipped (an `if:` that is false), both outputs are empty.
`fromJSON('')` is an error. For a login that is optional, read a value with
`fromJSON(steps.<id>.outputs.secrets || '{}').<NAME>`.

`github-token` gets one token. To get more than one token in one call, put
one line for each token in `secrets`, for example
`github/token/<name> token | TOKEN_A ;`.
In `secrets`, end each line except the last with `;`.

All values are masked in the log. hashicorp/vault-action registers a mask for
each value (and for each line of a multi-line value). The runner masks a value
everywhere in the job log, also when it comes through a composite output, a
JSON string or `fromJSON`. Do not print values anyway.

## Time limit

The Vault login and the GitHub token last at most 15 minutes. Call the action
just before the step that needs the values. For a longer job, call it again
later in the job.

Each request of the Vault login (OIDC token, login) stops after 15 seconds.
The OIDC token request is tried up to 3 times (about 50 seconds in the worst
case). The Vault login is one request with no retry.
The Vault read stops after `vault-timeout-seconds` (default 120).
Without this limit, one stalled network connection can hold the step for
about 16 minutes. A composite action step cannot have `timeout-minutes`, so
the action uses a background process for the limit. It needs `pgrep`. If
`pgrep` is not on the runner, the action writes a warning and runs without the
limit.

When the limit found the Vault step, the log shows `The time limit watched the
Vault step.` If it did not find the step, the action writes a warning and the
Vault step runs without the limit. The action does not fail in that case.

Also set `timeout-minutes` on the job (for example `timeout-minutes: 30`), so
that a stalled step in any part of the job cannot hold the runner for hours.

## Call it two times in one job

Give each call its own `id`. The second call sees that the runner is already
on the tailnet and does not join again (`join-tailnet: auto`).

```yaml
      - id: vault
        uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha>
        with:
          github-token: lib-read

      - id: vault_kv
        uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha>
        with:
          role: deploy
          secrets: |
            kv/data/_roles/tenstorrent--example-app--deploy/api key | API_KEY
```

A job that already joined the tailnet in another way (for example with
`tag:tt-github-actions-public-internet-outbound`) can also reach Vault. With
`auto`, the action does not join again. Do not join the tailnet two times in
one job.

## Failures

| Message | Cause | Action |
|---|---|---|
| `job needs permissions: id-token: write (not available on fork pull requests)` | The job has no OIDC token. | Add `id-token: write` to the job permissions. Fork pull requests never get it. |
| `this runner has no curl` / `no jq` | A self-hosted runner without these tools. | Install bash, curl and jq on the runner. |
| `refused on pull_request_target` | The workflow runs on `pull_request_target`. | Use another event. Vault never accepts this event. |
| `Vault gave an empty value for <NAME>` | The value stored in Vault is an empty string. | Ask the owner of the secret to store it again. |
| `nothing to get` | `github-token` and `secrets` are both empty. | Set one or both. |
| `input role has characters ...` / `input role '...' is not a role of <repo>` | `role` is not valid, or it is a role of another repository. | Use the short name of your workflow entry, or leave `role` empty for the default role. |
| `This repository has no default Vault role` | `role` is empty, and every workflow entry in the grant has a name. | Set `role` to the name of your entry, for example `role: nightly`. |
| `Vault has no role ...` | Wrong `role`, or the grant is not applied yet. | Check the name of the workflow entry in your grant file. |
| `This run does not match role ...: Vault refused claim ...` | The run does not match the role: wrong branch, wrong `environment:`, wrong workflow file, or an event the role does not allow. The message shows the facts of the run. | Run from the bound ref, environment or workflow file, or ask OSPO to change the grant. |
| `Vault refused the login: too many logins (rate limit)` | Too many logins in a short time. | Run the job again in a minute. |
| `Vault did not answer the login within 15 seconds` | A stalled network connection. | Run the job again. |
| `input github-token is not a valid token name or path` | Bad characters in `github-token`. | Use the key of the token only, for example `lib-read`. |
| `input github-token '...' is not a token of <repo>` | `github-token` is the name of a token of another repository. A role gets only tokens of its own repository. | Use the key of a token in your grant. |
| `Role ... has no grant for GitHub token set ...` | Vault refused the token set in every place where a token can be. The role has no grant for it, the key is wrong, or the grant is not applied yet. | Check the key in `github_tokens` of your workflow entry in your grant. |
| `Vault did not answer the read of GitHub token set ...` / `Vault refused the read of GitHub token set ...` | A stalled network connection, or a Vault error other than "permission denied". | Run the job again. If it occurs again, report it to OSPO. |
| `input vault-url is not an OSPO Vault URL` | `vault-url` is not the production or staging URL of OSPO Vault. The action sends the OIDC token of the job to this URL, so no other host is allowed. | Remove `vault-url` to use the default. |
| `input join-tailnet must be auto, true or false` | Wrong value. | Use `auto`, `true` or `false`. |
| `input network-mode must be kernel or userspace` | Wrong value (release 1.2). | Use `kernel` or `userspace`, in lower case, or remove the input. |
| `input network-mode userspace needs a Linux runner` | `userspace` on a macOS or Windows runner. | Remove `network-mode`. |
| `input proxy-port must be a whole number from 1 to 65535` | Wrong value in `userspace` mode. | Use a free port, or remove the input to use 1055. |
| `no Tailscale HTTP proxy answers on 127.0.0.1:<port>` | `userspace` mode without a join (`join-tailnet: false`, or `auto` on a runner already on the tailnet), and nothing listens on `proxy-port`. | See [Linux runner pods without TUN](#linux-runner-pods-without-tun-release-12). |
| `vault-secrets userspace mode requires Node 24.5 or newer` (read step) | The Actions runner runs actions with an older Node. | Update the runner. |
| `Vault ... is not reachable` | The runner is not on the tailnet, the join failed, the tag has no route to Vault, or the URL is wrong. | Read the "Join tailnet" step log. Use `join-tailnet: auto`. |
| `Vault did not answer within N seconds` | The Vault step took longer than `vault-timeout-seconds`. The likely cause is a stalled network connection on the tailnet. | Run the job again. If it occurs again, report it to OSPO. |
| `input vault-timeout-seconds must be a whole number from 10 to 600` | Wrong value. | Use a number from 10 to 600, or remove the input to use 120. |
| Vault: `permission denied` (403) on a `.../token/...` path | Only with a full path in `github-token` or `secrets`. The role may not mint that token, or the path is wrong. | Use `github-token: <key>`, or check `github_tokens` in your grant. |
| Vault: `permission denied` (403) or not found on a `kv/...` path, or field missing | Wrong path or field, or no read access. | Check the path (`kv/data/...`) and the field name. |

## Security notes

- Inputs reach the shell only through `env:`.
- The action does not export values to the job environment (`exportEnv: false`).
- Third-party actions are pinned by commit SHA.
- The action logs in with curl (`login.sh`). It masks the OIDC token and the
  Vault token before it prints anything, and never puts them in a command
  line. The Vault token goes to the read step as a step output inside the
  action. No output of the action has it.
- For `github-token` without `/`, the action reads the token with curl
  (`read-token.sh`). It asks the token engines in a fixed order, least
  privilege first, and stops at the first token. It masks the token at once and
  never reads it a second time. Each refused try is a `permission denied`
  entry in the Vault audit log. The role needs no access that it does not
  already have.
- Pin this action by full commit SHA from `main` of `tenstorrent/.github`.
  Check that the commit is on `main`: GitHub also resolves a SHA from a fork.

## Security of the test workflow

The workflow `.github/workflows/vault-secrets-test.yml` tests this action from
the pull request checkout. Its Vault jobs log in with the test role
`tenstorrent--.github--vault-action-test`. They run only when the repository
variable `VAULT_SECRETS_TEST_ENABLED` is `true`.

What a pull request can reach:

- A pull request from a branch in this repository can change the action, the
  test scripts and the workflow. Its Vault jobs then run that changed code with
  `id-token: write`, so the code can read what the test role can read.
- A check in the workflow cannot stop this. The pull request can change the
  check too.
- A pull request from a fork gets no OIDC token. It cannot log in to Vault.

Why the risk is low:

- The test role can get one token with read access to contents and metadata
  of this public repository, and one dummy KV value. These give no more access
  than the public repository already gives.
- The test role must never get a token with write access, a token for another
  repository, or a real secret. Add new test values to the test role only.

Required protection (a repository setting, applied by a maintainer):

- The environment `vault-action-test` has required reviewers, with "Prevent
  self-review" on. A person reads the diff of the pull request and approves the
  deployment before a Vault job starts.
- The Vault role accepts only the environment `vault-action-test`. A job
  without the environment cannot log in with the test role.

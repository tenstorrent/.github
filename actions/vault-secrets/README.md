# vault-secrets

Gets an ephemeral GitHub token and secrets from OSPO Vault in one step.

The action does these steps:

1. It checks the job and the inputs.
2. It joins the tailnet, if the runner is not on it yet.
3. It waits until Vault answers.
4. It logs in to Vault with the job's GitHub OIDC token and reads the values.

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

Pin the action to a full commit SHA. The current release commit is `30f687a815f9e78fd8c7460e6c20d29de7f28477`. Check that a commit is on `main` with `gh api repos/tenstorrent/.github/compare/main...<sha> --jq .status`. The status `identical` or `behind` means yes.

```yaml
      - id: vault
        uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha> # <date or tag>
        with:
          role: tenstorrent--example-app
          github-token: tenstorrent--example-app--lib-read
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

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `role` | yes | | Vault role of the workflow: `<org>--<repo>`, or `<org>--<repo>--<name>` for a named workflow entry. |
| `github-token` | no | | Token name. A bare name reads `github/token/<name>`. A value with `/` is the full path, for example `github-members/token/<name>`. |
| `secrets` | no | | Secrets in [hashicorp/vault-action](https://github.com/hashicorp/vault-action) `secrets` syntax: `<path> <field> \| <NAME> ;` per line. |
| `vault-url` | no | `https://vault-ospo.eng-svc.aws.tenstorrent.com` | Vault URL. Only the OSPO Vault production URL (default) and the staging URL are allowed. The JWT audience is always this URL. |
| `join-tailnet` | no | `auto` | `auto` joins unless the runner is already on the tailnet. `true` always joins. `false` never joins. |
| `tailscale-client-id` | no | value of org variable `TS_VAULT_OSPO_CLIENT_ID` | Tailscale OAuth client ID. Not a secret. |
| `tailscale-audience` | no | value of org variable `TS_VAULT_OSPO_AUDIENCE` | Tailscale OIDC audience. Not a secret. |
| `tailscale-tags` | no | `tag:tt-gha-vault-ospo` | Tags of the runner node. |
| `vault-timeout-seconds` | no | `120` | Time limit of the Vault login and read, in seconds (10 to 600). After this time the action stops the Vault step and fails. |

Set `github-token`, `secrets`, or both. If both are empty, the action fails.

The two Tailscale defaults are the values of the org variables. They are the
same in all six orgs. A composite action cannot read `vars`, so the action
holds a copy. If an org variable changes, pass the new value:

```yaml
          tailscale-client-id: ${{ vars.TS_VAULT_OSPO_CLIENT_ID }}
          tailscale-audience: ${{ vars.TS_VAULT_OSPO_AUDIENCE }}
```

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

The Vault login and read stop after `vault-timeout-seconds` (default 120).
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
          role: tenstorrent--example-app
          github-token: tenstorrent--example-app--lib-read

      - id: vault_kv
        uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha>
        with:
          role: tenstorrent--example-app--deploy
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
| `refused on pull_request_target` | The workflow runs on `pull_request_target`. | Use another event. Vault never accepts this event. |
| `Vault gave an empty value for <NAME>` | The value stored in Vault is an empty string. | Ask the owner of the secret to store it again. |
| `nothing to get` | `github-token` and `secrets` are both empty. | Set one or both. |
| `input role is empty` / `... characters ...` | `role` is missing or not valid. | Set the role name from your grant. |
| `input github-token is not a valid token name or path` | Bad characters in `github-token`. | Use the token name only, without `token` or `\|`. |
| `input vault-url is not an OSPO Vault URL` | `vault-url` is not the production or staging URL of OSPO Vault. The action sends the OIDC token of the job to this URL, so no other host is allowed. | Remove `vault-url` to use the default. |
| `input join-tailnet must be auto, true or false` | Wrong value. | Use `auto`, `true` or `false`. |
| `Vault ... is not reachable` | The runner is not on the tailnet, the join failed, the tag has no route to Vault, or the URL is wrong. | Read the "Join tailnet" step log. Use `join-tailnet: auto`. |
| `Vault did not answer within N seconds` | The Vault step took longer than `vault-timeout-seconds`. The likely cause is a stalled network connection on the tailnet. | Run the job again. If it occurs again, report it to OSPO. |
| `input vault-timeout-seconds must be a whole number from 10 to 600` | Wrong value. | Use a number from 10 to 600, or remove the input to use 120. |
| Vault: `role "..." could not be found` | Wrong `role`, or the grant is not applied. | Check the role name in your grant file. |
| Vault: `error validating claims` / `claim ... does not match` | The run does not match the role: wrong branch, wrong `environment:`, or an event the role does not allow. | Run from the bound ref or environment, or ask OSPO to change the grant. |
| Vault: `permission denied` (403) on a `github/token/...` path | The role may not mint that token, or the name is wrong. | Check `github_tokens` in your grant. |
| Vault: `permission denied` (403) or not found on a `kv/...` path, or field missing | Wrong path or field, or no read access. | Check the path (`kv/data/...`) and the field name. |

## Security notes

- Inputs reach the shell only through `env:`.
- The action does not export values to the job environment (`exportEnv: false`).
- Third-party actions are pinned by commit SHA.
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

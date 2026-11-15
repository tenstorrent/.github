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

Pin the action to a full commit SHA:

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
| `vault-url` | no | `https://vault-ospo.eng-svc.aws.tenstorrent.com` | Vault URL. The JWT audience is always this URL. |
| `join-tailnet` | no | `auto` | `auto` joins unless the runner is already on the tailnet. `true` always joins. `false` never joins. |
| `tailscale-client-id` | no | value of org variable `TS_VAULT_OSPO_CLIENT_ID` | Tailscale OAuth client ID. Not a secret. |
| `tailscale-audience` | no | value of org variable `TS_VAULT_OSPO_AUDIENCE` | Tailscale OIDC audience. Not a secret. |
| `tailscale-tags` | no | `tag:tt-gha-vault-ospo` | Tags of the runner node. |

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

When `github-token` is set, `secrets` also has the key
`VAULT_SECRETS_GITHUB_TOKEN` (the same value as `token`). Do not use that name
in `secrets`; the action refuses it.

When the action fails, `token` is empty and `secrets` is `{}`.

All values are masked in the log. hashicorp/vault-action registers a mask for
each value (and for each line of a multi-line value). The runner masks a value
everywhere in the job log, also when it comes through a composite output, a
JSON string or `fromJSON`. Do not print values anyway.

## Time limit

The Vault login and the GitHub token last at most 15 minutes. Call the action
just before the step that needs the values. For a longer job, call it again
later in the job.

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
| `nothing to get` | `github-token` and `secrets` are both empty. | Set one or both. |
| `input role is empty` / `... characters ...` | `role` is missing or not valid. | Set the role name from your grant. |
| `input github-token is not a valid token name or path` | Bad characters in `github-token`. | Use the token name only, without `token` or `\|`. |
| `input vault-url must be an https:// URL` | `vault-url` is not https. | Fix `vault-url`, or remove it to use the default. |
| `input join-tailnet must be auto, true or false` | Wrong value. | Use `auto`, `true` or `false`. |
| `Vault ... is not reachable` | The runner is not on the tailnet, the join failed, the tag has no route to Vault, or the URL is wrong. | Read the "Join tailnet" step log. Use `join-tailnet: auto`. |
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

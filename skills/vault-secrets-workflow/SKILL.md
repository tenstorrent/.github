---
name: vault-secrets-workflow
description: >-
  Build a NEW GitHub Actions workflow that needs a GitHub token with more
  access than GITHUB_TOKEN, or another secret, from OSPO Vault, with the
  shared action tenstorrent/.github/actions/vault-secrets. Use when a new
  workflow needs a cross-repo token, when a personal access token (PAT) must be
  replaced, when a workflow needs an API key from Vault. Triggers:
  "vault-secrets", "ephemeral GitHub token", "replace PAT", "cross-repo token
  in Actions", "secret from OSPO Vault", "GITHUB_TOKEN is not enough".
  To change an existing workflow, use RETROFIT.md instead.
---

# New workflow with vault-secrets

The action logs in to OSPO Vault with the job's OIDC token. It returns a
short-lived GitHub token and/or secrets. Read the
[action README](../../actions/vault-secrets/README.md) for inputs and outputs.
To change an existing workflow, read
[RETROFIT.md](../../actions/vault-secrets/RETROFIT.md).

## 1. Settle these questions first

Ask the developer. Do not guess.

1. Which repository holds the workflow?
2. Which branches or which environment run it?
3. Which events start it (push, schedule, manual, tag, pull request)?
4. Which repositories must the token reach? Which permissions on each
   (for example `contents: read`)?
5. Which other secrets does it need (API keys, passwords)?

## 2. Get the names from OSPO

OSPO sets up the Vault side. The developer asks in an OSPO ticket and gives the
answers from section 1. OSPO replies with:

- the role name
- the GitHub token name
- the secret paths and field names

Do not invent these names. Use placeholders (`<role>`, `<token-name>`,
`<secret-path>`, `<field>`) until the ticket gives the real values. Do not
change a name that OSPO gave.

## 3. Workflow template

```yaml
name: Example
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - id: vault
        uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha> # <date or tag>
        with:
          role: <role>
          github-token: <token-name>
          secrets: |
            <secret-path> <field> | API_KEY

      - name: Check out the other repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: <org>/<other-repo>
          token: ${{ steps.vault.outputs.token }}
          path: other
          persist-credentials: false

      - name: Use the secret
        env:
          API_KEY: ${{ fromJSON(steps.vault.outputs.secrets).API_KEY }}
        run: ./other/tools/call-service.sh
```

Pin the action by the full SHA of a commit on `main` of `tenstorrent/.github`.
The current release is `vault-secrets-v1.0.0`, commit `a697f1bb22ad8b488b0ac63f9a261e462179fe13`. Check that a commit is on `main` with `gh api repos/tenstorrent/.github/compare/main...<sha> --jq .status`. The status `identical` or `behind` means yes.
Remove `secrets:` if there is no other secret. Remove `github-token:` if there
is no token.

## 4. Which events can log in

The role in the grant decides. The claims of the run must match it.

| Event | Login | Note |
|---|---|---|
| `push` to a named branch | Yes | The role binds to that branch. |
| `workflow_dispatch` from a named branch | Yes | Run it from the bound branch. |
| `schedule` | Yes | Runs on the default branch. |
| Tag push or release | Needs an environment | Add `environment:` to the job. |
| `pull_request` from the same repository | Needs an environment | Add `environment:`. |
| `pull_request` from a fork | No | A fork gets no OIDC token. |
| `pull_request_target` | Never | The action refuses it. |
| Publish or deploy job | Protected environment | Set required reviewers on the environment. |

## 5. Rules

1. Keep `permissions: id-token: write` at job level. List the other
   permissions the job needs.
2. Pin the action by full commit SHA that is on `main`.
3. Put values in step-level `env:` only. Never put
   `${{ steps.<id>.outputs.* }}` in `run:` text.
4. Never print a value.
5. Do not add `continue-on-error`, except for a login that is optional by
   design. Then use `fromJSON(steps.<id>.outputs.secrets || '{}').<NAME>`.
6. Use `persist-credentials: false` on checkout steps. Do not leave the token in
   `.git/config`.
7. Call the action just before the step that needs the values. The login and
   the token last at most 15 minutes.
8. A job can call the action two times. Give each call its own `id`. The second
   call does not join the tailnet again.
9. Do not set `join-tailnet` or the Tailscale inputs unless OSPO asks.
10. The action stops a Vault step that does not answer within 120 seconds
    (`vault-timeout-seconds`) and fails. Run the job again. The limit needs
    `pgrep` on the runner. GitHub-hosted Linux runners have it. Without `pgrep`,
    the action writes a warning and the Vault step has no limit. For such a
    runner, also set `timeout-minutes` on the job.
11. Do not set `vault-url`. Only OSPO Vault URLs are allowed.
12. The output `failed-step` names the step that failed. Use it with
    `continue-on-error: true` for an optional login.

## 6. Common failures

The README lists every message in
[Failures](../../actions/vault-secrets/README.md#failures). The usual ones:

| Message | Cause | See README |
|---|---|---|
| `job needs permissions: id-token: write` | No `id-token: write`, or a fork pull request. | Failures |
| `refused on pull_request_target` | Wrong event. | Failures |
| `role "..." could not be found` | Wrong role, or the grant is not applied. | Failures |
| `error validating claims` | Wrong branch, environment or event. | Failures |
| `permission denied` on a token or `kv` path | Wrong name or path, or no access. | Failures |
| `Vault ... is not reachable` | Runner not on the tailnet. | Failures |
| `Vault did not answer within N seconds` | The Vault step took longer than the time limit. | Failures |
| `input vault-url is not an OSPO Vault URL` | `vault-url` is set. Remove it. | Failures |

For a role, claim or permission error, ask OSPO in the ticket. Do not change
names to try other values.

## 7. Final checklist

- [ ] Questions in section 1 answered
- [ ] OSPO ticket gave the role, token name and secret paths
- [ ] No placeholder left in the workflow
- [ ] Action pinned by full commit SHA on `main`
- [ ] `id-token: write` and the other permissions set at job level
- [ ] Values only in step-level `env:`
- [ ] No value printed
- [ ] `actionlint` passes
- [ ] First run is on a ref and event the role allows
- [ ] Log checked: no value visible

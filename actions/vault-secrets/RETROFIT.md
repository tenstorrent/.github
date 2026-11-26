# Retrofit a workflow to vault-secrets

This document is for a coding agent. It tells you how to change an existing
workflow from the copied steps (Tailscale join, Vault wait, `hashicorp/vault-action`)
to the `vault-secrets` action. Read [README.md](README.md) for the action itself.

A retrofit changes how the workflow gets its values. It does not change which
values it gets.

## 1. Find the candidates

Run these commands in the repository root:

```bash
grep -rn "hashicorp/vault-action" .github/
grep -rn "tailscale/github-action" .github/
grep -rn "VAULT_URL" .github/
```

Each file that matches is a candidate. Open each one and read the full job.
Stop and go to section 4 if the job is on the list there.

## 2. Map old to new

The current release is `vault-secrets-v1.1.0`. Pin its release tag:
`@vault-secrets-v1.1.0`. The section [Releases](README.md#releases) of the
README tells why this is safe.

| Old | New |
|---|---|
| Step `Join tailnet` (`tailscale/github-action`) | Removed. The action joins when needed. |
| Step `Wait for Vault` (curl loop) | Removed. The action waits. |
| Step with `hashicorp/vault-action` | One step with `uses: tenstorrent/.github/actions/vault-secrets@vault-secrets-v1.1.0`. |
| `role: <org>--<repo>` (the default role) | Remove `role`. The action uses the default role of the repository that runs the workflow. `role: <org>--<repo>` still works. |
| `role: <org>--<repo>--<name>` | `role: <name>` (the short name). The full name still works. Do not change the role itself. |
| `url`, `method`, `path`, `jwtGithubAudience` | Removed. The action sets them. |
| `exportEnv: false`, `exportToken: false`, `outputToken: false` | Removed. The action always sets these values. |
| No `exportEnv`, or `exportEnv: true` | Removed, but do step 2a first. vault-action exports by default; the action does not. |
| Any other `hashicorp/vault-action` input | Stop. See section 4. |
| `github/token/<org>--<repo>--<key> token \| GH_TOKEN` | `github-token: <key>` (the part after `<org>--<repo>--`). Read it with `steps.<id>.outputs.token`. The full name and the full path still work, but use the key. |
| Other lines in `secrets` | Same lines in the `secrets:` input. Read them with `fromJSON(steps.<id>.outputs.secrets).<NAME>`. |
| Token on another mount, for example `github-members/token/<org>--<repo>--<key> token \| NAME` | One token: `github-token: <key>`. The action finds the mount. More than one token: keep each as a line in `secrets:`. |
| `steps.<id>.outputs.<NAME>` | `fromJSON(steps.<id>.outputs.secrets).<NAME>`. Use `steps.<id>.outputs.token` for the `github-token` value. |

Keep the `;` at the end of each `secrets` line except the last. A `;` after the last line is optional.
vault-action splits entries on `;`, not on lines. Without the `;`, two lines
become one bad entry and the step fails.

### 2a. Values in the job environment

vault-action has `exportEnv: true` as its default. The action always sets
`exportEnv: false`. If the old step has no `exportEnv`, or has
`exportEnv: true`, later steps can read each value as a shell variable
(`$NAME`) or as `${{ env.NAME }}`. After the retrofit these values are empty,
and the step does not always fail.

Do these steps before you remove the old step:

1. For each entry in `secrets`, write down two names. They can be different.
   - The output key. With `| NAME`, it is `NAME`. Without `| NAME`, it is
     made from the selector: each `.` becomes `__`, and each `-` and each
     other character that is not a letter, a digit or `_` is removed. The
     case does not change. Example: `api_key`.
   - The exported name, which is the environment variable. With `| NAME`,
     it is `NAME`. Without `| NAME`, it is the output key in upper case.
     Example: `API_KEY`.
2. In each later step of the same job, find each use of an exported name:
   `$API_KEY`, `${API_KEY}`, `${{ env.API_KEY }}`, and use by a script or a
   tool that reads the environment. Read the scripts that the steps call.
3. For each step that uses an exported name, add it to the step-level `env:`
   of that step. The left side is the exported name. The right side reads
   the output key:
   `API_KEY: ${{ fromJSON(steps.<id>.outputs.secrets).api_key }}`, or
   `NAME: ${{ steps.<id>.outputs.token }}` for the `github-token` value.
4. If you cannot find all uses (for example, a tool reads an unknown
   variable), stop and ask a human.

### Before

```yaml
steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

  - name: Join tailnet
    uses: tailscale/github-action@064b10558093f38325e838ddea35486bdc6b1d5c # v4.4.0
    with:
      oauth-client-id: ${{ vars.TS_VAULT_OSPO_CLIENT_ID }}
      audience: ${{ vars.TS_VAULT_OSPO_AUDIENCE }}
      tags: tag:tt-gha-vault-ospo

  - name: Wait for Vault
    run: |
      for attempt in 1 2 3 4 5 6; do
        curl -fsS --max-time 5 "${VAULT_URL}/v1/sys/health?standbyok=true&uninitcode=204&sealedcode=204" >/dev/null && exit 0
        sleep 2
      done
      echo "Vault ${VAULT_URL} did not become reachable" >&2
      exit 1

  - name: Get secrets
    id: vault
    uses: hashicorp/vault-action@892a26828f195e65540a40b4768ae4571f51ebfc # v4.0.0
    with:
      url: ${{ env.VAULT_URL }}
      method: jwt
      path: jwt-github
      role: example-org--example-app
      jwtGithubAudience: ${{ env.VAULT_URL }}
      exportEnv: false
      secrets: |
        github/token/example-org--example-app--lib-read token | GH_TOKEN ;
        kv/data/example-org/example-app/upload api_key | UPLOAD_API_KEY

  - name: Upload
    env:
      GH_TOKEN: ${{ steps.vault.outputs.GH_TOKEN }}
      UPLOAD_API_KEY: ${{ steps.vault.outputs.UPLOAD_API_KEY }}
    run: ./upload.sh
```

### After

```yaml
steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

  - name: Get secrets
    id: vault
    uses: tenstorrent/.github/actions/vault-secrets@vault-secrets-v1.1.0
    with:
      github-token: lib-read
      secrets: |
        kv/data/example-org/example-app/upload api_key | UPLOAD_API_KEY

  - name: Upload
    env:
      GH_TOKEN: ${{ steps.vault.outputs.token }}
      UPLOAD_API_KEY: ${{ fromJSON(steps.vault.outputs.secrets).UPLOAD_API_KEY }}
    run: ./upload.sh
```

The old role `example-org--example-app` is the default role of the
repository, so the new step has no `role`.

### Tokens on another mount

For one token, use `github-token: <key>`: the action finds the mount. For more
than one token, use `secrets` with full paths. A token path with `/` is a full
path. The action does not add `github/token/`.

```yaml
steps:
  - id: vault
    uses: tenstorrent/.github/actions/vault-secrets@vault-secrets-v1.1.0
    with:
      role: nightly
      secrets: |
        github-members/token/example-org--example-app--read-a token | TOKEN_A ;
        github-members/token/example-org--example-app--read-b token | TOKEN_B

  - name: Read both
    env:
      TOKEN_A: ${{ fromJSON(steps.vault.outputs.secrets).TOKEN_A }}
      TOKEN_B: ${{ fromJSON(steps.vault.outputs.secrets).TOKEN_B }}
    run: ./read-both.sh
```

## 3. Rules

1. Keep `permissions: id-token: write` at job level. List the other
   permissions the job needs. A job-level `permissions` block replaces the
   workflow-level block.
2. Pin the action by its release tag, for example `@vault-secrets-v1.1.0`.
   Releases of this repository are immutable: a release tag cannot be moved or
   deleted. Do not pin a branch such as `@main`. A workflow that already pins
   the commit of a release still works and does not need a change.
3. Put values in step-level `env:` only. Do not put
   `${{ steps.<id>.outputs.* }}` in `run:` text. Do not use job-level or
   workflow-level `env:` for values.
4. Do not add `continue-on-error`. Add it only for a login that is optional by
   design. Then guard `fromJSON` against an empty output:

   ```yaml
   env:
     OPTIONAL: ${{ fromJSON(steps.vault_opt.outputs.secrets || '{}').OPTIONAL_VALUE }}
   ```

   A skipped step has an empty `secrets` output. `fromJSON('')` fails. The
   guard gives an empty value instead.
5. A job that is already on the tailnet needs nothing extra. The default
   `join-tailnet: auto` does not join a second time.
6. A second login in one job: give each call its own `id`. Use the role of the
   second login. Example:

   ```yaml
   steps:
     - id: vault
       uses: tenstorrent/.github/actions/vault-secrets@vault-secrets-v1.1.0
       with:
         github-token: lib-read

     - id: vault_deploy
       uses: tenstorrent/.github/actions/vault-secrets@vault-secrets-v1.1.0
       with:
         role: deploy
         secrets: |
           kv/data/_roles/example-org--example-app--deploy/api key | API_KEY
   ```

7. The Vault login and the token last at most 15 minutes. Put the action
   directly before the first step that needs a value. For a longer job, call it
   again later.
8. Remove the job-level or workflow-level `VAULT_URL` when nothing else uses it.
   Search the file first: `grep -n VAULT_URL <file>`.
9. Do not change the role name, the token names, or the secret paths. OSPO sets
   them in the grant (see the OSPO ticket). If a name looks wrong, ask OSPO.
   These changes of form are not a change of name:
   - `github-token` takes the token key, the part of the token name after
     `<org>--<repo>--`.
   - You may remove `role` for the default role `<org>--<repo>`, or write a
     named role as its short name (the part after `<org>--<repo>--`). Keep
     the full role name when you are not sure.
10. Never print a value. Do not use `echo`, `set -x`, or debug output on a
    value. Print lengths or key names only.

## 4. Do not convert: ask a human

Stop. Do not change the workflow. Tell the human why, and ask OSPO.

- The workflow uses `pull_request_target`. The action refuses it, and Vault
  never accepts it.
- The workflow runs on fork pull requests. Fork pull requests get no OIDC
  token.
- The job runs on a self-hosted runner. The runner may already have its own
  network path to Vault. Ask the runner owner which connection to use: the
  default `network-mode: kernel` for a runner with a route, or
  `network-mode: userspace` (release 1.2 and later) for a Linux pod without
  TUN or NET_ADMIN. `join-tailnet: false` uses a route or proxy that the runner
  already has; `auto` uses an active connection or joins. For userspace, the
  runner must run actions with Node 24.5 or newer. When the action does not
  join (`join-tailnet: false`, or `auto` on a runner already on the tailnet),
  `proxy-port` must match a Tailscale HTTP proxy that already runs, else the
  action stops at once; when the action joins, it starts the proxy on
  `proxy-port` itself. Read the README section "Linux runner pods without TUN" before you
  replace inline userspace or curl blocks.
- The job sets its own tailnet tags (for example, it joins with a different
  tag for other access). A second join can break the first.
- The old `hashicorp/vault-action` step uses an input that the action does not
  support. The action supports only `role` and `secrets` from vault-action,
  and sets `url`, `method`, `path`, `jwtGithubAudience`, `exportEnv`,
  `exportToken` and `outputToken` itself. Examples of inputs to stop on:
  `ignoreNotFound`, `outputToken: true`, `exportToken: true`, `namespace`,
  `extraHeaders`, `tlsSkipVerify`, `caCertificate`, `clientCertificate`,
  `clientKey`, `secretEncodingType`, `pki`, `jwtTtl`, `jwtPrivateKey`,
  `jwtKeyPassword`, and other login methods (`method` other than `jwt`, or
  `token`, `roleId`, `secretId`, `githubToken`, `kubernetesTokenPath`,
  `username`, `password`, `authPayload`).

## 5. Check the result

Complete each item before you open the pull request.

- [ ] Run `actionlint` on each changed file. It must report no error.
- [ ] Search for old references. Run
      `grep -n "steps\.<id>\.outputs\." <file>` for each Vault step `id`.
      Each result must be `outputs.token` or `outputs.secrets`.
- [ ] If the old step exported values (section 2a): search for each
      exported name (not the output key), for example
      `grep -n "API_KEY" <file>`. Each use must read the value from
      step-level `env:`.
- [ ] Search for the removed steps: `grep -n "tailscale/github-action\|hashicorp/vault-action\|VAULT_URL" <file>`.
      The result must be empty, unless a step is out of scope (section 4).
- [ ] Run the workflow on a ref that the Vault role allows (branch,
      environment, event). A run on another ref fails with a claim error. That
      is correct.
- [ ] Compare with the last good run: the same steps pass, the same files are
      written, the same calls succeed.
- [ ] Check the log. No value is visible.

Use this checklist in the pull request description:

```markdown
## vault-secrets retrofit

- [ ] Copied Tailscale, wait and `vault-action` steps replaced by one `vault-secrets` step
- [ ] Action pinned by its release tag (`@vault-secrets-vX.Y.Z`), not a branch
- [ ] `permissions: id-token: write` kept at job level; other permissions listed
- [ ] Role, token names and secret paths unchanged
- [ ] Values only in step-level `env:`
- [ ] Each use of a value that `exportEnv` put in the job environment is now mapped in step-level `env:`
- [ ] No leftover `steps.<id>.outputs.<NAME>` references
- [ ] Job-level `VAULT_URL` removed when unused
- [ ] Job has `timeout-minutes` (for example 30)
- [ ] `actionlint` passes
- [ ] Run on the permitted ref passes and behaves as before
- [ ] No value in the log
```

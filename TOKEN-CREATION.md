# Using Octo STS from your repository

A guide for repository owners at Tenstorrent who want their GitHub
Actions workflows to interact with **other** repos (or org-level
resources) without storing a long-lived PAT or GitHub App key.

## What this is

The `tenstorrent` org runs an Octo STS service. A workflow in your
repo can exchange its built-in OIDC identity for a short-lived
(1 hour) GitHub token with a tightly scoped set of permissions.
You don't manage any secrets — the token is minted on demand, used,
and discarded.

What you can do as a repo owner:

* Add an `octo-sts/action` step to your workflows.
* Request a new permission grant by opening a PR or issue against
  `tenstorrent/.github`.

What you can't do (this is on purpose):

* Edit the ACL yourself. All grants live in
  `tenstorrent/.github/.github/chainguard/`, which is admin-managed
  with branch protection. That repo is the audit trail.

---

## The basic pattern

```yaml
name: example-using-octo-sts

on:
  workflow_dispatch:

permissions:
  id-token: write    # required: lets the runner mint an OIDC token
  contents: read     # for actions/checkout of THIS repo

jobs:
  do-the-thing:
    runs-on: ubuntu-latest
    steps:
      - uses: octo-sts/action@v1.1.1
        id: octo-sts
        with:
          scope: tenstorrent
          identity: <your-policy-name>

      - env:
          GH_TOKEN: ${{ steps.octo-sts.outputs.token }}
        run: |
          gh api /repos/tenstorrent/some-other-repo/contents/README.md
```

Three things to know:

* `scope` is always `tenstorrent` — that tells Octo STS to look in
  the org-level `.github` repo for the trust policy.
* `identity` is the trust policy filename without the `.sts.yaml`
  suffix. You'll be told what value to use when your grant is
  approved.
* `${{ steps.octo-sts.outputs.token }}` is the resulting token,
  valid for 1 hour. Use it directly in `env:` or in step `with:`
  blocks — don't write it to disk or environment files.

---

## Requesting a new grant

Open a PR or issue against
[`tenstorrent/.github`](https://github.com/tenstorrent/.github) with
the following information. The admin team will write the trust
policy file based on it.

1. **Consumer.** The full path to the workflow file that will be
   requesting tokens. Example:
   `tenstorrent/tt-blaze/.github/workflows/release.yml`
2. **Trigger(s).** How the workflow runs — `push` to main,
   `pull_request`, `workflow_dispatch`, `workflow_call`, scheduled,
   etc. This determines what gets locked down in the policy.
3. **Target(s).** What the token needs to act on. Either:
   * a specific repo or list of repos
     (e.g. `tenstorrent/craq-sim`), or
   * an org-level resource (e.g. team management, org projects).
4. **Permissions.** The smallest set of GitHub App permissions that
   does the job. See the reference table below if you're not sure.
5. **What the workflow does.** One or two sentences — enough for
   the admin reviewer to sanity-check that the requested permission
   set actually matches the use case.

The identity name follows the convention
`<consumer-repo>-<target-or-purpose>-<perm>` — e.g.
`tt-blaze-craq-sim-read`, `internal-requests-create-teams-write`.

---

## Common patterns

**Read another private repo:**

```yaml
- uses: octo-sts/action@v1.1.1
  id: octo-sts
  with:
    scope: tenstorrent
    identity: <your-identity>-read

- env:
    GH_TOKEN: ${{ steps.octo-sts.outputs.token }}
  run: |
    gh api /repos/tenstorrent/other-repo/contents/path/to/file
```

**Clone another repo into the runner:**

```yaml
- env:
    GH_TOKEN: ${{ steps.octo-sts.outputs.token }}
  run: |
    git clone https://x-access-token:${GH_TOKEN}@github.com/tenstorrent/other-repo.git
```

**Use the token with `actions/checkout` (cleanest if you just need
the source tree of another repo):**

```yaml
- uses: actions/checkout@v4
  with:
    repository: tenstorrent/other-repo
    token: ${{ steps.octo-sts.outputs.token }}
    path: other-repo
```

**Open an issue or PR in another repo:**

```yaml
- env:
    GH_TOKEN: ${{ steps.octo-sts.outputs.token }}
  run: |
    gh issue create \
      --repo tenstorrent/other-repo \
      --title "..." \
      --body  "..."
```

**Pass the token to `gh` or any Octokit-based action:**

```yaml
- uses: some/action@v1
  with:
    github-token: ${{ steps.octo-sts.outputs.token }}
```

---

## Permission reference

A short list of the permissions you're most likely to need. These
go in the trust policy file written by the admin — you don't write
them, but knowing the names helps you make a clean request.

| What you want to do                          | Permission              | Scope |
|----------------------------------------------|--------------------------|-------|
| Read source / clone                          | `contents: read`         | repo  |
| Push commits, create branches                | `contents: write`        | repo  |
| Read repo metadata                           | `metadata: read`         | repo  |
| Open/edit issues                             | `issues: write`          | repo  |
| Open/edit pull requests                      | `pull_requests: write`   | repo  |
| Manage releases, deployments                 | `deployments: write`     | repo  |
| Manage repo settings (incl. team access)     | `administration: write`  | repo  |
| Create/manage org teams, manage membership   | `members: write`         | org   |
| Read org membership                          | `members: read`          | org   |
| Manage org projects                          | `organization_projects: write` | org |
| Read GitHub Actions logs / artifacts         | `actions: read`          | repo  |
| Trigger workflows                            | `actions: write`         | repo  |
| Read/write packages                          | `packages: read/write`   | repo  |

Principle of least privilege applies: ask for read where read works,
and only escalate to write if you actually need to mutate something.

---

## Troubleshooting

**`unable to find trust policy for "<name>"`**  
The `identity` value doesn't match a file in
`tenstorrent/.github/.github/chainguard/`. Check the spelling
(including hyphens and case) against the file the admin landed.

**`could not be authenticated` or 404 from a GitHub API call**  
The token was minted but doesn't grant what you tried to do. Either
the permission set in the trust policy is missing what you need, or
the target repo isn't in the policy's `repositories:` list. Open a
follow-up PR against `tenstorrent/.github` to expand the policy.

**`Resource not accessible by integration`**  
The token has the right permission category but the specific
operation is blocked — often by branch protection. Branch
protection rules apply regardless of token permissions; a token
with `contents: write` still can't push directly to a protected
branch.

**Step succeeded but the token doesn't seem to work**  
The OIDC claims dumped in the `octo-sts/action` log output (the
`OIDC Token Claims` group) show what was actually presented to
Octo STS. Look at `sub` and `job_workflow_ref` and compare against
the policy. For `workflow_call` invocations specifically, `sub`
reflects the calling workflow, not the called one — policies bind
on `job_workflow_ref` for that reason.

**Different workflow in the same repo, same need — does it work?**  
Probably not. Trust policies bind to a specific workflow file via
`job_workflow_ref`. A different workflow file is a different
identity. File a follow-up grant request — usually a quick admin
PR if the permissions are identical.

---

## Don't do this

* **Don't log the token.** `echo "$GH_TOKEN"`, dumping it to
  artifacts, or writing it to `$GITHUB_OUTPUT` exposes it to anyone
  with read access to the run logs.
* **Don't hand the token to untrusted actions.** Pin third-party
  actions by SHA, not by tag, for any step that consumes the token.
* **Don't reuse one identity across workflows to skip filing a PR.**
  The whole point of per-workflow identities is the audit trail.
  Reusing them defeats it.
* **Don't pass the token to `actions/checkout` when you only need
  your own repo** — the default `${{ github.token }}` is correct
  there. Save the Octo STS token for the cross-repo step.

---

## Limitations

* **Tokens last 1 hour.** Long-running jobs that need to outlast
  that should call `octo-sts/action` again to re-mint.
* **No cross-org access.** Octo STS only issues tokens for resources
  in `tenstorrent`.
* **Branch protection still applies.** A `contents: write` token
  can't bypass required reviews, status checks, or signed-commit
  requirements.
* **Tokens cannot trigger downstream workflows.** Actions taken with
  an Octo STS token (like opening a PR or pushing a commit) do not
  trigger other workflows that listen for those events. This is the
  same GitHub-side limitation that applies to `GITHUB_TOKEN`.

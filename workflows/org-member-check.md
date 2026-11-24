# Org member check (reusable workflow)

**File:** `.github/workflows/org-member-check.yml`

## TL;DR

Call this workflow to find out if one GitHub account is a member of the
organization `tenstorrent`. You get `true` or `false`. Your repository needs no
stored token. OSPO sets up an ephemeral token for each calling repository.

## Terminology

| Term | Meaning |
|---|---|
| Caller | The workflow file in your repository that calls this workflow. |
| Release | A tag `org-member-check-vX.Y.Z` of `tenstorrent/.github` with an immutable GitHub release. |
| Member | An account that is a member of `tenstorrent`, public or private. |

## Steps

| Step | What to do |
|---|---|
| 1 | Open a ticket in the OSPO Jira project. Ask for "org member check" for your repository. |
| 2 | Add the calling job to your workflow (see [Usage](#usage)). |
| 3 | Wait until OSPO says on the ticket that the setup is ready. Then run the workflow. |

Put this in the ticket:

- the repository;
- the caller file name, for example `.github/workflows/community-issue-tagging.yml`;
- the branch the workflow runs on (normally the default branch);
- the events that start it, for example `issues`;
- a short reason.

You can also point OSPO to a draft workflow on a branch or in a pull request.

## Usage

```yaml
jobs:
  member:
    permissions:
      id-token: write
    uses: tenstorrent/.github/.github/workflows/org-member-check.yml@<full-commit-sha> # org-member-check-v1.0.0
    secrets:
      user-id: ${{ github.event.issue.user.id }}

  label:
    needs: member
    if: needs.member.outputs.member == 'false'
    runs-on: ubuntu-latest
    permissions:
      issues: write
    steps:
      - run: gh issue edit "$NUMBER" --repo "$GITHUB_REPOSITORY" --add-label community
        env:
          GH_TOKEN: ${{ github.token }}
          NUMBER: ${{ github.event.issue.number }}
```

Rules:

- Pin the full commit SHA of a release. Put the tag in the comment. Do not pin
  a branch or a tag name. OSPO sets up the token for that commit only. To get
  the commit of a release, run
  `gh api repos/tenstorrent/.github/commits/org-member-check-v1.0.0 --jq .sha`.
- The calling job needs `permissions: id-token: write`. It needs no other
  permission.
- Give the account in `secrets:`, not in `with:`. Use `user-id` (the numeric
  id), `login`, or both. The numeric id is better: a login can change, the id
  cannot. If you give both, they must name the same account, else the job
  fails.
- The values are secrets only so that the log masks them. They are not
  secret data.

### Secrets (inputs)

| Name | Required | Meaning |
|---|---|---|
| `user-id` | one of the two | Numeric GitHub user id, for example `${{ github.event.issue.user.id }}`. |
| `login` | one of the two | GitHub login, for example `${{ github.event.issue.user.login }}`. |

### Output

| Name | Values |
|---|---|
| `member` | `true` or `false`, read with `needs.<job>.outputs.member`. |

`true` only for a member of `tenstorrent`. `false` for an outside
collaborator, a pending invitation, a bot, an organization, an unknown login or
id, and a value that is not a valid login or id.

If the check cannot get an answer (sign-in, network or GitHub error), the job
fails. It never answers `false` on an error. Jobs that need it do not run.
Do not use `if: always()` on those jobs, else they run without an answer.

## Events

| Event | Works | Note |
|---|---|---|
| `issues`, `issue_comment`, `discussion`, `discussion_comment` | Yes | On the default branch. |
| `schedule`, `workflow_dispatch`, `push`, `workflow_run` | Yes | Only on the branch of your setup. |
| `pull_request` from the same repository | No | The token setup cannot be bound to a pull request ref. |
| `pull_request` from a fork | No | GitHub gives a fork pull request no identity token. |
| `pull_request_target` | Not yet | Planned for this workflow only. The job fails with a clear message until then. |
| `merge_group` | No | Same reason as `pull_request`. |

## Privacy and limits

- The job prints no login, no id and no answer. Logs of a public repository
  are public.
- Your own jobs decide what they print. Do not print the answer, and do not
  print an account in the same log line.
- Anyone who can change your caller file can ask about any account, one per
  call. Ask only about the account of the event.
- No team, role, name or other data comes back. Only `true` or `false`.
- Only repositories of `tenstorrent` can call this workflow.

## Failures

| Message | Cause | Action |
|---|---|---|
| `Only repositories of the organization tenstorrent can call this workflow.` | The caller is in another organization. | None. |
| `Give the secret login, the secret user-id, or both.` | Both are empty. | Pass one of them in `secrets:`. |
| `This run has no GitHub identity token.` | `id-token: write` is missing, or a fork pull request. | Add the permission. Do not call it from a fork pull request. |
| `pull_request_target is not supported yet.` | See [Events](#events). | Use another event. |
| A sign-in error from the step "Get token" | The setup for your repository is not ready, or the run does not match it (branch, event, caller file, pinned commit). | Ask on your OSPO ticket. |
| `The secrets login and user-id name different accounts.` | The two values do not match. | Pass values of the same account. |
| `GitHub answered HTTP <code> ...` | GitHub error or network error. | Run the job again. If it fails again, ask on your OSPO ticket. |

## Releases

Each release has a tag `org-member-check-vX.Y.Z` and an immutable GitHub
release. There is no moving tag such as `v1`. When OSPO publishes a new
release, OSPO also updates the setup of each caller. Move your pin when OSPO
tells you on the ticket.

| Release | Commit |
|---|---|
| `org-member-check-v1.0.0` | Not released yet. |

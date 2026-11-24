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
    if: needs.member.outputs.member != 'true'
    runs-on: ubuntu-latest
    permissions:
      issues: write
    steps:
      # An empty output is an error, never "not a member".
      - name: Check the answer
        if: needs.member.outputs.member != 'false'
        run: '{ echo "::error::No answer from org-member-check."; exit 1; }'
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
  id). A login can change, the id cannot.
- `login` also works, with limits: a login that is part of the word `true` or
  `false` (for example `e` or `true`) fails the job; pass that account as
  `user-id`. The log masks the login everywhere in the job, so a login that is
  a common word can show by the pattern of `***`.
- If you give both, they must be valid and name the same user account, else
  the job fails.
- The values are secrets only so that the log masks them. They are not
  secret data.
- Call it once per calling job. Do not use a `matrix` on the calling job.

### Secrets (inputs)

| Name | Required | Meaning |
|---|---|---|
| `user-id` | one of the two (preferred) | Numeric GitHub user id, for example `${{ github.event.issue.user.id }}`. |
| `login` | one of the two | GitHub login, for example `${{ github.event.issue.user.login }}`. See the limits above. |

### Output

| Name | Values |
|---|---|
| `member` | `true` or `false`, read with `needs.<job>.outputs.member`. |

`true` only for a member of `tenstorrent`. With one value given, `false` for
an outside collaborator, a pending invitation, a bot, an organization, an
unknown login or id, and a value that is not a valid login or id. With both
values given, an invalid value, an unknown id, a bot or an organization fails
the job; an outside collaborator or a pending invitation is `false`.

If the check cannot get an answer (sign-in, network or GitHub error), the job
fails. It never answers `false` on an error. Jobs that need it do not run.
Do not use `if: always()` on those jobs, else they run without an answer.

An empty output is an error, never "not a member". Test for `true` and for
`false` explicitly, as in the example above.

## Events

| Event | Works | Note |
|---|---|---|
| `issues`, `issue_comment`, `discussion`, `discussion_comment` | Yes | On the default branch. |
| `schedule`, `workflow_dispatch`, `push`, `workflow_run` | Yes | Only on the branch of your setup. |
| `pull_request` from the same repository | No | The token setup cannot be bound to a pull request ref. |
| `pull_request` from a fork | No | GitHub gives a fork pull request no identity token. |
| `pull_request_target` | No | Not supported. The token service refuses this event. |
| `merge_group` | No | Same reason as `pull_request`. |

## Privacy and limits

- The job prints no login, no id and no answer. Logs of a public repository
  are public.
- Your own jobs decide what they print. Do not print the answer, and do not
  print an account in the same log line.
- A job that runs or skips on the answer shows the answer in the run graph of
  a public repository.
- A person with write access can re-run a job with debug logging. Debug lines
  can show the answer.
- Anyone who can change your caller file can ask about any account, one
  account per calling job. Ask only about the account of the event.
- No team, role, name or other data comes back. Only `true` or `false`.
- Only repositories of `tenstorrent` can call this workflow.

## Failures

| Message | Cause | Action |
|---|---|---|
| `Only repositories of the organization tenstorrent can call this workflow.` | The caller is in another organization. | None. |
| `Give the secret login, the secret user-id, or both.` | Both are empty. | Pass one of them in `secrets:`. |
| The run fails at start with a permissions error about `id-token: write` | The calling job does not give `permissions: id-token: write`. | Add the permission to the calling job. |
| `This run has no GitHub identity token.` | A pull request from a fork. | Do not call it from a fork pull request. |
| `pull_request_target is not supported.` | See [Events](#events). | Use another event. |
| `This login cannot be checked by login.` | The login is part of the word `true` or `false`. | Pass the account as `user-id`. |
| A sign-in error from the step "Get token" | The setup for your repository is not ready, or the run does not match it (branch, event, caller file, pinned commit). | Ask on your OSPO ticket. |
| `The secrets login and user-id do not name the same user account.` | Both are given, and they do not match, or one is invalid, unknown or not a user. | Pass `user-id` only, or values of the same account. |
| `GitHub answered HTTP <code> ...` | GitHub error or network error. | Run the job again. If it fails again, ask on your OSPO ticket. |

## Releases

Each release has a tag `org-member-check-vX.Y.Z` and an immutable GitHub
release. There is no moving tag such as `v1`. When OSPO publishes a new
release, OSPO also updates the setup of each caller. Move your pin when OSPO
tells you on the ticket.

| Release | Commit |
|---|---|
| `org-member-check-v1.0.0` | Not released yet. |

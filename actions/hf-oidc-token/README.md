# hf-oidc-token

**Prototype. Not released (no tag).** One live test passed on a
GitHub-hosted Linux runner on 2026-11-25. See
[What is proven](#what-is-proven-and-what-is-not).

Gets a short-lived, read-only Hugging Face token for gated models in one step.
No Hugging Face token is stored in GitHub.

The action does these steps:

1. It checks the inputs, the event and the branch of the run.
2. It asks GitHub for the job's OIDC token, for Hugging Face.
3. It exchanges the OIDC token at Hugging Face for a token of the OSPO
   service account. Hugging Face gives the token only if a CI/CD identity on
   that account matches the repository, branch and workflow file of the run.
4. Optional: it checks that the token can read each gated model in `models`,
   and lists the models it cannot read.

The token can read the gated repositories that the service account has
access to. It cannot write, it cannot read private repositories, and it ends
after 60 minutes.

## Before you start: open an OSPO ticket

**An OSPO ticket is necessary.** OSPO must add a CI/CD identity for your
workflow to the Hugging Face service account, and accept the licence of each
gated model on that account. Without the identity, the exchange fails.
The action cannot do this setup: the setup is on the Hugging Face side.

Put this in the ticket:

- the repository, for example `tenstorrent/tt-metal`;
- the workflow file name, for example `nightly-models.yml` (the file with
  `on:`, not a reusable workflow that it calls);
- the branch, normally `main` (it must have branch protection);
- the gated models that the job reads, for example
  `meta-llama/Llama-3.1-8B-Instruct`.

OSPO replies when the setup is ready. The repository then has the variable
`HF_OIDC_RESOURCE` (the service account name).

If you do not know the values yet, add the action with `models` and run the
workflow once. When the identity is missing, the action prints the exact
values in the log and in the job summary. Copy them into the ticket.

## Usage

```yaml
on:
  # Do not add pull_request, pull_request_target or workflow_run: this file
  # has a Hugging Face CI/CD identity.
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  models:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write          # this job only
    steps:
      - uses: actions/checkout@<full-commit-sha> # v7.0.1
        with:
          persist-credentials: false

      - id: hf
        uses: tenstorrent/.github/actions/hf-oidc-token@<full-commit-sha>
        with:
          resource: ${{ vars.HF_OIDC_RESOURCE }}
          models: |
            meta-llama/Llama-3.1-8B-Instruct

      - name: Download and use gated models
        env:
          HF_TOKEN: ${{ steps.hf.outputs.token }}
          HF_TOKEN_PATH: ${{ runner.temp }}/hf-no-stored-token
        run: |
          unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
          python3 scripts/run_models.py
```

Pin the action to a full commit SHA. There is no release yet.

### Rules for the calling workflow

1. **`id-token: write` on the one job that needs the token.** Put it in the
   job's `permissions:`, not at the top of the file.
2. **Give the token to one step only**, in that step's `env:`. Do not put
   `${{ steps.hf.outputs.token }}` in `run:` text.
3. **Never write the token to `GITHUB_ENV`**, a file, a cache or an artifact.
   The vendor page has an example with `GITHUB_ENV`. Do not copy it:
   `GITHUB_ENV` gives the token to every later step.
4. **Remove the OIDC request variables from every other `run:` step.** Start
   it with `unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN`.
   With these variables, any code in the step (for example a pip package) can
   get an OIDC token for the job and use it at other services that trust
   GitHub OIDC tokens of this repository. `uses:` steps cannot remove them:
   use only trusted actions in this job.
5. **Ignore stored tokens on the runner.** In the step that uses the token,
   set `HF_TOKEN_PATH` to a file that does not exist. Then the Hugging Face
   library cannot use an old token file on a self-hosted runner.
6. **Events:** only `schedule`, `workflow_dispatch` and `push`, on the branch
   in the identity. The action refuses other runs. Never add
   `pull_request_target` or `workflow_run` to the file.
7. **Long jobs:** the token ends after 60 minutes (output `expires-at`).
   For a later use, call the action again just before it.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `resource` | empty | The OSPO service account name. Pass `${{ vars.HF_OIDC_RESOURCE }}`. A composite action cannot read `vars`. A value with `/` (a repository) is refused: a repository resource gives a token that can write. |
| `models` | empty | Gated repositories that the job reads, one per line or separated by commas. `<owner>/<name>` for a model, `datasets/<owner>/<name>` for a dataset. At most 50. Empty: no check. |
| `if-no-token` | `fail` | `fail`: the action fails when it gives no token, or when the token cannot read a repository in `models`. `warn`: it writes a warning and succeeds. Then the token is empty, or (for `models`) the token reads only the other repositories. |
| `branch` | `main` | The only branch on which the action asks for a token. Use the branch of the CI/CD identity. |

Bad input values, and the events `pull_request_target` and `workflow_run`,
always fail, also with `if-no-token: warn`.

Why `fail` is the default: a job that needs gated models usually cannot do its
work without them. A warning is easy to miss, and a test that skips its gated
part looks green. Use `warn` for a job that also runs on pull requests and
skips the gated part there.

There is no built-in default for `resource`. The account name is not secret,
but the variable `HF_OIDC_RESOURCE` also shows that OSPO set up the
repository. An empty value gives a clear message: open an OSPO ticket.

## Outputs

| Output | Description |
| --- | --- |
| `token` | The Hugging Face token. Masked in logs. Empty when there is no token. |
| `expires-at` | The time (UTC, ISO 8601) at which the token ends. |
| `models-without-access` | Repositories from `models` that the token cannot read, separated by commas. |
| `failed-step` | `prepare`, `exchange` or `models`: the step that stopped the action. Also set with `if-no-token: warn`. Empty on full success. |

## Failures

The action writes one error (or, with `warn`, one warning) with the cause.
The table shows the start of each message, as the scripts write it. With
`warn`, the message ends with "The job continues without a Hugging Face
token (if-no-token: warn)." `<...>` is a value of the run.

Checks before the exchange (step `prepare`):

| Message starts with | Cause | What to do |
| --- | --- | --- |
| `input resource is empty.` | The repository has no variable `HF_OIDC_RESOURCE`, or the workflow does not pass it. | Pass `resource: ${{ vars.HF_OIDC_RESOURCE }}`. If the variable does not exist, **open an OSPO ticket** (see [Before you start](#before-you-start-open-an-ospo-ticket)). |
| `the action gives a token only for the events schedule, workflow_dispatch and push.` | The run came from another event, for example `pull_request`. | Run it from a schedule, by "Run workflow", or on push. |
| `the action gives a token only on branch <branch> (input branch).` | The run is on another branch or a tag. | Run it on the branch of the identity. |
| `refused on pull_request_target:` / `refused on workflow_run:` | The file has a trigger that outside code can start. Always an error. | Remove the trigger. |
| `the job has no OIDC token.` | No `id-token: write` on the job. | Add it to the job's `permissions:`. |
| `input resource '<value>' has a '/'.` / `input resource is not a valid Hugging Face user name.` | `resource` is a repository name or has other characters. Always an error. | Pass `vars.HF_OIDC_RESOURCE`. |
| `input models: '<value>' is not a Hugging Face repository name.` / `input models has more than 50 repositories.` | A bad entry in `models`. Always an error. | Use `<owner>/<name>` or `datasets/<owner>/<name>`. |
| `input branch is not a valid branch name.` / `input if-no-token must be fail or warn.` | A bad input value. Always an error. | Correct the value. |
| `this runner has no curl` / `this runner has no jq` | The runner lacks a tool. Always an error. | Install it, or use another runner. |

A warning that does not stop the action: `branch <branch> has no branch
protection or ruleset.` Protect the branch.

Exchange (step `exchange`):

| Message starts with | Cause | What to do |
| --- | --- | --- |
| `Hugging Face did not accept this run for account <account>.` | Hugging Face answered `invalid_grant`. No CI/CD identity on the account matches this run, or the account does not exist (Hugging Face then says `User '<account>' not found`). | **Open an OSPO ticket** (or add to your ticket). Copy the values from the message or the job summary: repository, branch, workflow file. Add the gated models. Give the Request ID. |
| `Hugging Face refused the exchange (HTTP <code>).` | Another refusal, for example `invalid_request`. | Report to OSPO with the Request ID. |
| `Hugging Face refused the exchange: too many requests.` | Rate limit (HTTP 429). | Run the job again later. |
| `Hugging Face had an error (HTTP <code>).` | Server error (HTTP 5xx). | Run the job again. |
| `Hugging Face did not answer the exchange within 20 seconds.` | Timeout. | Run the job again. |
| `the action could not send the exchange to https://huggingface.co (curl exit <n>).` | No route to `huggingface.co`. | Run the job again. On a self-hosted runner, check that it reaches `huggingface.co`. |
| `GitHub did not give an OIDC token (HTTP <code>).` / `GitHub did not give the OIDC token in 3 tries.` / `the action could not get the OIDC token from GitHub (curl exit <n>).` | GitHub did not give the OIDC token. | Check `id-token: write`. Run the job again. |
| `Hugging Face answered the exchange without a token.` / `Hugging Face gave a token in a form that the action does not expect.` | An answer that the vendor does not document. Always an error. | Report to OSPO. |

Model check (step `models`):

| Message starts with | Cause | What to do |
| --- | --- | --- |
| `account <account> cannot read <n> of <m> repositories:` | The account has not accepted the licence of those models, or the vendor has not approved it yet. Or the repository is private or does not exist. The log line `NO ACCESS: <repo>: <reason>.` gives the reason for each one. | Ask OSPO on your ticket to accept the licence. The list is in the job summary. |

Never paste a token into a ticket. In the log, a token shows as `***`.

## How the exchange works

The action uses `curl` and `jq` only. It does not install Python packages:
no package code runs while the OIDC request variables are in the step.

1. `GET $ACTIONS_ID_TOKEN_REQUEST_URL&audience=https%3A%2F%2Fhuggingface.co`
   with header `Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN`.
   15 seconds, up to 3 tries.
2. `POST https://huggingface.co/oauth/token`, `Content-Type: application/json`:

   ```json
   {
     "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
     "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
     "subject_token": "<OIDC token>",
     "resource": "<service account name>"
   }
   ```

   20 seconds, one try. The answer has `access_token` and `expires_in`.
3. For each repository in `models`:
   `GET https://huggingface.co/api/models/<repo>/auth-check` (or
   `/api/datasets/...`) with `Authorization: Bearer <token>`. 15 seconds, up
   to 3 tries. 200 means the account can read it. 403 with
   `X-Error-Code: GatedRepo` means the licence is not accepted.

Sources: [Hugging Face Trusted Publishers](https://huggingface.co/docs/hub/trusted-publishers),
section "API reference"; `huggingface_hub` `src/huggingface_hub/_oidc.py`
(`_get_github_oidc_token`, `exchange_oidc_token`) and `hf_api.py`
(`auth_check`).

Secrets never go into argv or a file. The OIDC token and the Hugging Face
token are masked (each line) as soon as the action has them, before any other
output.
The OIDC request token goes in a header from a pipe. The exchange body comes
from `jq` on stdin.

## What OSPO sets up

Once for the service account (see the Confluence page "Hugging Face tokens in
GitHub Actions without a stored secret (OIDC)"): a Hugging Face account that
belongs to OSPO, two-factor authentication, no access tokens.

For each ticket:

1. Accept the licence of each gated model on the service account. Wait for
   the vendor approval if the model needs one.
2. On the account, Settings, Authentication, CI/CD Access, add an identity:
   Provider GitHub Actions; `repository` `<org>/<repo>`; `branch` `main`;
   `workflow` `<file>.yml`; Allow Inference Providers calls **off**.
   Set all three claims.
3. Set the repository variable:
   `gh variable set HF_OIDC_RESOURCE -R <org>/<repo> --body <service-account>`.

## Design: why each workflow still needs a ticket

The request was: "Can this be a .github action ... this way we don't need to
submit OSPO tickets in advance". The answer: the action makes the workflow
change simple and the ticket easy. It cannot remove the ticket.

Facts from the vendor documentation:

- The GitHub token always names the **calling** repository, branch and
  workflow file. A shared action cannot change that.
- The Hugging Face preset for GitHub matches `repository`, `branch` and
  `workflow` (the file of `workflow_ref`, by prefix). Claims match exactly.
  There is no regex and no wildcard.
- The documentation does not name `job_workflow_ref`, `environment` or
  `event_name` as claims, and has no organization-wide rule.
- The documentation does not say if one account can hold many identities.
- Gated access belongs to the account. A person must accept each licence.

Options:

| Option | What it means | Decision |
| --- | --- | --- |
| (a) Composite action, one identity per calling workflow | The current model. Simple YAML for the caller. One ticket per workflow. | **Chosen**, with (d). |
| (b) Reusable workflow in `tenstorrent/.github`, one identity for it | Needs Hugging Face to match `job_workflow_ref`. The documentation does not offer it. Also: any repository in the organization could then read every gated model of the account, and the token would exist only in the called job, so the download would have to happen there. | Considered, not chosen. Not possible with the documented claims, and it removes the review per workflow. |
| (c) Broader identity: `repository` only, or no branch/workflow | Documented as possible (`repository` alone). Then any branch and any workflow of the repository can get a token, also a pull request branch that a person with write access pushes. | Considered, not chosen. Too wide. |
| (d) Make the ticket easy | After a failed run, the action prints the exact identity values and the models without access, in the log and in the job summary. | **Chosen**, with (a). |

## Limits

- Token life: 60 minutes from the exchange. No refresh.
- Read-only. Gated public repositories only. No private repositories. No
  uploads. No Inference Providers calls.
- GitHub Actions only. Not on a laptop.
- The token reads every gated model that the service account can read, not
  only the ones in `models`. `models` is a check, not a limit.
- The action cannot hide the OIDC request variables from the other steps of
  the caller's job. See rule 4.

## What is proven and what is not

Proven in a live test: run
[45521842112](https://github.com/tenstorrent/.github/actions/runs/45521842112),
2026-11-25 (UTC), GitHub-hosted Ubuntu runner, branch `ospo/hf-oidc-token`,
commit `780ce2a`. The CI/CD identity for the test named the repository and
the workflow file only, not the branch.

- A real exchange at `https://huggingface.co/oauth/token` for the account,
  with the request format in [How the exchange works](#how-the-exchange-works).
- The model check: `auth-check` accepts the token of a CI/CD identity and
  answers 200 for `meta-llama/Llama-3.1-8B-Instruct`.
- The token reads `config.json` of that gated model. Without a token, the
  same request gets 401 or 403.
- A refused exchange (job `live-refusal`, an account that does not exist):
  Hugging Face answered `invalid_grant` with the text
  `User '<account>' not found`, and the header `X-Request-Id` held the
  Request ID. The action failed in step `exchange` with an empty token.
- No token text in the log.

Proven offline (with a fake `curl`, on each pull request):

- the input, event and branch checks and their messages;
- masking before any output, no secret in argv, the log or the job summary;
- the message for each failure class, and the model check classification.

Not proven:

- The answer 403 `GatedRepo` for a model whose licence the account has not
  accepted.
- The real error text when the account exists but no identity matches (for
  example a wrong branch or workflow file), and the texts for HTTP 429 and 5xx.
- A caller in another repository.
- An identity that also names the branch (the test identity had no branch).
- A job longer than 60 minutes.
- Self-hosted runners, and macOS and Windows runners.
- That one service account can hold many CI/CD identities.
- How the `workflow` field matches a reusable workflow (the action assumes
  the calling file, from `workflow_ref`).
- Whether a custom GitHub Enterprise OIDC issuer would match the Hugging Face
  preset (`https://token.actions.githubusercontent.com`).

## Tests

- `test/prepare-cases.sh`: pre-checks, run directly.
- `test/exchange-cases.sh`: the exchange and the models check, with a fake
  `curl`.
- `test/assert-result.sh`: used by the test workflow.

The workflow [`hf-oidc-token-test.yml`](../../.github/workflows/hf-oidc-token-test.yml)
runs these on each pull request that changes the action, and runs the action
in cases that stop in the pre-checks. Its live jobs need the Hugging Face
setup, the variable `HF_OIDC_TEST_ENABLED` and the environment
`hf-oidc-token-test` with required reviewers. Its header lists the values.

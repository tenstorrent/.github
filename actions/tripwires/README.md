# Tripwires

Checks that stop a job on a value that only makes sense as an attack: code
injection, or sending a secret somewhere it must not go. They started in
[`cachew-checkout`](../cachew-checkout/README.md#refused-inputs) and are shared
here so that every action in this repository, and any workflow, can use the same
ones.

A tripwire is not input validation. Validation refuses a value the action does
not support and says how to correct it. A tripwire fires on a value that no
supported configuration produces. When one fires:

- the step fails, with no fallback;
- the log gets an error annotation titled
  `<title>: possible security compromise attempt`;
- the annotation names the check and the input, never the value, which could
  itself carry workflow commands;
- the output `security-violation` is `true`.

## Scope: what these checks can do, and what protects the secrets

GitHub Actions has no boundary between the steps of one job. The steps share
the files of the runner, the variables written to `GITHUB_ENV`, the
directories written to `GITHUB_PATH`, and every process that an earlier step
left running. On a job with `id-token: write`, the runner gives every step the
request token for the job's OIDC token. A step that runs untrusted code can
therefore ask for the OIDC token itself and log in wherever the job can. No
check in a later step prevents that. The boundary that GitHub provides is the
job.

The tripwires cover a narrower case: untrusted data reached the job, and
untrusted code has not run yet. Two examples: an action input that a branch
name or a pull request title fills, and a workflow that copies lines of an
artifact into `GITHUB_ENV`. For that case the checks look at the few settings
that turn data into code or send a secret somewhere else: the inputs of the
action, where its token goes, the event, and a short list of environment
variables (`BASH_ENV`, `LD_PRELOAD`, exported shell functions, `PATH`, shell
tracing, certificates). A tripwire is a detection signal. `LD_PRELOAD`, for
one, has loaded its library into the step's shell before the check runs: the
check reports that the job is compromised and cannot undo it.

The list of environment variables is short on purpose. Many more variables
change what a program loads or runs (`LD_LIBRARY_PATH`, `GIT_CONFIG_COUNT`,
`GIT_SSH_COMMAND`, `OPENSSL_CONF`, `NODE_OPTIONS`, `HOME` and others), and jobs
set most of them for ordinary reasons. The list does not grow to follow them:
a job where an attacker sets such a variable is a job that mixes untrusted
input with secrets, and the fix for that is below. Of these, the runner
refuses only `NODE_OPTIONS` from `GITHUB_ENV`.

### Keep untrusted code and secrets in different jobs

These rules protect the secrets. The tripwires only report when a job has
broken one of them.

1. A job that runs code from a pull request gets no secret and no
   `id-token: write`. Code means everything the pull request can change:
   build scripts, Makefiles, package install hooks, tests, and files that a
   tool reads as configuration.
2. A job that reads secrets runs no code from a pull request, in any step,
   before or after the secret is read.
3. Set `permissions` for each job, not for the workflow, and give each job
   the least it needs. `id-token: write` belongs only on the job that logs in.
4. Each job on a GitHub-hosted runner starts on a new machine. On a
   self-hosted runner this holds only when the runner is ephemeral (one job,
   then discarded). On a runner that keeps its files, a job without secrets
   can prepare the machine for the next job.
5. Pass only data between jobs: outputs and artifacts. The job that receives
   them treats them as untrusted. It does not run them, does not write them
   to `GITHUB_ENV`, `GITHUB_PATH` or `GITHUB_OUTPUT` without checking their
   form, and does not extract an artifact over the workspace.
6. For pull requests from forks, use `pull_request`, which has no secrets. Do
   privileged work in a second workflow on `workflow_run` that does not check
   out the head of the first run and does not run its artifacts. Do not use
   `pull_request_target` together with a checkout of the pull request.
7. Pass untrusted values to a script through `env:`. An expression such as
   `${{ github.head_ref }}` written into a `run:` script becomes shell text.
8. Pin third-party actions to a commit SHA, and container images to a digest.

```yaml
jobs:
  build: # runs the pull request's code: no secrets
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<full-commit-sha>
      - run: make test
      - uses: actions/upload-artifact@<full-commit-sha>
        with:
          name: report
          path: report.json

  publish: # reads secrets: runs no code from the pull request
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/download-artifact@<full-commit-sha>
        with:
          name: report
          path: ${{ runner.temp }}/report
      - id: vault
        uses: tenstorrent/.github/actions/vault-secrets@<full-commit-sha>
        with:
          secrets: |
            kv/data/tenstorrent/example-app/upload api_key | UPLOAD_API_KEY
      # The report is data: it is read, never run.
      - run: curl --fail --data-binary "@$RUNNER_TEMP/report/report.json" -H "Authorization: Bearer $UPLOAD_API_KEY" https://example.com/reports
        env:
          UPLOAD_API_KEY: ${{ fromJSON(steps.vault.outputs.secrets).UPLOAD_API_KEY }}
```

GitHub's guidance says the same: [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
and the CodeQL query [environment variable built from user-controlled sources](https://codeql.github.com/codeql-query-help/actions/actions-envvar-injection-critical/).
[GHSL-2024-255](https://securitylab.github.com/advisories/GHSL-2024-255_docker-mailserver)
is a real case: a `workflow_run` workflow appended a file of an artifact to
`GITHUB_ENV`, and the file set `LD_PRELOAD`.

## The checks

| Check | Function | Fires when the value |
| --- | --- | --- |
| `no-option <name>` | `no_option` | starts with `-`, so a command would read it as an option |
| `single-line <name>` | `single_line` | holds a line break or control character (a second line in `GITHUB_ENV`, a header, a configuration file) |
| `shell-safe <name>` | `shell_safe` | holds anything the shell does not read as itself. For names and identifiers, not free text |
| `relative-path <name> [component ...]` | `relative_path` | is absolute, or has `..`, a backslash, a control character or a listed component (for example `.git`) |
| `inside <name> [VARIABLE]` | `inside` | resolves, symlinks followed, outside the directory in `VARIABLE` (default `GITHUB_WORKSPACE`) |
| `plain-path <name>` | `plain_path` | is a URL path with a query, fragment, percent-encoding or anything else beyond plain segments |
| `url-host <name>` | `origin` | is a URL whose host, as written or as parsed, has characters no DNS name or IP literal has |
| `trusted-origin <name> <origin> ...` | `trusted_origin` | is not one of the listed HTTPS origins: another host, plain HTTP, or a spelling with userinfo or a path |
| `oidc-url <name> [host ...]` | `oidc_request_url` | (normally `ACTIONS_ID_TOKEN_REQUEST_URL`) is not HTTPS on a GitHub Actions host, so another server would receive the OIDC request token. For GitHub Enterprise Server, list its host |
| `oidc-claims <name> <audience> [VARIABLE]` | `oidc_claims` | is an OIDC token whose issuer, audience or repository (from `VARIABLE`, default `GITHUB_REPOSITORY`) is not what this job asked for, that names another audience too, or that is not in the strict form of a JWT (three base64url parts, JSON objects, no member named twice): a token swapped in on the way |
| `environment [command ...]` | `hostile_environment` | (no value) the environment is prepared to run code in the job's scripts or print their secrets: `BASH_ENV`, `LD_PRELOAD`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`, any exported shell function, `SHELLOPTS` with `xtrace` or `verbose`, a `PS4` that holds a command, `GIT_TRACE_REDACT` off, `NODE_TLS_REJECT_UNAUTHORIZED=0`, a `PATH` entry that is empty or relative (the current directory), a named command that `PATH` finds first inside `GITHUB_WORKSPACE`, or a certificate variable (`CURL_CA_BUNDLE`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `GIT_SSL_CAINFO`, `GIT_SSL_CAPATH`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`) that names a place inside `GITHUB_WORKSPACE` |
| `event [event ...]` | `untrusted_event` | (no value) the run's event is `pull_request_target` or `workflow_run`. With events listed, the run's event is one of those, and the two defaults apply only when listed too |

The first seven guard against code injection; `trusted-origin`, the two OIDC
checks and `event` against secret exfiltration; `environment` against both. Three helpers cover the output side: `mask` (hide a value in the
log), `report` (the annotation above) and `write_output` (a step output or
`GITHUB_ENV` entry with a random delimiter, so a value cannot start another
entry).

A value is checked as an action reads its input: trimmed. An empty value passes,
because the input was not given. Use validation, not a tripwire, for an input
that is required.

## Use it

### As a step, in any workflow or composite action

```yaml
- uses: tenstorrent/.github/actions/tripwires@<full-commit-sha>
  with:
    title: my-action
    values: ${{ toJSON(inputs) }}
    checks: |
      event
      no-option      ref
      inside         path
      relative-path  path .git
      trusted-origin vault-url https://vault-ospo.eng-svc.aws.tenstorrent.com
```

`values` is a JSON object; each name in `checks` is one of its keys. A name that
is not a key is read from the job's environment. The expression is passed as
data and never becomes shell text. Put the step before any step that uses the
values or handles a secret.

### As a command, from another action in this repository

A consumer's pin downloads this whole repository at that commit, so an action
here can run the script next to it. That keeps one pin, where a nested `uses:`
would need a second.

```yaml
- shell: bash --noprofile --norc -p -e -o pipefail {0}
  env:
    IN_REF: ${{ inputs.ref }}
    IN_PATH: ${{ inputs.path }}
  run: |
    tripwires_python_names=python3
    . "$GITHUB_ACTION_PATH/../tripwires/trusted-python.sh"
    [[ -n "$tripwires_python" ]] || { echo "::error title=my-action: tripwires could not run::no Python 3.9+ outside the workspace"; exit 1; }
    "$tripwires_python" -I "$GITHUB_ACTION_PATH/../tripwires/tripwires.py" --title my-action <<'EOF'
    environment
    no-option IN_REF=ref
    inside    IN_PATH=path
    EOF
```

Three parts of this keep an earlier step of the job from deciding the result
before the checks run:

- **The shell line.** `-p` (privileged mode) is the runner's own `bash` line
  with one option added. Bash then reads no `BASH_ENV` file and takes no shell
  function or `SHELLOPTS` from the environment. Plain `shell: bash` reads the
  `BASH_ENV` file before the first line of the step. A script that the step
  starts needs the same, from the same shell: `"$BASH" -p script.sh`. `$BASH`
  is the shell that the runner started. A plain `bash` is looked up again on
  the step's `PATH`, which an earlier step can set through `GITHUB_ENV`. The
  runner does not use that `PATH` to find the shell of the step, so a file
  named `bash` in the workspace would run only there, in place of the script
  and before any check.
- **`trusted-python.sh`.** It sets `tripwires_python` to the first interpreter
  on `PATH` whose directory, with every link followed, is outside
  `GITHUB_WORKSPACE`, where a pull request could place a file named `python3`.
  A virtual environment in the workspace is skipped, not refused. When `PATH`
  has no other interpreter, the variable is empty: stop the step.
- **`-I`.** `PYTHONPATH` and the user site cannot replace a module that the
  checks import.

Names are environment variables. `IN_REF=ref` reads the variable `IN_REF` and
calls it `ref` in the annotation. `--consequence "No request was sent."` adds
what did not happen. Never write an expression into the checks or the script:
pass every value through `env`.

Exit status: 0 when nothing fired, 1 when a check fired, 2 when the checks could
not run (an unknown check, a name with no value, a `trusted-origin` with no
origins). Status 2 fails the step too: a check that cannot run protects nothing.

### As a Python module

```python
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tripwires"))
import tripwires

try:
    tripwires.no_option(ref, "ref", "a Git option")
    target = tripwires.inside(workspace, path, "checkout path", "the workspace")
    vault = tripwires.trusted_origin(url, TRUSTED, "vault-url", "the job's OIDC token")
except tripwires.Violation as error:
    tripwires.report("my-action", error, "Nothing was sent.")
    sys.exit(1)
```

Each function returns the checked value (`inside` the resolved path, `origin`
and `trusted_origin` the normalized origin) or raises `Violation`. The second
argument is your own fixed label for the value; it goes into the message, so
never pass the value itself. `origin` also raises `Unsupported` for a URL that
is harmless but more than a plain HTTPS origin, which is a case for validation.

## Alerting

GitHub has no API that writes an event to the organization audit log or to a
security log, so a tripwire cannot record itself there. The record it does
leave is the error annotation on the job, and its title always ends with:

```text
: possible security compromise attempt
```

That text is a contract (`ANNOTATION_SUFFIX` in `tripwires.py`): it does not
change, and nothing else in these actions uses it. To alert on it from outside
the job, with no permission added to the job and nothing the job's own code
can switch off:

1. Subscribe an organization webhook or a GitHub App to the `workflow_job`
   event.
2. On `action: completed` with `conclusion: failure`, read the annotations of
   the job's check run (the job ID is the check run ID):
   `GET /repos/{owner}/{repo}/check-runs/{job_id}/annotations`.
3. Alert when an annotation has `annotation_level: failure` and a `title` that
   ends with the text above. The start of the title names the action; the
   message names the check and the input, never the value.

A second title suffix is fixed in the same way (`CANNOT_RUN_SUFFIX`):

```text
: tripwires could not run
```

It marks a step that failed because the checks did not run at all: no Python
outside the workspace, a check line that is wrong, or an error in the checks
themselves. Nothing was checked, so the step stops, but this is not proof of an
attack: a runner image without Python gives it too. Alert on it as well where
every runner is known to have Python, because a `PATH` written to `GITHUB_ENV`
can hide the interpreter on purpose. `cachew-checkout` is the one exception:
without Python it does not check the environment and goes on to the standard
checkout with no annotation, unless `github-server-url` is set with the job's
own token.

The receiver needs read access to checks, and nothing else. A step name
is not a usable signal: the `workflow_job` payload lists the job's own steps, so
the steps inside a composite action appear only as the one step that called it.

Limits: GitHub keeps a limited number of annotations for each step and job, so
a job that already printed many errors can push this one out; the receiver can
treat "failed, and annotations at the limit" as worth a look. Code that already
runs in the job can also print a forged annotation with this title, which
gives a false alert, not a missed one.

## Requirements and limits

- Python 3.9 or newer on `PATH`, outside the workspace, standard library only.
  Without it the step fails.
- The checks read values. They cannot see what a later step does with them: a
  value that passes `shell-safe` is still best passed through `env`, not written
  into a script.
- `inside` resolves the path when it runs. A step that creates a symlink
  afterward is not covered.
- The actions here start every step with `bash -p`, so a `BASH_ENV` file does
  not run in them, and `environment` still reports it: the other steps of the
  job read it. A step with plain `shell: bash` has read the file before its
  first line; there the check reports that the job is compromised and cannot
  undo what the file did.
- `trusted-python.sh` follows the links of each directory on `PATH`, not of
  the interpreter file itself: bash cannot read where a link leads without a
  command from `PATH`. A link outside the workspace that leads to a file inside
  it is not detected; making one takes code that already runs on the runner.
- On Windows the shell line starts the same Git Bash as `shell: bash` does;
  this was not tested there.
- The runner finds the `bash` of the `shell:` line itself, before any line of
  the action runs. It looks in the directories that earlier steps added
  through `GITHUB_PATH` first, then on its own `PATH`. A file named `bash` in
  a directory that an earlier step added runs in place of the shell, and no
  check inside the step can see that or stop it. An absolute path in `shell:`
  would avoid the lookup, but no single path is right on Linux, macOS, Windows
  and in container jobs, so the actions do not use one. What the actions do:
  they start their scripts with `"$BASH"`, and they name `bash` after
  `environment`, which reports a `bash` that `PATH` finds first in the
  workspace when that shell still runs the script. Checking `$BASH` against
  the workspace would add nothing: a planted shell decides what `$BASH` says.
- `environment` fires on every exported shell function (`BASH_FUNC_...`),
  whatever its name: a runner that exports one on purpose cannot use this
  check. The scripts here still call builtins such as `cd` before or after the
  check; a function named `builtin` or `cd` runs first in a script that bash
  started with those functions, and the check then reports it. Only a script
  started with `bash -p`, as the actions here start theirs, runs none of them.
- `environment` checks `PATH` in two ways. An empty or relative entry fires,
  because it makes every command lookup depend on the current directory (not
  on Windows, where entries are not POSIX paths). For each command named after
  `environment` (`environment curl jq`), the first match on `PATH` must not be
  inside `GITHUB_WORKSPACE`, links followed, because a pull request places files
  there. Name the commands that carry your secrets. A command that is not named
  is not checked, so a virtual environment in the workspace stays a supported
  configuration: do not name `python3` when the job uses one. A planted command
  outside the workspace, in a directory an earlier step added to `PATH`, is
  not detected.
- `environment` fires on `LD_PRELOAD` whatever it loads. A runner that preloads
  a library on purpose (an allocator, say) cannot use this check.
- `LD_LIBRARY_PATH` and the macOS `DYLD_*_PATH` variables are not checked.
  `actions/setup-python` sets the first to a tool cache directory, and jobs
  set it to a build directory of the workspace.
- A certificate variable fires only when it names a file or directory inside
  `GITHUB_WORKSPACE` (a relative value counts as inside). Certificates
  anywhere else pass: a self-hosted runner behind a proxy that inspects TLS
  sets them on purpose. A job that creates its own certificate authority in
  the workspace and exports it cannot use this check; write the file to
  `RUNNER_TEMP`.
- `environment` does not fire on proxy variables (`HTTPS_PROXY`, `ALL_PROXY`).
  Runners behind a proxy set them. A proxy alone sees the name of the server
  and not the request: the action's requests are HTTPS, and the certificate
  checks above and `NODE_TLS_REJECT_UNAUTHORIZED` cover the ways to make a
  client trust the proxy itself.
- `environment` does not fire on `GIT_SSL_NO_VERIFY`. `cachew-checkout` treats
  it as the job's own setting and keeps its tokens off unverified requests
  (see its README).
- `oidc-url` is a second line of defense. On a job with `id-token: write` the
  runner sets `ACTIONS_ID_TOKEN_REQUEST_URL` and the request token again for
  every step, after the values from `GITHUB_ENV`, so an earlier step cannot
  change the URL that a later step reads. `GITHUB_*` and `RUNNER_*` variables
  are set the same way. The host is matched after parsing: lower case, no
  userinfo, port 443 or none, an exact name or a suffix that starts with a
  dot. A trailing dot does not match. For GitHub Enterprise Server, the
  caller lists the host; a listed suffix such as `.example.com` trusts every
  host below it, so list the one name.
- `oidc-claims` compares claims; it verifies no signature. The receiver does.
  The form is strict, so that this parser and the receiver's cannot read two
  different tokens: exactly three base64url parts, a header and a payload that
  are JSON objects, no member named twice, and the requested audience alone.
  The command refuses a token in any other form; the function `oidc_claims`
  returns `None` for one, and the caller decides.
- `event` reads `GITHUB_EVENT_NAME`, which the runner sets for every step and
  `GITHUB_ENV` cannot change. In a reusable workflow it is the event of the
  calling workflow.
- `event` covers the two events where GitHub itself pairs the base
  repository's secrets with content from outside: `pull_request_target` (the
  pull request of a fork) and `workflow_run` (the artifacts and the head of
  another run). It does not judge who may trigger a `workflow_dispatch` or
  which branch runs. Other events also run with secrets and can be started
  from outside, such as `issue_comment`, `issues` and `discussion`. They
  carry text, not code: they are safe until the workflow itself checks out
  and runs the pull request, and the check cannot see that. A caller that
  wants them refused lists them, together with the two defaults.
- Events listed after `event` replace the defaults. `vault-secrets` lists
  only `pull_request_target`, so it runs on `workflow_run`: workflows that
  run after another workflow read their secrets with it. Such a workflow must
  not run code or artifacts of the first run. `hf-oidc-token` refuses both.

## Tests

```sh
python3 -m unittest discover -s actions/tripwires/tests -v
```

The `Test tripwires` workflow runs them on pull requests that touch this
directory, and runs the step itself on clean and on hostile values.
`cachew-checkout` imports this module, and `vault-secrets` and `hf-oidc-token`
run the command from their `prepare.sh`, so their test workflows run on changes
here too.

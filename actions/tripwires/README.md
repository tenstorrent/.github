# Tripwires

Checks that stop a job on a value that only makes sense as an attack: code
injection, or a secret sent somewhere it must not go. Every action in this
repository can use them, and so can any workflow.

A tripwire is not input validation. Validation refuses a value the action does
not support and says how to fix it. A tripwire fires on a value that no
supported configuration produces. When one fires:

- the step fails, with no fallback;
- the log gets an error annotation titled `<title>: input not supported`, which
  names the check and the input but never the value;
- the output `security-violation` is `true`.

The title reads like an ordinary input error on purpose. See
[Alerting](#alerting) for how to find it.

## Scope

GitHub Actions has no boundary between the steps of one job. Steps share the
runner's files, `GITHUB_ENV`, `GITHUB_PATH` and any process an earlier step
left running. On a job with `id-token: write`, every step can request the
job's OIDC token. A step that runs untrusted code can therefore log in wherever
the job can, and no later check prevents that. The job is the only boundary.

Tripwires cover a narrower case: untrusted data reached the job before any
untrusted code ran. For example, an input filled from a branch name, or a
workflow that copies an artifact's lines into `GITHUB_ENV`. The checks look at
the settings that turn data into code or send a secret elsewhere: the action's
inputs, where its token goes, the event, and a few environment variables.
Some of these act before the check runs (`LD_PRELOAD` is already loaded), so a
tripwire reports a compromised job. It cannot undo one.

The list of environment variables stays short. Many variables change what a
program loads (`LD_LIBRARY_PATH`, `GIT_CONFIG_COUNT`, `GIT_SSH_COMMAND`,
`OPENSSL_CONF`, `NODE_OPTIONS`, `HOME`), and jobs set most of them for
ordinary reasons. If an attacker can set them, the job mixes untrusted input
with secrets, and the fix is the next section.

### Keep untrusted code and secrets in different jobs

These rules protect the secrets. Tripwires only report a job that breaks them.

1. A job that runs code from a pull request gets no secret and no
   `id-token: write`. Code includes build scripts, Makefiles, install hooks,
   tests and tool configuration files.
2. A job that reads secrets runs no code from a pull request, before or after
   it reads them.
3. Set `permissions` per job, with the least each job needs.
   `id-token: write` belongs only on the job that logs in.
4. Use ephemeral runners. A runner that keeps its files lets one job prepare
   the machine for the next. GitHub-hosted runners are ephemeral.
5. Pass only data between jobs (outputs and artifacts), and treat it as
   untrusted in the receiving job. Do not run it, do not write it unchecked to
   `GITHUB_ENV`, `GITHUB_PATH` or `GITHUB_OUTPUT`, and do not extract an
   artifact over the workspace.
6. For fork pull requests, use `pull_request`, which has no secrets. Do
   privileged work in a `workflow_run` workflow that does not check out or run
   anything from the first run. Never combine `pull_request_target` with a
   checkout of the pull request.
7. Pass untrusted values to scripts through `env:`. `${{ github.head_ref }}`
   written into a `run:` script becomes shell text.
8. Pin third-party actions to a commit SHA and container images to a digest.

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

See GitHub's [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
and the CodeQL query [environment variable built from user-controlled sources](https://codeql.github.com/codeql-query-help/actions/actions-envvar-injection-critical/).
In [GHSL-2024-255](https://securitylab.github.com/advisories/GHSL-2024-255_docker-mailserver),
a `workflow_run` workflow appended an artifact file to `GITHUB_ENV`, and the
file set `LD_PRELOAD`.

## The checks

| Check | Function | Fires when the value |
| --- | --- | --- |
| `no-option <name>` | `no_option` | starts with `-`, so a command would read it as an option |
| `single-line <name>` | `single_line` | has a line break or control character |
| `shell-safe <name>` | `shell_safe` | has anything the shell does not read literally. For names and identifiers, not free text |
| `relative-path <name> [component ...]` | `relative_path` | is absolute, or has `..`, a backslash, a control character or a listed component such as `.git` |
| `inside <name> [VARIABLE]` | `inside` | resolves, symlinks followed, outside the directory in `VARIABLE` (default `GITHUB_WORKSPACE`) |
| `plain-path <name>` | `plain_path` | is a URL path with a query, fragment, percent-encoding or anything beyond plain segments |
| `url-host <name>` | `origin` | is a URL whose host has characters no DNS name or IP literal has |
| `trusted-origin <name> <origin> ...` | `trusted_origin` | is not one of the listed HTTPS origins |
| `oidc-url <name> [host ...]` | `oidc_request_url` | (normally `ACTIONS_ID_TOKEN_REQUEST_URL`) is not HTTPS on a GitHub Actions host. For GitHub Enterprise Server, list its host |
| `oidc-claims <name> <audience> [VARIABLE]` | `oidc_claims` | is an OIDC token with another issuer, audience or repository (from `VARIABLE`, default `GITHUB_REPOSITORY`), an extra audience, or not in strict JWT form |
| `environment [command ...]` | `hostile_environment` | (no value) `BASH_ENV`, `LD_PRELOAD`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`, an exported shell function, `SHELLOPTS` with `xtrace` or `verbose`, a `PS4` with a command, `GIT_TRACE_REDACT` off, `NODE_TLS_REJECT_UNAUTHORIZED=0`, an empty or relative `PATH` entry, a listed command that `PATH` finds first in `GITHUB_WORKSPACE`, or a certificate variable (`CURL_CA_BUNDLE`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `GIT_SSL_CAINFO`, `GIT_SSL_CAPATH`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`) that points into `GITHUB_WORKSPACE` |
| `event [event ...]` | `untrusted_event` | (no value) the event is `pull_request_target` or `workflow_run`, or one of the listed events. A list replaces the defaults |

Helpers: `mask` hides a value in the log, `report` prints the annotation, and
`write_output` writes a step output or `GITHUB_ENV` entry with a random
delimiter.

Values are trimmed first, as an action reads its inputs. An empty value passes
because the input was not given. Use validation for required inputs.

## Usage

### As a step

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

`values` is a JSON object, and each name in `checks` is one of its keys. A name
that is not a key is read from the environment. Put the step before any step
that uses the values or handles a secret.

### As a command, from another action in this repository

A consumer's pin downloads this whole repository, so an action here can run
the script next to it without a second pin.

```yaml
- shell: bash --noprofile --norc -p -e -o pipefail {0}
  env:
    IN_REF: ${{ inputs.ref }}
    IN_PATH: ${{ inputs.path }}
  run: |
    trusted_python_names=python3
    . "$GITHUB_ACTION_PATH/../tripwires/trusted-python.sh"
    [[ -n "$trusted_python" ]] || { echo "::error title=my-action: checks could not run::$trusted_python_problem"; exit 1; }
    "$trusted_python" -I "$GITHUB_ACTION_PATH/../tripwires/tripwires.py" --title my-action <<'EOF'
    environment
    no-option IN_REF=ref
    inside    IN_PATH=path
    EOF
```

Three parts stop an earlier step from deciding the result:

- `-p` (privileged mode) makes bash ignore `BASH_ENV`, exported functions and
  `SHELLOPTS`. Plain `shell: bash` runs the `BASH_ENV` file before the first
  line. Start child scripts with `"$BASH" -p script.sh`: `$BASH` is the shell
  the runner started, while a plain `bash` is looked up on a `PATH` that an
  earlier step can change.
- `trusted-python.sh` sets `trusted_python` to the first interpreter on `PATH`
  whose directory, links followed, is outside `GITHUB_WORKSPACE`. It skips a
  virtual environment in the workspace. If there is none, the variable is
  empty, `trusted_python_problem` says why, and the step must stop.
- `-I` stops `PYTHONPATH` and the user site from replacing a module.

`IN_REF=ref` reads the variable `IN_REF` and calls it `ref` in the annotation.
`--consequence "No request was sent."` says what did not happen. Never put an
expression in the checks or the script.

Exit status: 0 when nothing fired, 1 when a check fired, 2 when the checks
could not run (an unknown check, a name with no value, a `trusted-origin`
without origins). Status 2 fails the step too.

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

Each function returns the checked value (`inside` returns the resolved path,
`origin` and `trusted_origin` the normalized origin) or raises `Violation`. The
second argument is a fixed label that goes into the message. Never pass the
value there. `origin` raises `Unsupported` for a harmless URL that is more
than a plain HTTPS origin, which is a case for validation.

## Alerting

GitHub has no API to write to the audit log, so the annotation is the only
record. Its title always ends with `: input not supported`. This suffix is
`ANNOTATION_SUFFIX` in `tripwires.py`. It never changes, and nothing else here
uses it.

To alert from outside the job, with no extra job permissions:

1. Subscribe an organization webhook or GitHub App to `workflow_job`.
2. On `action: completed` with `conclusion: failure`, read the job's
   annotations: `GET /repos/{owner}/{repo}/check-runs/{job_id}/annotations`.
3. Alert on `annotation_level: failure` with a `title` ending in the suffix.

The receiver needs only read access to checks. Step names are not usable: the
`workflow_job` payload shows a composite action as one step.

A second suffix, `: checks could not run` (`CANNOT_RUN_SUFFIX`), marks a step
that stopped because nothing could be checked: no Python outside the
workspace, a bad check line, or an internal error. A runner without Python
causes it too, but so can a `PATH` written to `GITHUB_ENV` that hides the
interpreter. Alert on it where every runner has Python. `cachew-checkout` is
the exception: without Python it skips the environment check and continues,
unless `github-server-url` is set with the job's token.

Limits: GitHub keeps a limited number of annotations per step and job, so
many earlier errors can push this one out. Code already running in the job can
forge an annotation, which gives a false alert, not a missed one.

## Limits

- Needs Python 3.9 or newer on `PATH`, outside the workspace. Standard library
  only. Without it the step fails.
- The checks see values, not what a later step does with them. Pass values
  through `env` even when they pass `shell-safe`.
- `inside` resolves the path when it runs. A symlink created later is not
  covered.
- The actions here start every step with `bash -p`, so a `BASH_ENV` file does
  not run in them. `environment` still reports it, because other steps read it.
- `trusted-python.sh` follows links in each `PATH` directory but not the
  interpreter file itself, because bash cannot read a link without a command
  from `PATH`. Planting such a link takes code that already runs on the runner.
- On Windows the shell line starts Git Bash, as `shell: bash` does. This is
  untested.
- The runner finds the `bash` of the `shell:` line before the action runs,
  looking in `GITHUB_PATH` directories first. A planted `bash` there runs in
  place of the shell, and no check can see it. No single absolute path works
  on Linux, macOS, Windows and containers, so the actions start their scripts
  with `"$BASH"` and list `bash` after `environment`.
- `environment` fires on every exported shell function and on any
  `LD_PRELOAD`. A runner that sets these on purpose cannot use the check.
- `environment` checks `PATH` two ways. An empty or relative entry fires,
  except on Windows. Each listed command (`environment curl jq`) must not
  resolve first inside `GITHUB_WORKSPACE`. List the commands that carry your
  secrets. Do not list `python3` if the job uses a workspace virtual
  environment. A planted command outside the workspace is not detected.
- `LD_LIBRARY_PATH` and `DYLD_*_PATH` are not checked:
  `actions/setup-python` and many builds set them.
- A certificate variable fires only when it points into `GITHUB_WORKSPACE` (a
  relative value counts). Runners behind a TLS-inspecting proxy set them
  elsewhere on purpose. Write a job's own CA to `RUNNER_TEMP`.
- Proxy variables (`HTTPS_PROXY`, `ALL_PROXY`) do not fire. A proxy sees only
  the server name of an HTTPS request, and the certificate checks cover making
  a client trust the proxy.
- `GIT_SSL_NO_VERIFY` does not fire. `cachew-checkout` keeps its tokens off
  unverified requests (see its README).
- `oidc-url` is a second line of defense. The runner resets
  `ACTIONS_ID_TOKEN_REQUEST_URL`, `GITHUB_*` and `RUNNER_*` for every step,
  after `GITHUB_ENV`. Hosts match after parsing: lower case, no userinfo, port
  443 or none, an exact name or a suffix starting with a dot. A listed suffix
  such as `.example.com` trusts every host below it, so list the one name.
- `oidc-claims` compares claims and verifies no signature; the receiver does.
  The strict form (three base64url parts, JSON object header and payload, no
  duplicate members, one audience) keeps this parser and the receiver's from
  reading different tokens. The function `oidc_claims` returns `None` for any
  other form, and the caller decides.
- `event` reads `GITHUB_EVENT_NAME`, which `GITHUB_ENV` cannot change. In a
  reusable workflow it is the caller's event.
- `event` defaults to the two events where GitHub pairs the base repository's
  secrets with outside content: `pull_request_target` and `workflow_run`.
  `issue_comment`, `issues` and `discussion` carry text, not code, and are
  safe until the workflow runs the pull request. List them to refuse them.
- `vault-secrets` lists only `pull_request_target`, so it allows
  `workflow_run`. `hf-oidc-token` refuses both.

## Tests

```sh
python3 -m unittest discover -s actions/tripwires/tests -v
```

The `Test tripwires` workflow runs these on pull requests that touch this
directory, and runs the step on clean and hostile values. `cachew-checkout`,
`vault-secrets` and `hf-oidc-token` use this code, so their test workflows run
on changes here too.

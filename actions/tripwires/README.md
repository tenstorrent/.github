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
| `oidc-claims <name> <audience> [VARIABLE]` | `oidc_claims` | is an OIDC token whose issuer, audience or repository (from `VARIABLE`, default `GITHUB_REPOSITORY`) is not what this job asked for: a token swapped in on the way |
| `environment` | `hostile_environment` | (no value) the environment is prepared to run code in the job's scripts or print their secrets: `BASH_ENV`, `LD_PRELOAD`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`, an exported shell function named like a command, `SHELLOPTS` with `xtrace` or `verbose`, a `PS4` that holds a command, `GIT_TRACE_REDACT` off, `NODE_TLS_REJECT_UNAUTHORIZED=0` |
| `event [event ...]` | `untrusted_event` | (no value) the run's event is `pull_request_target` or `workflow_run`, or one of the listed events |

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
- shell: bash
  env:
    IN_REF: ${{ inputs.ref }}
    IN_PATH: ${{ inputs.path }}
  run: |
    python3 "$GITHUB_ACTION_PATH/../tripwires/tripwires.py" --title my-action <<'EOF'
    no-option IN_REF=ref
    inside    IN_PATH=path
    EOF
```

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

The receiver needs read access to checks, and nothing else. A step name
is not a usable signal: the `workflow_job` payload lists the job's own steps, so
the steps inside a composite action appear only as the one step that called it.

Limits: GitHub keeps a limited number of annotations for each step and job, so
a job that already printed many errors can push this one out; the receiver can
treat "failed, and annotations at the limit" as worth a look. Code that already
runs in the job can also print a forged annotation with this title, which
gives a false alert, not a missed one.

## Requirements and limits

- Python 3.9 or newer on `PATH`, standard library only. Without Python the step
  fails.
- The checks read values. They cannot see what a later step does with them: a
  value that passes `shell-safe` is still best passed through `env`, not written
  into a script.
- `inside` resolves the path when it runs. A step that creates a symlink
  afterward is not covered.
- `environment` runs after bash has already read `BASH_ENV`: it reports that
  the job is compromised, it cannot undo what that file did. Run the command
  with `python3 -I`, so that `PYTHONPATH` and the user site cannot replace its
  modules.
- `environment` fires on `LD_PRELOAD` whatever it loads. A runner that preloads
  a library on purpose (an allocator, say) cannot use this check.
- `oidc-claims` compares claims; it verifies no signature. The receiver does.
- `event` covers the events that give outside code the base repository's
  secrets. It does not judge who may trigger a `workflow_dispatch` or which
  branch runs.

## Tests

```sh
python3 -m unittest discover -s actions/tripwires/tests -v
```

The `Test tripwires` workflow runs them on pull requests that touch this
directory, and runs the step itself on clean and on hostile values.
`cachew-checkout` imports this module, and `vault-secrets` and `hf-oidc-token`
run the command from their `prepare.sh`, so their test workflows run on changes
here too.

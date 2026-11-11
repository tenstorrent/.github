# Actions

Reusable composite actions for the Tenstorrent org. Reference them from any
repository as `tenstorrent/.github/actions/<name>@<ref>`.

| Action | Use it for |
|---|---|
| [`docker-publish`](docker-publish/action.yml) | Building and publishing one image from a Dockerfile |
| [`docker-bake-publish`](docker-bake-publish/action.yml) | Publishing the targets of a `docker buildx bake` file |

Both put every published image through the same pipeline. Nothing is reachable
by tag until all of it has passed.

## What the pipeline does

1. **Build and push by digest only**, with max-mode SLSA provenance and a
   BuildKit SBOM attestation.
2. **Gate every image.** Each platform image must carry the required OCI
   labels, and a Trivy scan must find nothing at the configured severities.
   Trivy reports are uploaded as a workflow artifact, pass or fail.
3. **Enrich the SBOM.** Each platform is rescanned with syft. The describing
   package gets its license, source and supplier from the image's OCI labels,
   and packages get the OS, source-package, supplier and layer data Trivy
   needs to scan the SBOM.
4. **Sign the SBOM** of each platform with `actions/attest` and push the
   Sigstore bundle as an OCI referrer of that platform image.
5. **Copy, then tag.** Every image is copied by digest to any other
   repositories it is tagged in, together with its signed SBOM bundles. Only
   then are the tags applied.

If a gate fails, the images exist only as untagged digests.

## Requirements

- A Linux runner (x64 or arm64) with Docker, `jq`, `curl` and `git`.
- A BuildKit builder. Run `docker/setup-buildx-action` first; the classic
  `docker` driver cannot produce attestations.
- A registry login (`docker/login-action`) for every registry being pushed to.
- Job permissions:

  ```yaml
  permissions:
    contents: read
    packages: write          # pushing to GHCR
    id-token: write          # signing the SBOM
    attestations: write      # storing the attestation
    artifact-metadata: write # only if attest-storage-record is true (default)
  ```

  Attestation in private repositories needs GitHub Enterprise Cloud. Set
  `attest-sbom: "false"` to skip signing.

## docker-publish

```yaml
- uses: docker/setup-buildx-action@<sha>
- uses: docker/login-action@<sha>
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
- id: meta
  uses: docker/metadata-action@<sha>
  with:
    images: ghcr.io/tenstorrent/my-image
- id: publish
  uses: tenstorrent/.github/actions/docker-publish@<ref>
  with:
    tags: ${{ steps.meta.outputs.tags }}
    labels: ${{ steps.meta.outputs.labels }}
    platforms: linux/amd64,linux/arm64
```

`tags` must be fully qualified (`ghcr.io/org/image:tag`). The first tag's
repository is where the image is built and scanned; tags in other repositories
receive an identical copy with the same digest.

Outputs: `digest` (the published index), `image` (`<primary-repo>@<digest>`)
and `build-digest` (the index BuildKit pushed before enrichment, never tagged).

## docker-bake-publish

```yaml
- uses: tenstorrent/.github/actions/docker-bake-publish@<ref>
  env:
    UBUNTU_VERSION: "22.04"
    PYTHON_VERSION: "3.10"
  with:
    bake-file: docker-bake.hcl
    targets: release
    set-lines: |
      *.platform=linux/amd64
```

Targets whose output pushes to a registry are rewritten to push by digest and
go through the pipeline; their `tags` are applied at the end. Targets that do
not push (`type=docker`, local exports) are built unchanged and are not gated.

### Bake variables

The action has no inputs for bake variables. Bake reads a `variable` block's
value from the environment variable of the same name, and `env:` on the step
that uses the action reaches bake, so any variable your bake file declares can
be set as in the example above. Job-level and workflow-level `env:` work too.

```hcl
variable "UBUNTU_VERSION" { default = "22.04" }
```

To change a single target's attribute rather than a variable, use `set-lines`
(for example `app.args.FLAVOR=debug`). `tags` and `output` of pushed targets
are the exception: the action reads them to decide what to publish and then
replaces them, so set those per target, not with a wildcard.

### Migrating from tt-metal's `manual-docker-bake`

The other inputs keep their names. `ubuntu-version` and `python-version` are
gone: move them to `env:` as `UBUNTU_VERSION` and `PYTHON_VERSION`. A caller
that still passes them gets an "unexpected input" warning and the variable is
left at its bake-file default.

Output: `images`, a JSON array with one `{name, repo, digest, build_digest,
tags}` entry per published target (`[]` when no target pushes).

## Inputs shared by both actions

| Input | Default | Meaning |
|---|---|---|
| `required-labels` | `org.opencontainers.image.source`, `.revision`, `.licenses` | Label keys every platform image must carry |
| `trivy-severity` | `CRITICAL,HIGH` | Severities that fail the gate |
| `trivy-scanners` | `vuln,misconfig,secret` | Trivy scanners to run |
| `trivy-ignore-unfixed` | `false` | Ignore vulnerabilities with no fixed version |
| `trivy-ignorefile` | none | Path to a `.trivyignore` of reviewed exceptions |
| `sbom-supplier` | `Organization: Tenstorrent` | SPDX supplier of the describing package |
| `attest-sbom` | `true` | Sign each platform's SBOM and push it as a referrer |
| `attest-storage-record` | `true` | Also create a GitHub artifact storage record |
| `github-token` | `github.token` | Token used to call the attestations API |

See each `action.yml` for the full list.

## Things to know

- **The tag phase is not atomic.** Gating, enrichment, signing and copying all
  finish before the first tag, but tags are separate registry calls. A registry
  failure during tagging can leave some tags applied.
- **Finding the signed SBOM.** `trivy image --sbom-sources oci` and
  `gh attestation verify` find it when given a platform digest
  (`repo@sha256:...`). A tag resolves to the index, which carries a referrer
  only for single-platform images.
- **Large SBOMs are signed without file entries.** `actions/attest` accepts at
  most 16 MiB. An SBOM over that is signed without its file-level entries, and
  its `comment` names the registry blob (`repo@sha256:...`) holding the in-toto
  statement whose predicate is the complete SBOM. Packages, relationships and
  annotations, which are what Trivy reads, are kept. If the SBOM is still too
  large the job fails before anything is signed or tagged.
- **Build args are public.** They are recorded in the provenance attestation.
  Pass secrets with `secrets` or `secret-files`.
- **Tools on `PATH`.** The actions install syft, oras and trivy into
  `$RUNNER_TEMP` and add that directory to `GITHUB_PATH`, so later steps of the
  calling job see them too.
- **Trivy exceptions** belong in a `.trivyignore` in the calling repository,
  passed with `trivy-ignorefile`, so each one is code reviewed.

## Maintaining

- Scripts live in [`docker-publish/scripts`](docker-publish/scripts) and are
  shared by both actions; `bake.sh` is in
  [`docker-bake-publish/scripts`](docker-bake-publish/scripts).
- Composite actions cannot share input definitions, so the inputs above are
  declared in both `action.yml` files. `ruby actions/check-consistency.rb`
  fails if the copies drift, and runs in CI together with shellcheck
  ([`actions-lint.yml`](../.github/workflows/actions-lint.yml)).
- Tool versions and checksums are pinned in
  [`install-tools.sh`](docker-publish/scripts/install-tools.sh). Bump a version
  together with both of its checksums.
- The BuildKit SBOM scanner image is pinned by digest in two places:
  the `sbom-generator` default in `docker-publish/action.yml` and
  `SYFT_SCANNER_DIGEST` in `bake.sh`. Bump both; the consistency check
  compares them.

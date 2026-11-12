# Actions

Reusable composite actions for the Tenstorrent org. Reference them from any
repository as `tenstorrent/.github/actions/<name>@<ref>`.

| Action | Use it for |
|---|---|
| [`docker-publish`](docker-publish/action.yml) | Building and publishing one image from a Dockerfile |
| [`docker-bake-publish`](docker-bake-publish/action.yml) | Publishing the targets of a `docker buildx bake` file |

Both put every published image through the same pipeline. Nothing reaches a
registry until the gates have passed, and nothing is reachable by tag until all
of the pipeline has passed.

## What the pipeline does

1. **Build into a local OCI layout** on the runner, with max-mode SLSA
   provenance and a BuildKit SBOM attestation. Nothing is pushed.
2. **Gate every image.** Each platform image must carry the required OCI
   labels, and a Trivy scan must find nothing at the configured severities.
   Trivy reports are uploaded as a workflow artifact, pass or fail.
3. **Push by digest.** Only once every image has passed are the layouts pushed
   to the repository of each image's first tag, with no tag.
4. **Enrich the SBOM.** Each platform is rescanned with syft into an SPDX 2.3
   SBOM. The describing package gets its license, source and supplier from
   the image's OCI labels. Packages get the OS, source-package, supplier and
   layer data Trivy needs to scan the SBOM, and package checksums from the
   archive hashes syft reads but does not write for most ecosystems (see
   [Why not Trivy out of the box](#why-not-trivy-out-of-the-box)). The
   `org.opencontainers.image.*` labels that all platforms share are copied
   onto the index as annotations, since GitHub's package page reads the
   description, source and license only from there.
5. **Sign the SBOM** of each platform with `actions/attest` and push the
   Sigstore bundle as an OCI referrer of that platform image.
6. **Copy, then tag.** Every image is copied by digest to any other
   repositories it is tagged in, together with its signed SBOM bundles. Only
   then are the tags applied.

If a label check or Trivy fails, or Trivy itself errors, nothing is pushed:
the image never leaves the runner. See
[Failure modes and gotchas](#failure-modes-and-gotchas) for what each failure
leaves behind, and for the one way image content can still leave the runner
before the gate: build cache.

## Failure modes and gotchas

### Build cache is uploaded before the gate runs

> [!WARNING]
> `cache-to` bypasses the gate. BuildKit exports cache **while it builds**,
> before the label check and Trivy run. If `cache-to` points anywhere other
> than the runner (`type=registry`, a bare `ghcr.io/...:cache` reference,
> `type=gha`, `type=s3`, `type=azblob`), the layers of an image that then fails
> the gate are already in that cache, and nothing removes them.

The cache is not a tagged, runnable image, but it holds the same layer blobs,
and anyone who can read the cache location can download them. That includes
whatever Trivy's secret scanner found: a credential baked into a layer reaches
the cache before Trivy flags it.

Both actions print a `::warning::` for every such `cache-to`, including ones
set in a bake file. To keep failing images off the registry entirely:

- Use `cache-from` only (reading cache uploads nothing), `type=inline` (cache
  metadata inside the image, which is pushed only after the gate), or
  `type=local` on a self-hosted runner.
- If you need a shared cache, give it its own private repository, never the
  published one, with read access limited to the build, and expire it.

### What each failure leaves behind

| Fails at | Registry | Tags |
|---|---|---|
| Build (including running out of disk for the OCI layout) | Nothing, apart from build cache (above) | None |
| Label check, Trivy findings, or Trivy erroring (including a failed vulnerability database download) | Nothing, apart from build cache | None |
| Any image in a bake run fails the gate | Nothing for any target, including ones that passed | None |
| Push by digest | Possibly some blobs, or whole images that passed the gate | None |
| SBOM enrichment, signing, copying to other repositories | Images that passed the gate, as untagged digests; signed SBOM bundles if signing ran | None |
| Applying tags | Everything | Possibly some (see below) |

The runner's OCI layouts are deleted when the gate step ends, pass or fail.
Trivy reports are uploaded as an artifact either way.

### Other gotchas

- **The tag phase is not atomic.** Gating, pushing, enrichment, signing and
  copying all finish before the first tag, but tags are separate registry
  calls. A registry failure during tagging can leave some tags applied.
- **Signatures cannot be withdrawn.** An SBOM signed with `actions/attest`
  is recorded in GitHub's attestation store and the public Sigstore
  transparency log (public repositories) even if a later step fails.
- **The same image can pass today and fail tomorrow.** Trivy's vulnerability
  database is not pinned, so a rebuild or re-run can fail on a newly
  published CVE with no code change.
- **Non-pushed bake targets are not gated.** `type=docker` and local exports
  build unchanged; only targets that push to a registry go through the gate.
- **Disk.** Every image to be pushed sits on the runner as an OCI layout until
  the gate passes (see [Requirements](#requirements)).

## Requirements

- A Linux runner (x64 or arm64) with Docker, `jq`, `curl` and `git`.
- A BuildKit builder. Run `docker/setup-buildx-action` first; the classic
  `docker` driver cannot produce attestations.
- Free disk on the runner for the built images: each is exported to
  `$RUNNER_TEMP` as an OCI layout (compressed layers, all platforms) and kept
  until it is pushed. With bake, every pushed target in the run is on disk at
  once. A remote or Kubernetes builder streams the whole image to the runner.
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
and `build-digest` (the index BuildKit built, before enrichment, never tagged).

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

Targets whose output pushes to a registry are rewritten to export a local OCI
layout (keeping exporter options such as compression) and go through the
pipeline; their `tags` are applied at the end. Targets that do
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

- `ubuntu-version` and `python-version` are gone: move them to `env:` as
  `UBUNTU_VERSION` and `PYTHON_VERSION`.
- `oras-image` is gone: oras always comes from the pinned release tarball.
- `syft-scanner-image` must be pinned by digest (`name@sha256:...`) and is
  used exactly as given, without `harbor-prefix`. Leave it empty to use the
  org mirror (see [Tool images](#tool-images)).

A caller that still passes a removed input gets an "unexpected input" warning
and the input has no effect.

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

- **Finding the signed SBOM.** `trivy image --sbom-sources oci` and
  `gh attestation verify` find it when given a platform digest
  (`repo@sha256:...`). A tag resolves to the index, which carries a referrer
  only for single-platform images. Verify with
  `--predicate-type https://spdx.dev/Document`; see
  [Signing](#signing-actionsattest-not-cosign) for why it is not the
  `.../v2.3` type.
- **The full SBOM is also in the registry.** Each platform's
  attestation-manifest in the published index holds the enriched SBOM as an
  in-toto layer with predicate type `https://spdx.dev/Document`, the same
  place BuildKit puts its own. [Cycode](#continuous-monitoring-with-cycode)
  shows how to read it.
- **Large SBOMs are signed without file entries.** `actions/attest` accepts at
  most 16 MiB. An SBOM over that is signed without its file-level entries, and
  its `comment` names the registry blob (`repo@sha256:...`) holding the in-toto
  statement whose predicate is the complete SBOM. Packages, relationships and
  annotations, which are what Trivy reads, are kept. If the SBOM is still too
  large the job fails before anything is signed or tagged.
- **Build args are public.** They are recorded in the provenance attestation.
  Pass secrets with `secrets` or `secret-files`.
- **Tools are pinned, with no fallback.** syft, oras and trivy each come from
  one release tarball whose sha256 is pinned in `install-tools.sh` and checked
  before it is unpacked. There is no alternative source and no reuse of a
  binary already on the runner. The BuildKit SBOM scanner image is pulled by
  digest from the org mirror (see [Tool images](#tool-images)); a scanner
  given as a tag is rejected. Trivy's vulnerability database is the one
  thing that is not pinned: it has to be current to be useful, and Trivy
  fetches it at scan time.
- **Tools on `PATH`.** The actions install syft, oras and trivy into
  `$RUNNER_TEMP` and add that directory to `GITHUB_PATH`, so later steps of the
  calling job see them too.
- **Trivy exceptions** belong in a `.trivyignore` in the calling repository,
  passed with `trivy-ignorefile`, so each one is code reviewed.

## Why not Trivy out of the box

Trivy alone could cover most of this: `trivy image` as the gate, `trivy image
--format spdx-json` for the SBOM, and `cosign attest` to sign it. We use Trivy
for what it does best, the gate, and generate the SBOM with syft instead,
because the SBOM is the provenance and traceability record and Trivy's leaves
out things that record needs. The comparisons below were run with Trivy
0.76.2 and syft 1.57.1 on `python:3.12-slim` (linux/amd64).

### SBOM generator: syft, not Trivy

| | syft + `enrich-sbom.jq` | `trivy image --format spdx-json` |
|---|---|---|
| Software not installed by a package manager | Found by content (the Python interpreter, binaries copied onto `FROM scratch`) | Missing |
| CPEs, for NVD-based scanners | 95 of 95 packages | None |
| Files | Every file, with SHA-1, SHA-256 and the package that owns it | One |
| Image license, source and supplier | From the OCI labels | `NOASSERTION` / `NONE`; labels only as notes |
| `licenseConcluded` | Left to a reviewer, as SPDX intends | Copied from the declared license |
| Supplier | Valid SPDX (`Organization: Name (email)`) | `Name <email>`, not valid SPDX |
| Size | 5.7 MB | 0.2 MB |

Running both and merging was rejected: the two tools name the same package
differently (`bin/registry` vs `github.com/docker/distribution/cmd/registry`,
`stdlib@v1.20.8` vs `stdlib@1.20.8`), so the merge would be lossy and
fragile.

### Making the syft SBOM scan like the image

Trivy's SPDX decoder relies on fields syft does not write. Scanning the raw
syft SBOM with `trivy sbom` found 6 of the 210 vulnerabilities a direct
`trivy image` scan finds. [`enrich-sbom.jq`](docker-publish/scripts/enrich-sbom.jq)
adds them, from data syft already collects:

- an operating-system package that contains every OS package, so Trivy picks
  the right vulnerability database (6 → 31);
- `sourceInfo: built package from: <source> <version>`, because distro
  advisories are keyed by source package (31 → 210, matching the image scan);
- suppliers from package maintainers, and `LayerDiffID` / `LayerDigest`
  annotations naming the layer that introduced each package;
- package checksums (apk, npm/yarn/pnpm/bun/deno, Cargo, Composer, Hex,
  conda) from the archive hashes syft reads but writes to SPDX only for Java,
  Go and opam.

syft also runs with every file hashed (`file.metadata.selection: all`, so
`FROM scratch` images get real digests), with the text of licenses it cannot
map to an SPDX ID embedded for review, and with Go binaries' `(devel)` main
module version guessed from the binary's contents. That guess can be wrong,
and it takes precedence over the commit-based pseudo-version.

Archives nested inside archives (wheels, zips) are not scanned. On the
tt-metal `ubuntu-24.04-ci-build` image, scanning them added 19 entries but
only one new package (the `pip` wheel bundled with `ensurepip`). The rest were
second copies of pip and setuptools, Windows launchers inside their wheels,
and test fixtures.

### Format: SPDX 2.3

- Trivy reads SPDX 2.1 to 2.3 and CycloneDX, but not SPDX 3.0, and
  `actions/attest`'s `sbom-path` input rejects SPDX 3.0.
- SPDX 2.3 is what GitHub's own dependency graph exports.
- CycloneDX was built and compared side by side, then dropped. Trivy got
  identical results from it, but nothing we use needs it, GitHub only stores
  and displays it, and a second, unsigned SBOM next to the signed one leaves
  auditors asking which one counts. If a consumer needs CycloneDX (for
  example Dependency-Track, which reads nothing else), it can be generated
  again for any published image.
- SPDX 2.3 requires a SHA-1 for every file (§8.4), so files carry SHA-1 and
  SHA-256. Verify with SHA-256. Symlinks and other non-regular files have no
  contents to hash; syft gives them an all-zero SHA-1 to satisfy the spec.

### Signing: actions/attest, not cosign

`actions/attest` signs with the workflow's GitHub OIDC identity, so there are
no keys to manage, and the attestations appear on GitHub and verify with
`gh attestation verify`. The SBOM is passed as a custom predicate with type
`https://spdx.dev/Document`, because that exact string is the only SPDX type
Trivy recognizes when it looks for SBOMs in the registry. Passing it as
`sbom-path` would make `actions/attest` set `https://spdx.dev/Document/v2.3`,
which Trivy ignores.

## Continuous monitoring with Cycode

The Trivy gate checks an image once, at publish time. To be alerted about
vulnerabilities disclosed later, import each published image's SBOM into
Cycode, which is meant to re-check stored SBOMs (confirm it does; see the last
point below). The actions do not do this themselves; add a step after the
publish step:

```yaml
- id: publish
  uses: tenstorrent/.github/actions/docker-publish@<ref>
  with:
    tags: ${{ steps.meta.outputs.tags }}
    labels: ${{ steps.meta.outputs.labels }}
    platforms: linux/amd64,linux/arm64

- name: Import SBOMs into Cycode
  shell: bash
  env:
    IMAGE: ${{ steps.publish.outputs.image }}
    VERSION: ${{ steps.meta.outputs.version }}
    CYCODE_CLIENT_ID: ${{ secrets.CYCODE_CLIENT_ID }}
    CYCODE_CLIENT_SECRET: ${{ secrets.CYCODE_CLIENT_SECRET }}
  run: |
    set -euo pipefail
    pip install --quiet cycode==3.27.1
    repo="${IMAGE%@*}"
    index="$(oras manifest fetch "$IMAGE")"
    jq -c '.manifests[] | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")
           | {att: .digest, img: .annotations["vnd.docker.reference.digest"]}' <<< "$index" |
    while read -r m; do
      att="$(jq -r .att <<< "$m")"; img="$(jq -r .img <<< "$m")"
      platform="$(jq -r --arg d "$img" '.manifests[] | select(.digest == $d) | .platform
        | [.os, .architecture, .variant] | map(select(. != null)) | join("/")' <<< "$index")"
      layer="$(oras manifest fetch "${repo}@${att}" | jq -r '
        [.layers[] | select(.annotations["in-toto.io/predicate-type"] == "https://spdx.dev/Document")][0].digest')"
      oras blob fetch --output - "${repo}@${layer}" | jq '.predicate' > sbom.spdx.json
      cycode import sbom \
        --name "${repo} ${VERSION} ${platform}" \
        --vendor Tenstorrent \
        --label "platform:${platform}" --label "digest:${img}" \
        sbom.spdx.json
    done
```

- **Credentials.** Create a Cycode service account and store its client ID
  and secret as the `CYCODE_CLIENT_ID` and `CYCODE_CLIENT_SECRET` secrets.
  For a Cycode tenant outside the US, also set `CYCODE_API_URL` and
  `CYCODE_APP_URL` (for example `https://api.eu.cycode.com` and
  `https://app.eu.cycode.com`).
- **What gets imported.** One SBOM per platform image, the full enriched SPDX
  from the registry. `oras` and `jq` are already on `PATH` after the action
  runs, and the registry login is the one the action used. Each run creates
  new imports, so name them by version, not by branch.
- **Signed SBOMs instead.** To import only an SBOM whose signature checks
  out, replace the `oras blob fetch` line with
  `gh attestation verify "oci://${repo}@${img}" --repo "$GITHUB_REPOSITORY" --predicate-type https://spdx.dev/Document --format json | jq '.[0].verificationResult.statement.predicate' > sbom.spdx.json`
  (with `GH_TOKEN` set). An SBOM over 16 MiB was signed without its file
  entries, which Cycode does not need.
- **docker-bake-publish.** Loop over the `images` output and run the same
  steps for each entry's `repo` and `digest`.
- **The image is already published** when this step runs. A failed import
  fails the job but does not unpublish anything.
- **Check before relying on it.** Cycode's import documentation is behind
  its login. The CLI only uploads the file; Cycode does all parsing on its
  servers. Cimon, Cycode's build agent, uploads SPDX to the same import API
  ([release notes](https://docs.cimon.build/overview/release-notes)), so SPDX
  2.3 is expected to work. Confirm in your tenant that Debian and Alpine
  packages get findings: Trivy finds 210 vulnerabilities in the
  `python:3.12-slim` SBOM. Also confirm that an import picks up a CVE
  disclosed after it was imported, without a re-import.

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
- Image digests live only in [`tool-images.json`](tool-images.json); the
  consistency check fails if a script or `action.yml` hardcodes one.

## Tool images

The BuildKit SBOM scanner runs inside every build, so the org uses one copy of
it that this repository manages. [`tool-images.json`](tool-images.json) pins
the upstream image by digest and names its mirror:

| Image | Upstream | Mirror |
|---|---|---|
| `buildkit-syft-scanner` | `docker.io/docker/buildkit-syft-scanner` | `ghcr.io/tenstorrent/buildkit-syft-scanner` |

Both actions default to `<mirror>@<digest>` from that file.
[`mirror-tool-images.sh`](mirror-tool-images.sh) copies the pinned digest from
upstream to the mirror, and the
[`Mirror tool images`](../.github/workflows/mirror-tool-images.yml) workflow
runs it when the pin file changes. A registry-to-registry copy keeps the
digest, so the mirror is byte-identical to upstream and anyone can check it
against Docker's published image. Upstream is contacted when the pin changes,
not on every build.

To move the org to a new scanner version:

1. Look up the new digest of the upstream tag, for example with
   `docker buildx imagetools inspect docker/buildkit-syft-scanner:stable-1`.
2. Change `digest` in `tool-images.json` in a pull request. The mirror workflow
   runs on the pull request and copies the new digest before anything asks
   for it.
3. Merge. Callers get the new scanner when they move to the new commit of
   this repository.

Things to know:

- The mirror package must be public, because every repository's builds pull
  it. A new package starts private; set its visibility once in the package
  settings. The workflow fails until it is publicly pullable.
- Each mirrored digest also gets a `<tag>-<digest prefix>` tag. Nothing pulls
  by it; it keeps registry cleanup from deleting a digest that is in use.
- To pull the scanner through a cache such as Harbor, pass the same digest
  through it with `syft-scanner-image` or `sbom-generator`. The actions do not
  add a prefix themselves.

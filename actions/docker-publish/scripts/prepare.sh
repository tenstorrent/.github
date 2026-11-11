#!/bin/bash
# Validate docker-publish inputs before anything is built or pushed.
#
# Env: INPUT_TAGS (newline/comma separated), INPUT_BUILDER (optional),
#      INPUT_SBOM_GENERATOR (must be pinned by digest),
#      ATTEST_SBOM (default true)
# Outputs: primary-repo, report-id, tags (normalized, newline separated)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TAGS=()
while IFS= read -r t; do
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [ -n "$t" ] && TAGS+=("$t")
done < <(printf '%s\n' "${INPUT_TAGS}" | tr ',' '\n')

[ "${#TAGS[@]}" -gt 0 ] || die "No tags provided. Pass fully-qualified tags, e.g. ghcr.io/tenstorrent/<image>:<tag> (docker/metadata-action's tags output works as-is)."

for t in "${TAGS[@]}"; do
  require_publishable_tag "$t"
done

parse_ref "${TAGS[0]}"
PRIMARY_REPO="$REF_REPO"

require_attesting_builder "${INPUT_BUILDER:-}"

# The SBOM scanner runs inside the build with access to the image's filesystem.
require_digest_pinned "${INPUT_SBOM_GENERATOR:?}" "sbom-generator"

# Fail before building, not after the scan; attest-sbom.sh checks this again.
if [ "${ATTEST_SBOM:-true}" = true ] && [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  die "SBOM attestation needs 'permissions: id-token: write' (and attestations: write) on the calling job."
fi

log "primary repository: $PRIMARY_REPO"
{
  echo "primary-repo=$PRIMARY_REPO"
  echo "report-id=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  echo "tags<<__TAGS__"
  printf '%s\n' "${TAGS[@]}"
  echo "__TAGS__"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

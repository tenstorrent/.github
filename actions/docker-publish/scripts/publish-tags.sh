#!/bin/bash
# Point every requested tag at the scanned + enriched index. Runs only after all
# gates pass. Tags in other repositories/registries get a full copy of the
# index (images + attestations) via `oras cp`, so the digest is identical
# everywhere, plus the signed SBOM bundles attached to it.
#
# Usage: publish-tags.sh <primary-repo>@<index-digest>
# Env:   INPUT_TAGS (newline separated, already validated by prepare.sh)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="${1:?Usage: $0 <primary-repo>@<index-digest>}"
parse_ref "$SRC"
PRIMARY_REPO="$REF_REPO"
DIGEST="$REF_DIGEST"

# Signed SBOM bundles (attest-sbom.sh) are referrers of the index and platform
# images, so a plain copy of the index leaves them behind. They are copied in
# oras's auto mode, unlike the index: on a registry without the Referrers API
# a bundle is only discoverable through the sha256-<digest> fallback tag, which
# is also what actions/attest creates in the primary repository.
copy_sbom_bundles() {  # <dest-repo>
  local dest="$1" subject ref
  for subject in "$DIGEST" $(oras manifest fetch "$SRC" | jq -r '.manifests[] | select(.platform.os != "unknown") | .digest'); do
    for ref in $(oras discover --format json --artifact-type "$SIGSTORE_BUNDLE_TYPE" "${PRIMARY_REPO}@${subject}" | jq -r '.referrers[]?.digest'); do
      oras cp "${PRIMARY_REPO}@${ref}" "${dest}@${ref}" >&2
      log "copied signed SBOM ${ref} (subject ${subject}) to ${dest}"
    done
  done
}

declare -A TAGS_BY_REPO=()
REPOS=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  parse_ref "$t"
  [ -n "${TAGS_BY_REPO[$REF_REPO]+x}" ] || REPOS+=("$REF_REPO")
  TAGS_BY_REPO[$REF_REPO]="${TAGS_BY_REPO[$REF_REPO]:+${TAGS_BY_REPO[$REF_REPO]},}${REF_TAG}"
done <<< "${INPUT_TAGS}"

for repo in "${REPOS[@]}"; do
  IFS=',' read -r -a tags <<< "${TAGS_BY_REPO[$repo]}"
  if [ "$repo" = "$PRIMARY_REPO" ]; then
    oras tag "${SRC}" "${tags[@]}" >&2
  else
    oras cp --to-distribution-spec "$ORAS_REFERRERS_SPEC" "${SRC}" "${repo}:${TAGS_BY_REPO[$repo]}" >&2
    copy_sbom_bundles "$repo"
  fi
  for tag in "${tags[@]}"; do
    resolved="$(oras resolve "${repo}:${tag}")"
    [ "$resolved" = "$DIGEST" ] || die "${repo}:${tag} resolved to ${resolved}, expected ${DIGEST}."
    log "published ${repo}:${tag}@${DIGEST}"
    echo "- \`${repo}:${tag}@${DIGEST}\`" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  done
done

#!/bin/bash
# Point every requested tag at the scanned + enriched index. Runs only after all
# gates pass. Tags in other repositories/registries get a full copy of the
# index (images + attestations) via `oras cp`, so the digest is identical
# everywhere, plus the signed SBOM bundles attached to it.
#
# Usage: publish-tags.sh <primary-repo>@<index-digest>
# Env:   INPUT_TAGS (newline separated fully-qualified name:tag; validated by
#        prepare.sh or bake.sh), ATTEST_SBOM (default true: copies to other
#        repositories must include at least one signed SBOM bundle)

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
#
# Registry output is captured into variables before looping: a failing command
# substitution in a `for` word list would not trip `set -e`.
SBOM_BUNDLES=()  # "<subject> <bundle-digest>"
find_sbom_bundles() {
  local index subjects subject referrers refs ref
  index="$(oras manifest fetch "$SRC")"
  subjects="$(printf '%s' "$index" | jq -r '.manifests[] | select(.platform.os != "unknown") | .digest')"
  for subject in "$DIGEST" $subjects; do
    referrers="$(oras discover --format json --artifact-type "$SIGSTORE_BUNDLE_TYPE" "${PRIMARY_REPO}@${subject}")"
    refs="$(printf '%s' "$referrers" | jq -r '.referrers[]?.digest')"
    for ref in $refs; do
      SBOM_BUNDLES+=("${subject} ${ref}")
    done
  done
  if [ "${ATTEST_SBOM:-true}" = true ] && [ "${#SBOM_BUNDLES[@]}" -eq 0 ]; then
    die "No signed SBOM bundle found as a referrer of ${SRC} or its platform images; refusing to publish copies without it."
  fi
}

copy_sbom_bundles() {  # <dest-repo>
  local dest="$1" entry subject ref
  for entry in "${SBOM_BUNDLES[@]}"; do
    subject="${entry%% *}"
    ref="${entry#* }"
    oras cp "${PRIMARY_REPO}@${ref}" "${dest}@${ref}" >&2
    log "copied signed SBOM ${ref} (subject ${subject}) to ${dest}"
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

# Look the bundles up before applying any tag, so a missing bundle or a
# registry error fails without leaving a partial set of tags behind.
for repo in "${REPOS[@]}"; do
  if [ "$repo" != "$PRIMARY_REPO" ]; then
    find_sbom_bundles
    break
  fi
done

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

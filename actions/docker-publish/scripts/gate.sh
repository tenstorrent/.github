#!/bin/bash
# Run the compliance gates over every image pushed by digest, then enrich and
# tag them. All images are checked before ANY is tagged, so a multi-target
# build publishes all of its images or none of them.
#
# Usage: gate.sh <images.json>
#   images.json: [{"name": "...", "repo": "...", "digest": "sha256:...", "tags": ["reg/repo:tag", ...]}]
# Env:   INPUT_REQUIRED_LABELS, INPUT_SEVERITY, INPUT_SCANNERS, INPUT_IGNORE_UNFIXED,
#        INPUT_IGNOREFILE, SBOM_SUPPLIER, REPORT_ROOT,
#        ATTEST_SBOM (default true), GITHUB_TOKEN, ATTEST_CREATE_STORAGE_RECORD
# Outputs: images (JSON, digests after enrichment), digest (first image)

set -euo pipefail
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPTS}/lib.sh"

IMAGES_JSON="${1:?Usage: $0 <images.json>}"
REPORT_ROOT="${REPORT_ROOT:?}"
COUNT="$(jq length "$IMAGES_JSON")"
[ "$COUNT" -gt 0 ] || die "No pushed images to gate."

field() { jq -r --argjson i "$1" ".[\$i].$2" "$IMAGES_JSON"; }

FAILED=()
for ((i = 0; i < COUNT; i++)); do
  name="$(field "$i" name)"
  ref="$(field "$i" repo)@$(field "$i" digest)"
  echo "::group::[${name}] verify OCI labels"
  bash "${SCRIPTS}/verify-labels.sh" "$ref" || FAILED+=("${name}: labels")
  echo "::endgroup::"
  echo "::group::[${name}] Trivy scan"
  REPORT_DIR="${REPORT_ROOT}/${name//[^A-Za-z0-9._-]/_}" bash "${SCRIPTS}/trivy-scan.sh" "$ref" || FAILED+=("${name}: trivy")
  echo "::endgroup::"
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '::error::Gate failed: %s\n' "${FAILED[@]}"
  die "Nothing was tagged. Images exist only as untagged digests."
fi

# Enrich and attest every image before tagging any, so a failure on a later
# image cannot leave earlier ones tagged.
sbom_dir=""
trap 'rm -rf "$sbom_dir"' EXIT
DIGESTS=()
for ((i = 0; i < COUNT; i++)); do
  name="$(field "$i" name)"
  repo="$(field "$i" repo)"
  echo "::group::[${name}] enrich SBOM"
  sbom_dir="$(mktemp -d)"
  digest="$(SBOM_OUT_DIR="$sbom_dir" bash "${SCRIPTS}/enrich-sbom.sh" "${repo}@$(field "$i" digest)")"
  if [ "${ATTEST_SBOM:-true}" = true ]; then
    bash "${SCRIPTS}/attest-sbom.sh" "${repo}@${digest}" "${sbom_dir}/sboms.jsonl"
  fi
  rm -rf "$sbom_dir"
  sbom_dir=""
  DIGESTS+=("$digest")
  echo "::endgroup::"
done

echo "### Published" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
RESULT='[]'
for ((i = 0; i < COUNT; i++)); do
  name="$(field "$i" name)"
  repo="$(field "$i" repo)"
  digest="${DIGESTS[$i]}"
  echo "::group::[${name}] publish tags"
  INPUT_TAGS="$(jq -r --argjson i "$i" '.[$i].tags[]' "$IMAGES_JSON")" \
    bash "${SCRIPTS}/publish-tags.sh" "${repo}@${digest}"
  echo "::endgroup::"
  RESULT="$(jq -c --argjson i "$i" --arg d "$digest" --argjson r "$RESULT" \
    '$r + [.[$i] | {name, repo, digest: $d, build_digest: .digest, tags}]' "$IMAGES_JSON")"
done

{
  echo "images=${RESULT}"
  echo "digest=$(printf '%s' "$RESULT" | jq -r '.[0].digest')"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

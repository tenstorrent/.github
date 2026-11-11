#!/bin/bash
# Scan every platform of a built image, still in a local OCI layout and not yet
# pushed anywhere, with Trivy and fail if any finding meets the severity
# threshold. See https://trivy.dev/docs/latest/guide/
#
# Usage: trivy-scan.sh <oci-layout-dir>@<index-digest>
# Env:   INPUT_SEVERITY, INPUT_SCANNERS, INPUT_IGNORE_UNFIXED, INPUT_IGNOREFILE,
#        REPORT_DIR, IMAGE_LABEL (heading for the step summary; default the digest)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF="${1:?Usage: $0 <oci-layout-dir>@<index-digest>}"
LAYOUT="${REF%@*}"
REPORT_DIR="${REPORT_DIR:?}"
mkdir -p "$REPORT_DIR"
VIEWS="$(mktemp -d)"
trap 'rm -rf "$VIEWS"' EXIT

# Trivy exits 1 on fatal errors too, so findings get a distinct code.
FINDINGS_EXIT_CODE=3

SEVERITY="${INPUT_SEVERITY:-CRITICAL,HIGH}"
SCANNERS="${INPUT_SCANNERS:-vuln,misconfig,secret}"

TRIVY_ARGS=(
  --severity "$SEVERITY"
  --scanners "$SCANNERS"
  --exit-code "$FINDINGS_EXIT_CODE"
  --format json
)
[ "${INPUT_IGNORE_UNFIXED:-false}" = true ] && TRIVY_ARGS+=(--ignore-unfixed)
if [ -n "${INPUT_IGNOREFILE:-}" ]; then
  [ -f "$INPUT_IGNOREFILE" ] || die "trivy-ignorefile '${INPUT_IGNOREFILE}' does not exist."
  TRIVY_ARGS+=(--ignorefile "$INPUT_IGNOREFILE")
fi

# `trivy image --input <layout>` only looks at the top-level entries of
# index.json and, for a nested index, scans its first child; --platform is not
# applied. BuildKit's layout has a single top-level entry (the index), so each
# platform gets a view whose index.json lists only that platform's descriptor
# and whose blobs/ is the build layout's.
INDEX_JSON="$(layout_blob "$LAYOUT" "${REF##*@}")"
mapfile -t PLATFORMS < <(printf '%s' "$INDEX_JSON" | index_platforms)
[ "${#PLATFORMS[@]}" -gt 0 ] || die "No platform manifests found in $REF."
mapfile -t DESCRIPTORS < <(printf '%s' "$INDEX_JSON" | jq -c '
  .manifests[] | select((.annotations["vnd.docker.reference.type"] // "") == "")')
[ "${#DESCRIPTORS[@]}" -eq "${#PLATFORMS[@]}" ] || die "Could not pair platforms with manifests in $REF."
for ((p = 0; p < ${#PLATFORMS[@]}; p++)); do
  view="${VIEWS}/${p}"
  mkdir "$view"
  ln -s "$(cd "$LAYOUT" && pwd)/blobs" "${view}/blobs"
  cp "${LAYOUT}/oci-layout" "${view}/oci-layout"
  jq -n --argjson d "${DESCRIPTORS[$p]}" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [$d]}' > "${view}/index.json"
done

{
  echo "### Trivy scan: \`${IMAGE_LABEL:-${REF##*@}}\`"
  echo
  echo "Threshold: \`${SEVERITY}\`, scanners: \`${SCANNERS}\`"
  echo
  echo "| Platform | Result | Findings at threshold |"
  echo "|---|---|---|"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

failed=0
for ((p = 0; p < ${#PLATFORMS[@]}; p++)); do
  platform="${PLATFORMS[$p]}"
  report="${REPORT_DIR}/trivy-${platform//\//-}.json"
  log "scanning ${platform} ($(jq -r .digest <<< "${DESCRIPTORS[$p]}"))"
  status=0
  trivy image "${TRIVY_ARGS[@]}" --output "$report" --input "${VIEWS}/${p}" || status=$?

  if [ "$status" -ne 0 ] && [ "$status" -ne "$FINDINGS_EXIT_CODE" ]; then
    die "Trivy errored scanning ${platform} (exit ${status}); see log above."
  fi
  trivy convert --format table "$report"

  count="$(jq '[.Results[]? | (.Vulnerabilities // []), (.Secrets // []), (.Misconfigurations // []), (.Licenses // []) | length] | add // 0' "$report")"
  if [ "$status" -eq 0 ]; then
    result="pass"
  else
    result="**FAIL**"
    failed=1
  fi
  echo "| \`${platform}\` | ${result} | ${count} |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
done

if [ "$failed" -ne 0 ]; then
  die "Trivy found ${SEVERITY} findings. The image has NOT been pushed to any registry. Fix the findings or add a reviewed exception to the trivy-ignorefile."
fi
log "Trivy scan passed for all platforms."

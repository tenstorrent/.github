#!/bin/bash
# Scan every platform of a built image, still in a local OCI layout and not yet
# pushed anywhere, with Trivy. Secret, misconfiguration and license findings at
# the severity threshold fail the gate. Vulnerabilities at the threshold are
# reported (log, step summary, warning annotation, JSON report) and fail the
# gate only when INPUT_FAIL_ON_VULNS is true. A Trivy error always fails.
# See https://trivy.dev/docs/latest/guide/
#
# Usage: trivy-scan.sh <oci-layout-dir>@<index-digest>
# Env:   INPUT_SEVERITY, INPUT_SCANNERS, INPUT_IGNORE_UNFIXED, INPUT_IGNOREFILE,
#        INPUT_FAIL_ON_VULNS (default false),
#        INPUT_HARBOR_PREFIX (pull-through prefix for Trivy's databases, e.g.
#        'harbor.example.com/'; empty pulls them from upstream),
#        REPORT_DIR, IMAGE_LABEL (heading for the step summary; default the digest)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF="${1:?Usage: $0 <oci-layout-dir>@<index-digest>}"
LAYOUT="${REF%@*}"
REPORT_DIR="${REPORT_DIR:?}"
mkdir -p "$REPORT_DIR"
VIEWS="$(mktemp -d)"
trap 'rm -rf "$VIEWS"' EXIT

SEVERITY="${INPUT_SEVERITY:-CRITICAL,HIGH}"
SCANNERS="${INPUT_SCANNERS:-vuln,misconfig,secret}"
FAIL_ON_VULNS="${INPUT_FAIL_ON_VULNS:-false}"
HARBOR="${INPUT_HARBOR_PREFIX:-}"
scanner_on() { [[ ",${SCANNERS}," == *",$1,"* ]]; }

# No --exit-code: Trivy then exits non-zero only on an error, and which findings
# fail the gate is decided from the JSON report below.
TRIVY_ARGS=(
  --severity "$SEVERITY"
  --scanners "$SCANNERS"
  --format json
)

# --- databases: through the Harbor pull-through cache when given ---
# Trivy tries --db-repository entries in order but moves to the next only on a
# 429 or 5xx; an unreachable Harbor is fatal (checked against 0.76.2). So the
# vulnerability DB is downloaded here first, from Harbor and then from Trivy's
# default upstream repositories, and the scan reuses it with --skip-db-update.
# --download-db-only is a no-op while the cached DB is still current.
# The Java DB and checks bundle are fetched lazily during the scan; they are
# pointed at Harbor only once the DB download proved it is reachable. The Java
# DB list keeps Trivy's defaults behind Harbor; a failed checks bundle pull
# falls back to the checks embedded in the trivy binary.
if scanner_on vuln; then
  if [ -n "$HARBOR" ] && trivy image --download-db-only --no-progress        --db-repository "${HARBOR}ghcr.io/aquasecurity/trivy-db:2"; then
    TRIVY_ARGS+=(
      --java-db-repository "${HARBOR}ghcr.io/aquasecurity/trivy-java-db:1"
      --java-db-repository mirror.gcr.io/aquasec/trivy-java-db:1
      --java-db-repository ghcr.io/aquasecurity/trivy-java-db:1
    )
    scanner_on misconfig && TRIVY_ARGS+=(--checks-bundle-repository "${HARBOR}ghcr.io/aquasecurity/trivy-checks:2")
  else
    [ -n "$HARBOR" ] && echo "::warning::Could not download Trivy's vulnerability DB through '${HARBOR}'; downloading it from upstream."
    trivy image --download-db-only --no-progress || die "Could not download Trivy's vulnerability DB."
  fi
  TRIVY_ARGS+=(--skip-db-update)
elif [ -n "$HARBOR" ] && scanner_on misconfig; then
  TRIVY_ARGS+=(--checks-bundle-repository "${HARBOR}ghcr.io/aquasecurity/trivy-checks:2")
fi
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
  echo "Threshold: \`${SEVERITY}\`, scanners: \`${SCANNERS}\`, vulnerabilities fail the gate: \`${FAIL_ON_VULNS}\`"
  echo
  echo "| Platform | Result | Secrets, misconfigurations, licenses | Vulnerabilities |"
  echo "|---|---|---|---|"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

failed=0
for ((p = 0; p < ${#PLATFORMS[@]}; p++)); do
  platform="${PLATFORMS[$p]}"
  report="${REPORT_DIR}/trivy-${platform//\//-}.json"
  log "scanning ${platform} ($(jq -r .digest <<< "${DESCRIPTORS[$p]}"))"
  status=0
  trivy image "${TRIVY_ARGS[@]}" --output "$report" --input "${VIEWS}/${p}" || status=$?
  [ "$status" -eq 0 ] || die "Trivy errored scanning ${platform} (exit ${status}); see log above."
  trivy convert --format table "$report"

  vulns="$(jq '[.Results[]?.Vulnerabilities // [] | length] | add // 0' "$report")"
  # Misconfigurations lists only failures unless --include-non-failures is set;
  # the Status filter keeps that true if it ever is.
  others="$(jq '[.Results[]? | (.Secrets // []), [.Misconfigurations[]? | select(.Status == "FAIL")], (.Licenses // []) | length] | add // 0' "$report")"
  blocking="$others"
  [ "$FAIL_ON_VULNS" = true ] && blocking=$((blocking + vulns))
  if [ "$blocking" -gt 0 ]; then
    result="**FAIL**"
    failed=1
  else
    result="pass"
  fi
  if [ "$vulns" -gt 0 ] && [ "$FAIL_ON_VULNS" != true ]; then
    echo "::warning title=Trivy vulnerabilities (not gating)::${platform}: ${vulns} ${SEVERITY} vulnerabilities; see the scan log or the uploaded Trivy report."
  fi
  echo "| \`${platform}\` | ${result} | ${others} | ${vulns} |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
done

if [ "$failed" -ne 0 ]; then
  what="secret, misconfiguration or license"
  [ "$FAIL_ON_VULNS" = true ] && what="secret, misconfiguration, license or vulnerability"
  die "Trivy found ${SEVERITY} ${what} findings. The image has NOT been pushed to any registry. Fix the findings or add a reviewed exception to the trivy-ignorefile."
fi
log "Trivy scan passed for all platforms."

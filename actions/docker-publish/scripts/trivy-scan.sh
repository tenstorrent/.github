#!/bin/bash
# Scan every platform of a pushed (but not yet tagged) image with Trivy and
# fail if any finding meets the severity threshold.
# See https://trivy.dev/docs/latest/guide/
#
# Usage: trivy-scan.sh <repo>@<index-digest>
# Env:   INPUT_SEVERITY, INPUT_SCANNERS, INPUT_IGNORE_UNFIXED, INPUT_IGNOREFILE,
#        REPORT_DIR
# Registry auth comes from the docker credential store (docker login).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF="${1:?Usage: $0 <repo>@<index-digest>}"
REPORT_DIR="${REPORT_DIR:?}"
mkdir -p "$REPORT_DIR"

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

mapfile -t PLATFORMS < <(oras manifest fetch "$REF" | index_platforms)
[ "${#PLATFORMS[@]}" -gt 0 ] || die "No platform manifests found in $REF."

{
  echo "### Trivy scan: \`${REF}\`"
  echo
  echo "Threshold: \`${SEVERITY}\`, scanners: \`${SCANNERS}\`"
  echo
  echo "| Platform | Result | Findings at threshold |"
  echo "|---|---|---|"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

failed=0
for platform in "${PLATFORMS[@]}"; do
  report="${REPORT_DIR}/trivy-${platform//\//-}.json"
  log "scanning ${platform}"
  status=0
  trivy image "${TRIVY_ARGS[@]}" --platform "$platform" --output "$report" "$REF" || status=$?

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
  die "Trivy found ${SEVERITY} findings. The image was pushed by digest only and has NOT been tagged. Fix the findings or add a reviewed exception to the trivy-ignorefile."
fi
log "Trivy scan passed for all platforms."

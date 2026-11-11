#!/bin/bash
# Fail unless every platform image carries the OCI labels the SBOM enrichment
# and traceability requirements depend on.
#
# Usage: verify-labels.sh <oci-layout-dir>@<index-digest>
# Env:   INPUT_REQUIRED_LABELS (whitespace/comma separated label keys)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF="${1:?Usage: $0 <oci-layout-dir>@<index-digest>}"
LAYOUT="${REF%@*}"

read -r -a REQUIRED <<< "$(printf '%s' "${INPUT_REQUIRED_LABELS:-}" | tr ',\n' '  ')"
[ "${#REQUIRED[@]}" -gt 0 ] || { log "No required labels configured."; exit 0; }

INDEX_JSON="$(layout_blob "$LAYOUT" "${REF##*@}")"
mapfile -t IMAGE_DIGESTS < <(printf '%s' "$INDEX_JSON" | jq -r '
  .manifests[] | select((.annotations["vnd.docker.reference.type"] // "") == "") | .digest')
[ "${#IMAGE_DIGESTS[@]}" -gt 0 ] || die "No image manifests found in $REF."

missing=0
for d in "${IMAGE_DIGESTS[@]}"; do
  config="$(layout_blob "$LAYOUT" "$d" | jq -r .config.digest)"
  labels="$(layout_blob "$LAYOUT" "$config" | jq -c '.config.Labels // {}')"
  for key in "${REQUIRED[@]}"; do
    value="$(printf '%s' "$labels" | jq -r --arg k "$key" '.[$k] // ""')"
    if [ -z "$value" ]; then
      echo "::error::Image manifest ${d} is missing required label '${key}'."
      missing=1
    else
      log "${d}: ${key}=$(oneline "$value")"
    fi
  done
done

if [ "$missing" -ne 0 ]; then
  die "Required OCI labels are missing. Set them via the 'labels' input (docker/metadata-action's labels output provides source/revision/licenses) or LABEL in the Dockerfile."
fi

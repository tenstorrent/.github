# shellcheck shell=bash disable=SC2034
# Shared helpers for the docker-publish action scripts. Source, don't execute.

log() { echo "[docker-publish] $*" >&2; }
die() { echo "::error::$*" >&2; exit 1; }

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# BuildKit attestation-manifests carry a `subject`. On registries without the
# Referrers API (e.g. GHCR), oras would otherwise create a visible
# `sha256-<digest>` fallback tag for each one; BuildKit itself never does.
ORAS_REFERRERS_SPEC="v1.1-referrers-api"

SIGSTORE_BUNDLE_TYPE="application/vnd.dev.sigstore.bundle.v0.3+json"

# Split an image reference into REF_REPO / REF_TAG / REF_DIGEST.
# Handles registry ports (localhost:5000/img:tag) and name:tag@digest forms.
parse_ref() {
  local ref="$1" last
  REF_DIGEST=""
  REF_TAG=""
  if [[ "$ref" == *@* ]]; then
    REF_DIGEST="${ref#*@}"
    ref="${ref%%@*}"
  fi
  last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    REF_TAG="${last##*:}"
    REF_REPO="${ref%:*}"
  else
    REF_REPO="$ref"
  fi
}

# A repository is fully qualified when its first path component names a
# registry host. Short names (ubuntu, myorg/img) silently resolve to Docker Hub.
is_fully_qualified() {
  local host="${1%%/*}"
  [[ "$1" == */* ]] && { [[ "$host" == *.* ]] || [[ "$host" == *:* ]] || [[ "$host" == localhost ]]; }
}

# Fail unless a tag is a fully-qualified name:tag (no digest). Sets REF_* vars.
require_publishable_tag() {
  parse_ref "$1"
  [ -z "$REF_DIGEST" ] || die "Tag '$1' contains a digest; pass name:tag only."
  [ -n "$REF_TAG" ] || die "Tag '$1' has no tag component."
  is_fully_qualified "$REF_REPO" || die "Tag '$1' is not fully qualified with a registry host (e.g. ghcr.io/...)."
}

# Attestations need a BuildKit driver (docker-container, kubernetes, remote).
# The classic docker driver either errors or silently drops them.
# Usage: require_attesting_builder [builder-name]
require_attesting_builder() {
  local args=() driver
  [ -n "${1:-}" ] && args=(--builder "$1")
  driver="$(docker buildx inspect "${args[@]}" | awk -F': *' '/^Driver:/ {print $2; exit}')"
  log "buildx driver: ${driver:-unknown}"
  if [ "$driver" = docker ]; then
    die "The active buildx builder uses the 'docker' driver, which cannot produce provenance/SBOM attestations. Run docker/setup-buildx-action before this action."
  fi
}

# Print "os/arch[/variant]" for every real platform manifest in an OCI index,
# skipping BuildKit attestation-manifests (platform unknown/unknown).
index_platforms() {
  jq -r '
    .manifests[]
    | select((.annotations["vnd.docker.reference.type"] // "") == "")
    | .platform | [.os, .architecture, .variant] | map(select(. != null and . != "")) | join("/")'
}

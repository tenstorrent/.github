#!/bin/bash
# `docker buildx bake` front end for the docker-bake-publish action.
#
# Accepts the same inputs as tt-metal's manual-docker-bake action. Every target
# whose resolved output pushes to a registry is rewritten to push BY DIGEST to
# the repository of its first tag, with provenance + SBOM attestations forced
# on. Its tags are recorded in images.json and applied only after gate.sh
# passes. Targets that don't push (type=docker, local exports) build unchanged.
#
# Env (see action.yml for descriptions):
#   INPUT_BAKE_FILE, INPUT_TARGETS, INPUT_SET_LINES, INPUT_UBUNTU_VERSION,
#   INPUT_PYTHON_VERSION, INPUT_RETRIES, INPUT_RETRY_DELAY_SECONDS,
#   INPUT_USE_DEFAULT_BUILDER, INPUT_VALIDATE_IMAGES, INPUT_ENABLE_ATTESTATIONS,
#   INPUT_ENRICH_SBOM, INPUT_HARBOR_PREFIX, INPUT_SYFT_SCANNER_IMAGE
#   ATTEST_SBOM  (default true) fail early without id-token: write
#   IMAGES_JSON  path to write [{name, repo, digest, tags}] for gate.sh

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGES_JSON="${IMAGES_JSON:?}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# --- inputs ---
[ "${INPUT_USE_DEFAULT_BUILDER:-false}" = true ] && { docker buildx use default || true; }
[ -n "${INPUT_UBUNTU_VERSION:-}" ] && export UBUNTU_VERSION="$INPUT_UBUNTU_VERSION"
[ -n "${INPUT_PYTHON_VERSION:-}" ] && export PYTHON_VERSION="$INPUT_PYTHON_VERSION"

FILE_ARGS=()
while IFS= read -r f; do
  f="$(trim "$f")"
  [ -n "$f" ] && FILE_ARGS+=(-f "$f")
done < <(printf '%s\n' "${INPUT_BAKE_FILE:-}" | tr ',' '\n')

REQUESTED=()
while IFS= read -r t; do
  t="$(trim "$t")"
  [ -n "$t" ] && REQUESTED+=("$t")
done < <(printf '%s\n' "${INPUT_TARGETS:-}" | tr ',' '\n')
[ "${#REQUESTED[@]}" -gt 0 ] || die "No bake targets provided."

SET_LINES=()
while IFS= read -r s; do
  s="$(trim "$s")"
  [ -n "$s" ] && SET_LINES+=("$s")
done <<< "${INPUT_SET_LINES:-}"

# BuildKit's SBOM scanner: self-hosted copy via Harbor with a direct fallback,
# else an anonymous mirror.gcr.io pull with a docker.io fallback.
if [ -n "${INPUT_SYFT_SCANNER_IMAGE:-}" ]; then
  GENERATOR_PRIMARY="${INPUT_HARBOR_PREFIX:-}${INPUT_SYFT_SCANNER_IMAGE}"
  GENERATOR_FALLBACK="${INPUT_SYFT_SCANNER_IMAGE}"
else
  # Pinned by digest: the scanner runs inside every build with access to the
  # image's filesystem. Keep in sync with docker-publish's sbom-generator
  # default; bump the digest to pick up scanner updates.
  SYFT_SCANNER_DIGEST="sha256:873a7458c3c8ac8e32c7b796c10e1600b07b963d2aa000a72a2d97aaaa2d6315"
  GENERATOR_PRIMARY="mirror.gcr.io/docker/buildkit-syft-scanner:stable-1@${SYFT_SCANNER_DIGEST}"
  GENERATOR_FALLBACK="docker.io/docker/buildkit-syft-scanner:stable-1@${SYFT_SCANNER_DIGEST}"
fi

set_args() { local s; for s in "$@"; do [ -n "$s" ] && printf -- '--set\0%s\0' "$s"; done; return 0; }
bake_print() {  # <set lines...> -> resolved JSON on stdout
  local args=()
  mapfile -d '' -t args < <(set_args "$@")
  docker buildx bake "${FILE_ARGS[@]}" "${args[@]}" --print "${REQUESTED[@]}" 2>"$WORKDIR/print.err" \
    || { cat "$WORKDIR/print.err" >&2; die "docker buildx bake --print failed."; }
}

# --- resolve targets (groups expand) and classify their outputs ---
RESOLVED="$(bake_print "${SET_LINES[@]}")"
mapfile -t TARGETS < <(printf '%s' "$RESOLVED" | jq -r '.target | keys[]')

# Normalizes each output to an object (older buildx prints "type=...,k=v" strings).
# shellcheck disable=SC2016
CLASSIFY_JQ='
  def kv: if type == "string" then (split(",") | map(split("=") | {(.[0]): (.[1:] | join("="))}) | add) else . end;
  .target | to_entries | map(
    (.value.output // [] | map(kv)) as $outs
    | ($outs | map(select(.type == "registry" or (.type == "image" and ((.push // "false") | tostring) == "true")))) as $push
    | {
        name: .key,
        pushed: ($push | length > 0),
        outputs: ($outs | length),
        output: ($push[0] // null),
        tags: ([(.value.tags // [])[] | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(. != "")]
               + (if (.value.tags // []) == [] then [($push[0].name // "") | split(",")[] | select(. != "")] else [] end))
      })'
printf '%s' "$RESOLVED" | jq -c "$CLASSIFY_JQ" > "$WORKDIR/targets.json"

PUSHED=()
LOCAL=()
for t in "${TARGETS[@]}"; do
  info="$(jq -c --arg t "$t" '.[] | select(.name == $t)' "$WORKDIR/targets.json")"
  if [ "$(jq -r .pushed <<< "$info")" = true ]; then
    [ "$(jq -r .outputs <<< "$info")" -eq 1 ] || die "Target '$t' has multiple outputs including a registry push; use a single output."
    [ "$(jq '.tags | length' <<< "$info")" -gt 0 ] || die "Target '$t' pushes to a registry but has no tags."
    while IFS= read -r tag; do require_publishable_tag "$tag"; done < <(jq -r '.tags[]' <<< "$info")
    PUSHED+=("$t")
  else
    LOCAL+=("$t")
  fi
done
log "targets pushed (gated): ${PUSHED[*]:-none}"
log "targets not pushed (built as-is): ${LOCAL[*]:-none}"

if [ "${#PUSHED[@]}" -gt 0 ]; then
  # Fail before building, not after the scan; attest-sbom.sh checks this again.
  if [ "${ATTEST_SBOM:-true}" = true ] && [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    die "SBOM attestation needs 'permissions: id-token: write' (and attestations: write) on the calling job."
  fi
  require_attesting_builder ""
  [ "${INPUT_ENABLE_ATTESTATIONS:-true}" = true ] \
    || echo "::warning::enable-attestations=false is ignored for registry-pushed targets (${PUSHED[*]}); provenance and SBOM are mandatory for published images."
  [ "${INPUT_ENRICH_SBOM:-true}" = true ] \
    || echo "::warning::enrich-sbom=false is ignored; SBOM enrichment is mandatory for published images."
fi

is_pushed() { local p; for p in "${PUSHED[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

# --- drop the caller's tags/output for pushed targets; we own those ---
FILTERED=()
for s in "${SET_LINES[@]}"; do
  pattern="${s%%.*}"
  key="${s#*.}"; key="${key%%=*}"
  case "$key" in
    tags | tags+ | output | output+)
      if is_pushed "$pattern"; then
        continue
      fi
      for p in "${PUSHED[@]}"; do
        # shellcheck disable=SC2053
        [[ "$p" == $pattern ]] && die "--set '${s}' uses a pattern that matches pushed target '$p'; set ${key} per target instead."
      done
      ;;
  esac
  FILTERED+=("$s")
done

# --- overrides: push by digest + attestations ---
OUTPUT_JQ='
  .output | to_entries
  | map(select(.key | IN("type", "name", "push", "push-by-digest", "name-canonical") | not) | "\(.key)=\(.value)")
  | . + ["push-by-digest=true", "name-canonical=true", "push=true"]
  | map(if test("[,\"]") then "\"" + gsub("\""; "\"\"") + "\"" else . end)
  | "type=image," + join(",")'

overrides() {  # <generator-image>
  local t info
  for t in "${PUSHED[@]}"; do
    info="$(jq -c --arg t "$t" '.[] | select(.name == $t)' "$WORKDIR/targets.json")"
    parse_ref "$(jq -r '.tags[0]' <<< "$info")"
    echo "${t}.tags=${REF_REPO}"
    echo "${t}.output=$(jq -r "$OUTPUT_JQ" <<< "$info")"
    echo "${t}.attest=type=provenance,mode=max"
    echo "${t}.attest=type=sbom,generator=$1"
  done
  for t in "${LOCAL[@]}"; do
    if [ "${INPUT_ENABLE_ATTESTATIONS:-true}" = true ]; then
      echo "${t}.attest=type=provenance,mode=max"
      echo "${t}.attest=type=sbom,generator=$1"
    else
      echo "${t}.attest=type=provenance,disabled=true"
      echo "${t}.attest=type=sbom,disabled=true"
    fi
  done
}

PRIMARY_SETS=("${FILTERED[@]}")
mapfile -t -O "${#PRIMARY_SETS[@]}" PRIMARY_SETS < <(overrides "$GENERATOR_PRIMARY")

# Guard against anything (bake file, globs, groups) re-introducing tags.
CHECK="$(bake_print "${PRIMARY_SETS[@]}")"
for t in "${PUSHED[@]}"; do
  parse_ref "$(jq -r --arg t "$t" '.[] | select(.name == $t) | .tags[0]' "$WORKDIR/targets.json")"
  ok="$(printf '%s' "$CHECK" | jq --arg t "$t" --arg repo "$REF_REPO" '
    .target[$t] | (.tags == [$repo])
      and ([.output[] | if type == "string" then test("push-by-digest=true") else (.["push-by-digest"] | tostring) == "true" end] | all)')"
  [ "$ok" = true ] || die "Could not rewrite target '$t' to push by digest; resolved config: $(printf '%s' "$CHECK" | jq -c --arg t "$t" '.target[$t] | {tags, output}')"
done

# --- build: retries, then Harbor -> GHCR direct fallback ---
METADATA="$WORKDIR/metadata.json"
run_bake() {
  local args=()
  mapfile -d '' -t args < <(set_args "$@")
  docker buildx bake "${FILE_ARGS[@]}" "${args[@]}" --metadata-file "$METADATA" "${REQUESTED[@]}"
}

retries="${INPUT_RETRIES:-1}"
delay="${INPUT_RETRY_DELAY_SECONDS:-5}"
ok=false
for ((attempt = 1; attempt <= retries; attempt++)); do
  log "docker buildx bake ${REQUESTED[*]} (attempt ${attempt}/${retries})"
  if run_bake "${PRIMARY_SETS[@]}"; then ok=true; break; fi
  [ "$attempt" -lt "$retries" ] && { log "bake failed, retrying in ${delay}s"; sleep "$delay"; }
done

if [ "$ok" != true ] && [ -n "${INPUT_HARBOR_PREFIX:-}" ]; then
  echo "::warning::Bake failed with Harbor prefix; retrying with GHCR direct (prefix stripped from docker-image:// contexts)."
  FALLBACK_SETS=()
  for s in "${FILTERED[@]}"; do
    FALLBACK_SETS+=("${s//"docker-image://${INPUT_HARBOR_PREFIX}"/"docker-image://"}")
  done
  mapfile -t -O "${#FALLBACK_SETS[@]}" FALLBACK_SETS < <(overrides "$GENERATOR_FALLBACK")
  run_bake "${FALLBACK_SETS[@]}" && ok=true
fi
[ "$ok" = true ] || die "docker buildx bake failed."

# --- record pushed images for the gate ---
PUSHED_JSON="$(printf '%s\n' "${PUSHED[@]}" | jq -R 'select(. != "")' | jq -sc .)"
jq -c --slurpfile meta "$METADATA" --argjson pushed "$PUSHED_JSON" '
  [ .[] | select(.name | IN($pushed[]))
    | . as $t
    | ($meta[0][$t.name]["containerimage.digest"] // "") as $d
    | {name: $t.name, repo: ($t.tags[0] | sub(":[^:/]+$"; "")), digest: $d, tags: $t.tags} ]
' "$WORKDIR/targets.json" > "$IMAGES_JSON"
[ "$(jq length "$IMAGES_JSON")" -eq "${#PUSHED[@]}" ] || die "Could not record every pushed target in ${IMAGES_JSON}."
if jq -e 'any(.[]; .digest == "")' "$IMAGES_JSON" >/dev/null; then
  die "bake metadata is missing a digest for: $(jq -r '[.[] | select(.digest == "") | .name] | join(", ")' "$IMAGES_JSON")"
fi
jq -r '.[] | "[docker-publish] pushed \(.name): \(.repo)@\(.digest) (pending tags: \(.tags | join(", ")))"' "$IMAGES_JSON" >&2

# --- validate docker-loaded local targets ---
if [ "${INPUT_VALIDATE_IMAGES:-true}" = true ]; then
  for t in "${LOCAL[@]}"; do
    tag="$(printf '%s' "$RESOLVED" | jq -r --arg t "$t" '
      .target[$t] | select([.output[]? | if type == "string" then test("type=docker") else .type == "docker" end] | any)
      | (.tags // [])[0] // empty')"
    [ -n "$tag" ] || continue
    docker image inspect "$tag" >/dev/null 2>&1 || die "Local image for target '$t' (${tag}) is not inspectable after build."
    log "local image validated: ${tag}"
  done
fi

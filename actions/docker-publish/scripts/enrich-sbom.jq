# Add the per-package fields syft's SPDX output leaves out but Trivy's SPDX
# decoder (pkg/sbom/spdx/unmarshal.go, pkg/sbom/io/decode.go) relies on:
#
#   - an SPDXRef-OperatingSystem-* package named after Trivy's OS family, which
#     CONTAINS every OS package. Without it Trivy cannot pick a vulnerability
#     database and reports almost nothing for OS packages.
#   - sourceInfo "built package from: <src-name> <src-version>". Distro
#     advisories are keyed by source package (openssl, not libssl3t64).
#   - supplier from the package maintainer where syft left NOASSERTION.
#   - "LayerDiffID: ..." / "LayerDigest: ..." annotations recording which image
#     layer each package came from.
#
# Input: syft spdx-json. Args: --slurpfile syft <syft-json of the same scan>,
# --arg annotator "Tool: <name>".

def trivy_os_family:
  {
    "debian": "debian", "ubuntu": "ubuntu", "alpine": "alpine",
    "rhel": "redhat", "centos": "centos", "rocky": "rocky", "almalinux": "alma",
    "ol": "oracle", "amzn": "amazon", "fedora": "fedora", "photon": "photon",
    "wolfi": "wolfi", "chainguard": "chainguard", "azurelinux": "azurelinux",
    "mariner": "cbl-mariner", "sles": "sles", "sle-micro": "slem",
    "opensuse-leap": "opensuse-leap", "opensuse-tumbleweed": "opensuse-tumbleweed",
    "bottlerocket": "bottlerocket", "echo": "echo", "minimos": "minimos"
  }[.] // null;

def b64json: if . == null or . == "" then null else (@base64d | fromjson) end;

# "Name <email>" -> SPDX "Name (email)"
def spdx_actor: sub("\\s*<(?<e>[^>]*)>\\s*$"; " (\(.e))");

def source_package($a):
  if $a.type == "deb" then
    "\(($a.metadata.source // "") | if . == "" then $a.name else . end) \(($a.metadata.sourceVersion // "") | if . == "" then $a.version else . end)"
  elif $a.type == "apk" then
    "\($a.metadata.originPackage // $a.name) \($a.version)"
  elif $a.type == "rpm" and (($a.metadata.sourceRpm // "") != "") then
    # [...] | first: a non-matching sourceRpm (e.g. "(none)") must yield null,
    # not empty, or the caller's map() drops the whole package.
    ([$a.metadata.sourceRpm | sub("\\.src\\.rpm$"; "") | capture("^(?<n>.+)-(?<v>[^-]+)-(?<r>[^-]+)$")?] | first) as $s
    | if $s then "\($s.n) \(if $a.metadata.epoch != null then "\($a.metadata.epoch):" else "" end)\($s.v)-\($s.r)" else null end
  else null end;

($syft[0]) as $sj
| ($sj.artifacts | map({key: .id, value: .}) | from_entries) as $art
| ($sj.source.metadata.manifest | b64json) as $manifest
| ($sj.source.metadata.config | b64json) as $config
| (if $manifest and $config
   then [$config.rootfs.diff_ids, [$manifest.layers[].digest]] | transpose | map({key: .[0], value: .[1]}) | from_entries
   else {} end) as $layer_digest
| ($config.rootfs.diff_ids // []) as $layer_order
| ($sj.files // [] | map({key: .id, value: .location.layerID}) | from_entries) as $file_layer
| ($sj.artifactRelationships // [] | map(select(.type == "contains")) | group_by(.parent)
   | map({key: .[0].parent, value: [.[].child]}) | from_entries) as $owned_files
# A package's primary evidence (e.g. /var/lib/dpkg/status) lives in whichever
# layer last rewrote the package DB, so it names the wrong layer for anything
# installed earlier. The earliest layer holding one of its own files is the
# layer that introduced it.
| def introduced_layer($a):
    ([($owned_files[$a.id] // [])[] | $file_layer[.] // empty] | unique
     | map({l: ., i: (. as $l | $layer_order | index($l))}) | sort_by(.i) | .[0].l)
    // ([$a.locations[]? | select(.annotations.evidence == "primary") | .layerID][0])
    // $a.locations[0].layerID // null;
  .
| (.creationInfo.created) as $date
| def ann($c): {annotationDate: $date, annotationType: "OTHER", annotator: $annotator, comment: $c};
  ($sj.distro.id // "" | trivy_os_family) as $family
| ($sj.distro.versionID // "") as $os_version
| ([.relationships[]? | select(.spdxElementId == "SPDXRef-DOCUMENT" and .relationshipType == "DESCRIBES")][0].relatedSpdxElement) as $root
| ("SPDXRef-OperatingSystem-" + ("\($family)-\($os_version)" | gsub("[^A-Za-z0-9.-]"; "-"))) as $os_id
| ($family != null and $os_version != "" and ([.packages[].SPDXID | select(startswith("SPDXRef-OperatingSystem"))] | length == 0)) as $add_os

| .packages |= map(
    ($art[.SPDXID | split("-") | last] // null) as $a
    | if $a == null then . else
        introduced_layer($a) as $diff
        | source_package($a) as $src
        | (if $diff then .annotations = ((.annotations // [])
              + [ann("LayerDiffID: \($diff)")]
              + (if $layer_digest[$diff] then [ann("LayerDigest: \($layer_digest[$diff])")] else [] end))
           else . end)
        | (if ((.supplier // "NOASSERTION") == "NOASSERTION") and (($a.metadata.maintainer // "") != "")
           then .supplier = "Organization: \($a.metadata.maintainer | spdx_actor)" else . end)
        | (if $src then
             (if (.sourceInfo // "") != "" and .comment == null then .comment = .sourceInfo else . end)
             | .sourceInfo = "built package from: \($src)"
           else . end)
      end)

| if $add_os and $root then
    .packages += [{
      SPDXID: $os_id, name: $family, versionInfo: $os_version,
      downloadLocation: "NONE", filesAnalyzed: false, primaryPackagePurpose: "OPERATING-SYSTEM"
    }]
    | .relationships += [{spdxElementId: $root, relationshipType: "CONTAINS", relatedSpdxElement: $os_id}]
      + [.packages[] | select(($art[.SPDXID | split("-") | last].type // "") | IN("deb", "apk", "rpm"))
         | {spdxElementId: $os_id, relationshipType: "CONTAINS", relatedSpdxElement: .SPDXID}]
  else . end

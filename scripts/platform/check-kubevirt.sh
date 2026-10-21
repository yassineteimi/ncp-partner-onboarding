#!/usr/bin/env bash
#
# Free checks for use case 7, before anything reaches a cluster:
#
#   1. the vendored operator manifest is byte for byte the v1.9.1 release asset
#   2. kustomize builds, virt-operator lands on the CPU worker as one replica,
#      and every KubeVirt image, the ones the operator deploys included, is
#      pinned by digest
#   3. every field of the KubeVirt and VirtualMachine objects exists in
#      KubeVirt's own OpenAPI spec at v1.9.1 (their CRDs only exist once the
#      operator runs, so a server-side dry run can't check them yet)
#   4. with DRY_RUN=server, everything else passes a server-side dry run on
#      par: the operator, its CRD, RBAC, the wait Job, the tenant's quota and
#      Service (needs kubeconfig-par, changes nothing)
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools kubectl python3 curl shasum

VERSION=v1.9.1
SHA256=9ac45a436c49d32e6fc21d542bcb7600b970705297b9e6752f3ef9b0a1d292da
DIR="$REPO_ROOT/gitops/manifests/platform/kubevirt"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"

log "1. vendored operator manifest"
echo "$SHA256  $DIR/upstream/kubevirt-operator-$VERSION.yaml" | shasum -a 256 -c -

log "2. kustomize build"
kubectl kustomize "$DIR" > "$OUT/kubevirt.yaml"
python3 - "$OUT/kubevirt.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
op = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "virt-operator"][0]
spec = op["spec"]["template"]["spec"]
assert op["spec"]["replicas"] == 1, "virt-operator replicas"
assert spec["nodeSelector"].get("eu1.io/pool") == "cpu", "virt-operator nodeSelector"
assert "nodeAffinity" not in spec.get("affinity", {}), "virt-operator still requires a control-plane node"
kinds = sorted({d["kind"] for d in docs})
print("ok   virt-operator: 1 replica, eu1.io/pool=cpu, no control-plane affinity")
print("     kinds:", ", ".join(kinds))
PY

# Every image reference, and every *_IMAGE env value virt-operator turns into
# a component's image, must carry a digest. A tag alone would let quay.io
# change what runs.
check_images() {
  python3 - "$1" <<'PY'
import sys, yaml
OPERANDS = ["VIRT_OPERATOR_IMAGE", "VIRT_API_IMAGE", "VIRT_CONTROLLER_IMAGE", "VIRT_HANDLER_IMAGE",
            "VIRT_LAUNCHER_IMAGE", "VIRT_EXPORTPROXY_IMAGE", "VIRT_EXPORTSERVER_IMAGE",
            "VIRT_SYNCHRONIZATIONCONTROLLER_IMAGE", "GS_IMAGE", "PR_HELPER_IMAGE", "SIDECAR_SHIM_IMAGE"]
errors, refs = [], 0

def walk(obj, path):
    global refs
    if isinstance(obj, dict):
        for k, v in obj.items():
            walk(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            walk(v, f"{path}[{i}]")
    elif isinstance(obj, str) and obj.startswith(("quay.io/", "docker.io/", "alpine/")) and " " not in obj:
        refs += 1
        if "@sha256:" not in obj:
            errors.append(f"{path}: {obj} has no digest")

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for d in docs:
    walk(d, f"{d['kind']}/{d['metadata']['name']}")
op = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "virt-operator"][0]
env = {e["name"]: e.get("value", "") for e in op["spec"]["template"]["spec"]["containers"][0]["env"]}
for name in OPERANDS:
    if "@sha256:" not in env.get(name, ""):
        errors.append(f"virt-operator env {name}: missing or not a digest")
for e in errors:
    print("FAIL", e)
if errors:
    sys.exit(1)
print(f"ok   {refs} image references, all by digest, and {len(OPERANDS)} component images set on virt-operator")
PY
}
check_images "$OUT/kubevirt.yaml" || die "an image without a digest, see above"

log "3. KubeVirt and VirtualMachine fields against KubeVirt's OpenAPI spec at $VERSION"
curl -sfL -o "$OUT/swagger.json" "https://raw.githubusercontent.com/kubevirt/kubevirt/$VERSION/api/openapi-spec/swagger.json"
FIELDS="$OUT/kubevirt.yaml"
if [ "${BREAK:-0}" = 1 ]; then
  # So must a component image back on its bare tag.
  sed -E 's#quay\.io/kubevirt/virt-launcher@sha256:[0-9a-f]+#quay.io/kubevirt/virt-launcher:v1.9.1#' "$OUT/kubevirt.yaml" > "$OUT/tagged.yaml"
  if check_images "$OUT/tagged.yaml"; then
    die "BREAK=1: virt-launcher by tag passed the image check"
  fi
  log "virt-launcher by tag was caught, as it should be"
  # A misspelt field must fail the check, or the check proves nothing.
  sed 's/evictionStrategy:/evictionStrateg:/; s/useEmulation:/useEmulaton:/' "$OUT/kubevirt.yaml" > "$OUT/broken.yaml"
  FIELDS="$OUT/broken.yaml"
fi
if ! python3 - "$FIELDS" "$OUT/swagger.json" <<'PY'
import json, sys, yaml
defs = json.load(open(sys.argv[2]))["definitions"]
errors = []

def resolve(schema):
    while "$ref" in schema:
        schema = defs[schema["$ref"].split("/")[-1]]
    return schema

def walk(obj, schema, path):
    schema = resolve(schema)
    if isinstance(obj, dict):
        props = schema.get("properties")
        if props is None:
            extra = schema.get("additionalProperties")
            if isinstance(extra, dict):
                for k, v in obj.items():
                    walk(v, extra, f"{path}.{k}")
            return
        for k, v in obj.items():
            if k not in props:
                errors.append(f"{path}.{k}: no such field")
            else:
                walk(v, props[k], f"{path}.{k}")
    elif isinstance(obj, list):
        items = schema.get("items")
        if items:
            for i, v in enumerate(obj):
                walk(v, items, f"{path}[{i}]")

checked = 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("apiVersion") == "kubevirt.io/v1" and d["kind"] in ("KubeVirt", "VirtualMachine"):
        walk(d["spec"], defs[f"v1.{d['kind']}"]["properties"]["spec"], f"{d['kind']}/{d['metadata']['name']}.spec")
        checked += 1
for e in errors:
    print("FAIL", e)
if errors or checked != 2:
    sys.exit(f"{len(errors)} unknown fields, {checked} objects checked")
print(f"ok   {checked} objects, every field known to KubeVirt {sys.argv[2].split('/')[-1]}")
PY
then
  [ "${BREAK:-0}" = 1 ] || die "unknown fields, see above"
  log "the misspelt fields were caught, as they should be"
  exit 0
fi
[ "${BREAK:-0}" = 1 ] && die "BREAK=1: the misspelt fields passed the check"

if [ "${DRY_RUN:-}" = server ]; then
  log "4. server-side dry run on par, without the objects whose CRDs the operator creates"
  use_site par
  require_kubeconfig
  python3 - "$OUT/kubevirt.yaml" "$OUT/dry-run.yaml" <<'PY'
import sys, yaml
keep = [d for d in yaml.safe_load_all(open(sys.argv[1]))
        if d and not (d.get("apiVersion") == "kubevirt.io/v1")]
# Objects in namespaces this sync creates are checked in kube-system, which
# exists, since a dry run creates no namespace.
for d in keep:
    if d["metadata"].get("namespace") in ("kubevirt", "tenant-vm"):
        d["metadata"]["namespace"] = "kube-system"
keep = [d for d in keep if d["kind"] != "Namespace"]
yaml.safe_dump_all(keep, open(sys.argv[2], "w"))
PY
  kubectl_cp apply --dry-run=server --server-side --field-manager=ws-platform-dry-run -f "$OUT/dry-run.yaml"
  kubectl_cp apply --dry-run=server -f "$REPO_ROOT/gitops/apps/par/platform/kubevirt.yaml"
fi

log "all KubeVirt checks passed"

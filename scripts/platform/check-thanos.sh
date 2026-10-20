#!/usr/bin/env bash
#
# Free checks for use case 6, before anything reaches a cluster:
#
#   1. every Thanos flag in the manifests exists in the pinned binary's --help
#   2. the endpoint config parses (thanos query started for a few seconds)
#   3. the manifests build with kustomize, and the dashboard is valid JSON
#   4. kube-prometheus-stack 91.4.1 renders on both sites with the lane
#      overlays, and the rendered Prometheus and Grafana objects say what the
#      overlays meant
#   5. with DRY_RUN=server, every rendered object passes a server-side dry
#      run against par's API server (needs kubeconfig-par, changes nothing)
#
# Needs thanos v0.42.4 on PATH, the same version the manifests pin.
# Renders are left in $OUT (default: a temporary directory) for inspection.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools thanos kubectl helm python3

THANOS_VERSION=0.42.4
KPS_VERSION=91.4.1
MANIFESTS="$REPO_ROOT/gitops/manifests/platform"
VALUES="$REPO_ROOT/gitops/values"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
log "renders go to $OUT"

thanos --version 2>&1 | grep -q "version $THANOS_VERSION " \
  || die "thanos on PATH is not $THANOS_VERSION: $(thanos --version 2>&1 | head -n1)"

########################################
# 3. Kustomize builds, first, so 1 can read the rendered args
########################################

log "kustomize build of thanos and gpu-rules"
kubectl kustomize "$MANIFESTS/thanos" > "$OUT/thanos.yaml"
kubectl kustomize "$MANIFESTS/gpu-rules" > "$OUT/gpu-rules.yaml"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
  "$MANIFESTS/thanos/dashboards/eu1-gpus-across-sites.json"
log "dashboard JSON parses"

########################################
# 1. Flags against the binary
########################################

# Every "- --flag" under a thanos container, with the subcommand above it.
python3 - "$OUT/thanos.yaml" > "$OUT/flags.txt" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc or doc.get("kind") not in ("StatefulSet", "Deployment"):
        continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if "quay.io/thanos/thanos" not in c["image"]:
            continue
        cmd, *args = c["args"]
        for a in args:
            print(cmd, a.split("=", 1)[0])
PY
missing=0
while read -r cmd flag; do
  # Boolean flags are listed as --[no-]name.
  name="${flag#--}"
  if ! thanos "$cmd" --help 2>&1 | grep -qE -- "--(\[no-\])?${name//./\\.}([=[:space:]]|$)"; then
    warn "thanos $cmd has no $flag"
    missing=1
  fi
done < "$OUT/flags.txt"
[ "$missing" = 0 ] || die "unknown flags, see above"
log "$(wc -l < "$OUT/flags.txt" | tr -d ' ') thanos flags exist in v$THANOS_VERSION"

########################################
# 2. Endpoint config parses
########################################

python3 - "$OUT/thanos.yaml" > "$OUT/endpoints.yaml" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "thanos-query-endpoints":
        print(doc["data"]["endpoints.yaml"])
PY
thanos query --http-address=127.0.0.1:0 --grpc-address=127.0.0.1:0 \
  --endpoint.sd-config-file="$OUT/endpoints.yaml" > "$OUT/query.log" 2>&1 &
QPID=$!
sleep 4
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
if grep -qiE 'err.*(parse|unmarshal|yaml|endpoint config)' "$OUT/query.log"; then
  cat "$OUT/query.log"
  die "thanos query rejected the endpoint config"
fi
grep -q 'starting query node' "$OUT/query.log" || { cat "$OUT/query.log"; die "thanos query did not start"; }
log "thanos query starts with the endpoint config"

########################################
# 4. kube-prometheus-stack with the overlays
########################################

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
for site in par fin; do
  log "helm template kube-prometheus-stack $KPS_VERSION for $site"
  helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version "$KPS_VERSION" --namespace monitoring \
    -f "$VALUES/base/kube-prometheus-stack.yaml" \
    -f "$VALUES/base/kube-prometheus-stack-$site.yaml" \
    -f "$VALUES/platform/kube-prometheus-stack-$site.yaml" \
    > "$OUT/kps-$site.yaml"
done

python3 - "$OUT" <<'PY'
import sys, yaml
out = sys.argv[1]

def docs(site):
    return [d for d in yaml.safe_load_all(open(f"{out}/kps-{site}.yaml")) if d]

def one(ds, kind, name=None):
    found = [d for d in ds if d["kind"] == kind and (name is None or d["metadata"]["name"] == name)]
    assert len(found) == 1, f"expected one {kind} {name or ''}, found {len(found)}"
    return found[0]

fails = []
def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)

par, fin = docs("par"), docs("fin")

p = one(par, "Prometheus")["spec"]
check(p.get("externalLabels", {}).get("site") == "par", "par Prometheus keeps site=par")
t = p.get("thanos", {})
check(t.get("image", "").startswith("quay.io/thanos/thanos:v0.42.4@sha256:"), "par sidecar image pinned by digest")
osc = t.get("objectStorageConfig", {})
check(osc == {"name": "thanos-objstore", "key": "objstore.yml"}, "par sidecar uploads with monitoring/thanos-objstore")
check(p.get("retention") == "15d", "par keeps 15 days locally")
svc = [d for d in par if d["kind"] == "Service" and d["metadata"]["name"].endswith("-thanos-discovery")]
check(len(svc) == 1 and svc[0]["metadata"]["name"] == "kube-prometheus-stack-thanos-discovery",
      "sidecar Service is kube-prometheus-stack-thanos-discovery, as query.yaml expects")
if svc:
    ports = {pt["name"]: pt["port"] for pt in svc[0]["spec"]["ports"]}
    check(ports.get("grpc") == 10901, "sidecar Service exposes grpc 10901")
ds = [d for d in par if d["kind"] == "Secret" and "datasource" in d["metadata"]["name"]] + \
     [d for d in par if d["kind"] == "ConfigMap" and "datasource" in d["metadata"]["name"]]
blob = "".join(str(d.get("data", {})) + str(d.get("stringData", {})) for d in ds)
check("thanos-eu1" in blob and "thanos-query.thanos.svc:9090" in blob, "Grafana gets the Thanos (EU1) data source")

f = one(fin, "Prometheus")["spec"]
check(f.get("externalLabels", {}).get("site") == "fin", "fin Prometheus keeps site=fin")
check("thanos" not in f, "fin has no sidecar")
rw = f.get("remoteWrite", [])
check(len(rw) == 1, "fin has exactly one remote write")
if rw:
    r = rw[0]
    check(r["url"] == "https://51.159.176.50:30291/api/v1/receive", "fin writes to the CPU worker's NodePort over https")
    tls = r.get("tlsConfig", {})
    check(tls.get("serverName") == "thanos-receive.eu1.internal", "fin verifies the server name in Receive's certificate")
    check(tls.get("keySecret", {}).get("name") == "thanos-remote-write", "fin's client key comes from thanos-remote-write")
check(not any(d["kind"] == "Deployment" and "grafana" in d["metadata"]["name"] for d in fin), "no Grafana on fin")

sys.exit(1 if fails else 0)
PY
log "rendered kube-prometheus-stack objects match the overlays"

########################################
# 5. Server-side dry run on par
########################################

if [ "${DRY_RUN:-}" = server ]; then
  use_site par
  require_kubeconfig
  # A dry run creates nothing, so objects in the fin-sim namespace, which only
  # this Application creates, would fail on a missing namespace. They are
  # validated in the thanos namespace instead, which exists.
  python3 - "$OUT/thanos.yaml" "$OUT/thanos-dry-run.yaml" <<'PY'
import sys, yaml
out = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d:
        continue
    if d["kind"] == "Namespace" and d["metadata"]["name"] == "fin-sim":
        continue
    if d["metadata"].get("namespace") == "fin-sim":
        d["metadata"]["namespace"] = "thanos"
    out.append(d)
yaml.safe_dump_all(out, open(sys.argv[2], "w"))
PY
  log "server-side dry run on par: thanos (fin-sim objects in namespace thanos) and gpu-rules"
  kubectl_cp apply --dry-run=server -f "$OUT/thanos-dry-run.yaml"
  kubectl_cp apply --dry-run=server -f "$OUT/gpu-rules.yaml"
  log "server-side dry run on par: the Prometheus objects rendered for par and for fin"
  for site in par fin; do
    python3 - "$OUT/kps-$site.yaml" > "$OUT/prometheus-$site.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "Prometheus":
        print("---"); print(yaml.safe_dump(d))
PY
    kubectl_cp apply --dry-run=server --server-side --force-conflicts \
      --field-manager=ws-platform-dry-run -f "$OUT/prometheus-$site.yaml"
  done
  for f in "$REPO_ROOT"/gitops/apps/par/platform/*.yaml; do
    kubectl_cp apply --dry-run=server -f "$f"
  done
fi

log "all checks passed"

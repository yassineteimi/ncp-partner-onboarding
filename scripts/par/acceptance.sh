#!/usr/bin/env bash
#
# Acceptance of a site's GPU node: Part 1's acceptance test, plus the versions
# actually running on the node. W1 step 2 on par's L4, W2 at node Ready on
# fin's 2x H200.
#
# The criteria, from Part 1's docs/01-platform.md:
#   1. a cuda-vectoradd pod reaches Completed with "Test PASSED"
#   2. nvidia-smi inside a CUDA container shows the GPU and the expected driver
#   3. the node advertises every GPU of its type (1 on par, 2 on fin)
#   4. the node carries feature.node.kubernetes.io/pci-10de.present=true
# And for this project's evidence (rule 10): the driver, DCGM exporter and
# device plugin images the GPU Operator actually runs, read from the pods.
#
# The expected driver differs by owner (ADR 0002): on par it is the version
# pinned in Git for the GPU Operator; on fin it is the one the provider image
# reported at boot, in the newest image inventory gpu-up.sh saved.
#
# fin's node is still in staging at this point (use case 2), so on fin the two
# pods get a toleration for eu1.io/staging when they are applied. They are
# platform test fixtures, like NVCRE's jobs, not tenants. The pods are applied
# directly and deleted at the end rather than committed to gitops/. The
# cluster is left as ArgoCD put it.
#
#   make par-acceptance
#   make fin-acceptance

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site "${SITE:-par}"

require_tools kubectl grep sed jq
require_kubeconfig

NS="gpu-acceptance"
MANIFESTS="$REPO_ROOT/workloads/acceptance"
case "$SITE" in
  par)
    GPU_NODE="$(tf_output gpu_node_name)"
    EXPECTED_GPUS=1 PRODUCT=L4 DRIVER_SOURCE="pinned in Git"
    PINNED_DRIVER="$(grep -E '^\s+version: "' "$REPO_ROOT/gitops/values/base/gpu-operator-par.yaml" | head -n1 | sed -E 's/.*"(.*)".*/\1/')"
    ;;
  fin)
    GPU_NODE="$(tf_output gpu_name)"
    EXPECTED_GPUS=2 PRODUCT=H200 DRIVER_SOURCE="reported by the provider image at boot"
    # Names carry a UTC timestamp, so the glob's last match is the newest.
    INVENTORY=""
    for f in "$ARTIFACTS"/image-inventory-*.txt; do
      case "$f" in *-rehearsal.txt) ;; *) [ -e "$f" ] && INVENTORY="$f" ;; esac
    done
    [ -n "$INVENTORY" ] || die "no image inventory in ${ARTIFACTS#"$REPO_ROOT"/}. make fin-gpu-up writes it."
    PINNED_DRIVER="$(sed -n 's/^driver_version=//p' "$INVENTORY" | head -n1)"
    ;;
esac
[ -n "$GPU_NODE" ] || die "terraform/$SITE has no GPU node. Run make $SITE-gpu-up first."
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ARTIFACTS/acceptance-$STAMP.txt"

mkdir -p "$ARTIFACTS"
results=()
record() { results+=("$1"); }

exec > >(tee "$OUT") 2>&1
echo "# $SITE GPU acceptance, $STAMP, laptop clock, UTC. Node $GPU_NODE, driver $DRIVER_SOURCE: $PINNED_DRIVER"

########################################
# The node and what the GPU Operator runs on it
########################################

echo
echo "== allocatable"
kubectl_cp get node "$GPU_NODE" -o jsonpath='{.status.allocatable}'
echo
echo
echo "== GPU labels"
kubectl_cp get node "$GPU_NODE" -o json \
  | grep -oE '"(feature\.node\.kubernetes\.io/pci-10de\.present|nvidia\.com/(gpu\.product|gpu\.count|gpu\.memory|cuda\.driver-version\.full|cuda\.runtime-version\.full|gpu\.deploy\.[a-z-]+))": *"[^"]*"' \
  | sort
echo
echo "== GPU Operator pods on $GPU_NODE: image references and the digests the node pulled"
kubectl_cp -n gpu-operator get pods --field-selector "spec.nodeName=$GPU_NODE" -o json \
  | jq -r '.items[] | .metadata.name as $p | .status.containerStatuses[]? | "\($p) \(.name) \(.image) pulled=\(.imageID)"'

gpus="$(kubectl_cp get node "$GPU_NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')"
if [ "$gpus" = "$EXPECTED_GPUS" ]; then record "PASS  node advertises nvidia.com/gpu: $EXPECTED_GPUS"
else record "FAIL  node advertises nvidia.com/gpu: '${gpus:-none}'"; fi

label="$(kubectl_cp get node "$GPU_NODE" -o jsonpath='{.metadata.labels.feature\.node\.kubernetes\.io/pci-10de\.present}')"
if [ "$label" = "true" ]; then record "PASS  node carries pci-10de.present=true"
else record "FAIL  node pci-10de.present is '${label:-absent}'"; fi

dcgm="$(kubectl_cp -n gpu-operator get pods --field-selector "spec.nodeName=$GPU_NODE" -l app=nvidia-dcgm-exporter \
  -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
if [ -n "$dcgm" ]; then record "INFO  DCGM exporter image on the node: $dcgm"
else record "WARN  no DCGM exporter pod on $GPU_NODE yet"; fi

########################################
# The workloads, one after the other, one GPU each
########################################

kubectl_cp create namespace "$NS" --dry-run=client -o yaml | kubectl_cp apply -f - >/dev/null
kubectl_cp -n "$NS" delete pod cuda-vectoradd nvidia-smi --ignore-not-found --wait >/dev/null

run_pod() {
  local name="$1"
  echo
  echo "== $name"
  if [ "$SITE" = fin ]; then
    kubectl_cp patch --local -f "$MANIFESTS/$name.yaml" --type=json -o yaml \
      -p '[{"op":"add","path":"/spec/tolerations","value":[{"key":"eu1.io/staging","operator":"Exists","effect":"NoSchedule"}]}]' \
      | kubectl_cp -n "$NS" apply -f - >/dev/null
  else
    kubectl_cp -n "$NS" apply -f "$MANIFESTS/$name.yaml" >/dev/null
  fi
  if ! kubectl_cp -n "$NS" wait "pod/$name" \
      --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s >/dev/null; then
    warn "$name did not succeed. Its state:"
    kubectl_cp -n "$NS" describe pod "$name" | tail -n 25 || true
  fi
  kubectl_cp -n "$NS" logs "$name" | tee "$ARTIFACTS/acceptance-$STAMP-$name.txt"
}

run_pod cuda-vectoradd
if grep -q "Test PASSED" "$ARTIFACTS/acceptance-$STAMP-cuda-vectoradd.txt"; then
  record "PASS  cuda-vectoradd printed Test PASSED"
else
  record "FAIL  cuda-vectoradd did not print Test PASSED"
fi

run_pod nvidia-smi
if grep -q "$PRODUCT" "$ARTIFACTS/acceptance-$STAMP-nvidia-smi.txt"; then
  record "PASS  nvidia-smi sees the $PRODUCT"
else
  record "FAIL  nvidia-smi does not show an $PRODUCT"
fi
if [ -n "$PINNED_DRIVER" ] && grep -q "$PINNED_DRIVER" "$ARTIFACTS/acceptance-$STAMP-nvidia-smi.txt"; then
  record "PASS  driver in use is $PINNED_DRIVER, the version $DRIVER_SOURCE"
else
  record "FAIL  driver in use is not $PINNED_DRIVER, the version $DRIVER_SOURCE"
fi

kubectl_cp delete namespace "$NS" --wait=false >/dev/null

########################################
# Verdict
########################################

echo
echo "== verdict"
printf '%s\n' "${results[@]}"
if printf '%s\n' "${results[@]}" | grep -q '^FAIL'; then
  die "acceptance FAILED. Evidence: ${OUT#"$REPO_ROOT"/}"
fi
log "acceptance PASSED. Evidence: ${OUT#"$REPO_ROOT"/}"

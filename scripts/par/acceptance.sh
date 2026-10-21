#!/usr/bin/env bash
#
# Acceptance of the par L4 node, W1 step 2: Part 1's acceptance test, plus the
# versions actually running on the node.
#
# The criteria, from Part 1's docs/01-platform.md:
#   1. a cuda-vectoradd pod reaches Completed with "Test PASSED"
#   2. nvidia-smi inside a CUDA container shows the L4 and the pinned driver
#   3. the node advertises nvidia.com/gpu: 1
#   4. the node carries feature.node.kubernetes.io/pci-10de.present=true
# And for this project's evidence (rule 10): the driver, DCGM exporter and
# device plugin images the GPU Operator actually runs, read from the pods.
#
# The pods are test fixtures, so they are applied directly and deleted at the
# end rather than committed to gitops/. The cluster is left as ArgoCD put it.
#
#   make par-acceptance

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools kubectl grep sed jq
require_kubeconfig

NS="gpu-acceptance"
MANIFESTS="$REPO_ROOT/workloads/acceptance"
GPU_NODE="$(tf_output gpu_node_name)"
[ -n "$GPU_NODE" ] || die "terraform/par has no GPU node. Run make par-gpu-up first."
PINNED_DRIVER="$(grep -E '^\s+version: "' "$REPO_ROOT/gitops/values/base/gpu-operator-par.yaml" | head -n1 | sed -E 's/.*"(.*)".*/\1/')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ARTIFACTS/acceptance-$STAMP.txt"

mkdir -p "$ARTIFACTS"
results=()
record() { results+=("$1"); }

exec > >(tee "$OUT") 2>&1
echo "# par GPU acceptance, $STAMP, laptop clock, UTC. Node $GPU_NODE, driver pinned in Git: $PINNED_DRIVER"

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
if [ "$gpus" = "1" ]; then record "PASS  node advertises nvidia.com/gpu: 1"
else record "FAIL  node advertises nvidia.com/gpu: '${gpus:-none}'"; fi

label="$(kubectl_cp get node "$GPU_NODE" -o jsonpath='{.metadata.labels.feature\.node\.kubernetes\.io/pci-10de\.present}')"
if [ "$label" = "true" ]; then record "PASS  node carries pci-10de.present=true"
else record "FAIL  node pci-10de.present is '${label:-absent}'"; fi

dcgm="$(kubectl_cp -n gpu-operator get pods --field-selector "spec.nodeName=$GPU_NODE" -l app=nvidia-dcgm-exporter \
  -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
if [ -n "$dcgm" ]; then record "INFO  DCGM exporter image on the node: $dcgm"
else record "WARN  no DCGM exporter pod on $GPU_NODE yet"; fi

########################################
# The workloads, one after the other: there is one GPU
########################################

kubectl_cp create namespace "$NS" --dry-run=client -o yaml | kubectl_cp apply -f - >/dev/null
kubectl_cp -n "$NS" delete pod cuda-vectoradd nvidia-smi --ignore-not-found --wait >/dev/null

run_pod() {
  local name="$1"
  echo
  echo "== $name"
  kubectl_cp -n "$NS" apply -f "$MANIFESTS/$name.yaml" >/dev/null
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
if grep -q "L4" "$ARTIFACTS/acceptance-$STAMP-nvidia-smi.txt"; then
  record "PASS  nvidia-smi sees the L4"
else
  record "FAIL  nvidia-smi does not show an L4"
fi
if [ -n "$PINNED_DRIVER" ] && grep -q "$PINNED_DRIVER" "$ARTIFACTS/acceptance-$STAMP-nvidia-smi.txt"; then
  record "PASS  driver in use is $PINNED_DRIVER, the version pinned in Git"
else
  record "FAIL  driver in use is not the pinned $PINNED_DRIVER"
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

#!/usr/bin/env bash
#
# FC4: par's NVSentinel values in KIND, stage by stage, before W1.
#
#   KUBECONFIG=<scratch> scripts/readiness/kind-rehearsal.sh <NVSentinel checkout at v1.28.0>
#
# Runs on the cluster NVSentinel's own demo builds (demos/local-fault-injection-
# demo/scripts/00-setup.sh), which brings cert-manager and a fake DCGM 4.2.0
# backed by NVML injection. This replaces the demo's NVSentinel with ours,
# gitops/values/readiness/nvsentinel-par.yaml, and changes only what KIND can't
# have, each said below. Then, per stage, one SIMULATED XID 95 into the fake
# DCGM (the demo's method; DCGM 4.2.0 only turns 95 into a health failure) and
# what NVSentinel did about it:
#   stage 1  monitoring and store   expect a node condition, no cordon
#   stage 2  + quarantine and drain expect cordon and eviction, no RebootNode
#   stage 3  + remediation          expect a RebootNode, then uncordon once DCGM is healthy
#
# Refuses to touch a cluster whose context isn't the demo's.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools kubectl helm jq
DEMO="${1:?usage: scripts/readiness/kind-rehearsal.sh <NVSentinel checkout at v1.28.0>}/demos/local-fault-injection-demo"
[ -d "$DEMO" ] || die "no demo at $DEMO"
[ "$(kubectl config current-context)" = kind-nvsentinel-demo ] || die "current context isn't kind-nvsentinel-demo"

NS=nvsentinel
WORKER=nvsentinel-demo-worker
CP=nvsentinel-demo-control-plane
OUT="$REPO_ROOT/docs/artifacts/readiness/fc4-kind-par-values-$(date -u +%Y%m%dT%H%M%SZ).txt"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# What KIND can't have, and nothing else:
#  - storage: KIND's local-path class is named standard, par's is local-path
#  - labeler, syslog monitor, metadata collector: no GPU Operator and no
#    journald XIDs here; the labeler would strip the demo's hand-set labels
#  - csp.provider kind: generic would run chroot /host reboot in a container
KIND_OVERRIDES=(
  --set mongodb-store.psmdb-db.replsets.rs0.volumeSpec.pvc.storageClassName=standard
  --set global.labeler.enabled=false
  --set global.syslogHealthMonitor.enabled=false
  --set global.metadataCollector.enabled=false
  --set janitor-provider.csp.provider=kind
)

install() {
  local stage="$1"
  shift
  helm upgrade --install nvsentinel oci://ghcr.io/nvidia/nvsentinel --version v1.28.0 -n "$NS" \
    -f "$REPO_ROOT/gitops/values/readiness/nvsentinel-par.yaml" "${KIND_OVERRIDES[@]}" "$@" \
    --wait --timeout 15m >/dev/null
  echo "stage $stage installed $(now)"
  kubectl -n "$NS" get deploy -o custom-columns='DEPLOYMENT:.metadata.name,READY:.status.readyReplicas,NODE-SELECTOR:.spec.template.spec.nodeSelector'
}

condition() {
  kubectl get node "$WORKER" -o json | jq -r '[.status.conditions[] | select(.type | test("^Gpu|^SysLogs")) | select(.status == "True") | .type] | join(",")'
}

# Inject, wait up to $2 seconds, report what NVSentinel did; then clear the fault.
round() {
  local stage="$1" wait="$2" pod t0
  pod="$(kubectl -n gpu-operator get pods -l app=nvidia-dcgm -o jsonpath='{.items[0].metadata.name}')"
  t0="$(date +%s)"
  echo "== stage $stage: SIMULATED XID 95 into the fake DCGM at $(now)"
  kubectl -n gpu-operator exec "$pod" -- dcgmi test --inject --gpuid 0 -f 230 -v 95 >/dev/null
  sleep "$wait"
  echo "after ${wait}s: condition=[$(condition)] unschedulable=$(kubectl get node "$WORKER" -o jsonpath='{.spec.unschedulable}') state=$(kubectl get node "$WORKER" -o jsonpath='{.metadata.labels.dgxc\.nvidia\.com/nvsentinel-state}')"
  echo "workload: $(kubectl get pods -l app=gpu-workload -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.nodeName}; {end}')"
  echo "RebootNodes: $(kubectl get rebootnodes.janitor.dgxc.nvidia.com -o name 2>/dev/null | tr '\n' ' ')"
  # The fake DCGM keeps the XID until its host engine restarts, as the real one does.
  kubectl -n gpu-operator delete pod "$pod" --wait=false >/dev/null
  kubectl -n gpu-operator wait pod -l app=nvidia-dcgm --for=condition=Ready --timeout=300s >/dev/null
  local deadline=$(( $(date +%s) + 300 ))
  while [ -n "$(condition)" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 5; done
  [ "$(kubectl get node "$WORKER" -o jsonpath='{.spec.unschedulable}')" = true ] && kubectl uncordon "$WORKER" >/dev/null && echo "uncordoned by hand (stage $stage has no remediation)"
  echo "cleared after $(( $(date +%s) - t0 ))s: condition=[$(condition)]"
}

{
  echo "# FC4: gitops/values/readiness/nvsentinel-par.yaml in KIND, $(now)"
  echo "# overrides for KIND only: ${KIND_OVERRIDES[*]}"

  # The demo's own NVSentinel, and its MongoDB volume (on the worker), go first.
  helm uninstall nvsentinel -n "$NS" --wait >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pvc --all --wait >/dev/null 2>&1 || true

  # Our pools: the control plane plays par's CPU worker, the worker the L4.
  kubectl taint node "$CP" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
  kubectl label node "$CP" eu1.io/pool=cpu eu1.io/site=par --overwrite >/dev/null
  kubectl label node "$WORKER" eu1.io/pool=gpu eu1.io/site=par --overwrite >/dev/null

  install 1
  round 1 45
  install 2 --set global.faultQuarantine.enabled=true --set global.nodeDrainer.enabled=true
  round 2 90
  install 3 --set global.faultQuarantine.enabled=true --set global.nodeDrainer.enabled=true \
    --set global.faultRemediation.enabled=true --set global.janitor.enabled=true --set global.janitorProvider.enabled=true
  round 3 90
  echo "== circuit breaker"
  kubectl -n "$NS" get configmap circuit-breaker -o yaml 2>/dev/null | grep -E 'state|tripped' || echo "no circuit-breaker ConfigMap (breaker disabled)"
  echo "== MongoDB"
  kubectl -n "$NS" get pods -o wide | grep -E 'NAME|mongo'
} 2>&1 | tee "$OUT"
log "saved ${OUT#"$REPO_ROOT"/}"

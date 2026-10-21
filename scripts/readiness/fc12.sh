#!/usr/bin/env bash
#
# FC12: the readiness lane on par with the CPU worker on and no GPU, after
# each merge.
#
#   scripts/readiness/fc12.sh <label>    e.g. after-3, after-4, after-5, worker-off
#
# Prints and saves what each stage needs to be true before the next merge:
# the lane's Applications Synced and Healthy, their pods Running on the CPU
# worker and nowhere else, MongoDB up on local-path, NVCRE's own readiness
# report, the NVSentinel Deployments of every stage merged so far, and the
# admission webhooks the lane added. With label worker-off, it checks the
# cluster still admits ordinary pods while the lane's pods can't run.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools kubectl jq
require_kubeconfig
LABEL="${1:?usage: scripts/readiness/fc12.sh <label>}"
NVCRECTL="${NVCRECTL:-$REPO_ROOT/.cache/readiness/bin/nvcrectl}"
OUT="$REPO_ROOT/docs/artifacts/readiness/fc12-$LABEL-$(date -u +%Y%m%dT%H%M%SZ).txt"
LANE_NS=(nvsentinel nvcre kubeflow-system)

{
  echo "# FC12 $LABEL on par, $(date -u +%Y-%m-%dT%H:%M:%SZ), git main at $(git -C "$REPO_ROOT" ls-remote origin main | cut -c1-7)"

  echo "== Applications"
  kubectl_cp -n argocd get applications -o json | jq -r '.items[]
    | select(.metadata.name | test("^(nvsentinel|nvcre|kubeflow-trainer|cert-manager)$"))
    | "\(.metadata.name)\twave \(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-")\t\(.status.sync.status)\t\(.status.health.status)\t\(.status.sync.revision[0:7] // .status.sync.revisions[0][0:7] // "")"' | column -t

  echo "== Nodes"
  kubectl_cp get nodes -L eu1.io/pool

  echo "== Lane pods, and where they run"
  # From JSON, not columns: a restart count like "1 (10m ago)" shifts them.
  for ns in "${LANE_NS[@]}"; do
    kubectl_cp -n "$ns" get pods -o json 2>/dev/null | jq -r '.items[]
      | "\(.metadata.namespace)\t\(.metadata.name)\t\(.status.phase)\trestarts=\([.status.containerStatuses[]?.restartCount] | add // 0)\t\(.spec.nodeName // "-")"'
  done | column -t
  misplaced="$(for ns in "${LANE_NS[@]}"; do
      kubectl_cp -n "$ns" get pods -o json 2>/dev/null | jq -r '.items[]
        | select(.status.phase == "Running" and (.metadata.ownerReferences[0].kind // "") != "DaemonSet")
        | "\(.metadata.namespace)/\(.metadata.name) \(.spec.nodeName)"'
    done | grep -v ' eu1-par-cpu-01$' || true)"
  echo "pods running off the CPU worker (should be none): ${misplaced:-none}"

  echo "== NVSentinel Deployments and DaemonSets"
  kubectl_cp -n nvsentinel get deploy,daemonset -o wide 2>/dev/null | awk '{print $1, $2, $3, $4}' | column -t

  echo "== MongoDB"
  kubectl_cp -n nvsentinel get perconaservermongodb -o custom-columns='NAME:.metadata.name,STATE:.status.state' 2>/dev/null || echo "no PerconaServerMongoDB"
  kubectl_cp -n nvsentinel get pvc -o custom-columns='PVC:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,SIZE:.status.capacity.storage' 2>/dev/null

  echo "== circuit breaker"
  kubectl_cp -n nvsentinel get configmap circuit-breaker -o yaml 2>/dev/null | grep -E '^\s+(state|status)' \
    || echo "no circuit-breaker ConfigMap"

  echo "== admission webhooks from the lane"
  kubectl_cp get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json | jq -r '.items[]
    | select(.metadata.name | test("nvsentinel|janitor|jobset|trainer|nvcre"; "i"))
    | .kind as $k | .webhooks[] | "\($k | sub("WebhookConfiguration"; ""))\t\(.name)\t\(.failurePolicy)\t\([.rules[]?.resources[]?] | unique | join(","))"' | column -t

  echo "== nvcrectl setup status (its em dashes written as --, which this repository's lint requires)"
  if [ -x "$NVCRECTL" ]; then
    "$NVCRECTL" setup status --kubeconfig "$KUBECONFIG_PATH" 2>&1 | perl -CSD -pe 's/\x{2014}/--/g' || true
  else
    echo "no nvcrectl: make readiness-tools"
  fi

  if [ "$LABEL" = worker-off ]; then
    echo "== with the CPU worker off: does the API still admit an ordinary pod?"
    kubectl_cp -n default run fc12-probe --image=registry.k8s.io/pause:3.10 --restart=Never \
      --overrides='{"spec":{"nodeSelector":{"eu1.io/pool":"control"}}}' --dry-run=server -o name 2>&1
  fi
} 2>&1 | tee "$OUT"
log "saved ${OUT#"$REPO_ROOT"/}"

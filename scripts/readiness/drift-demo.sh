#!/usr/bin/env bash
#
# Use case 1's drift demo on par: a version changed by hand, seen by aicr diff,
# then put back by Argo CD. Every command is logged with the time it ran.
#
#   scripts/readiness/drift-demo.sh before     snapshot before the change
#   scripts/readiness/drift-demo.sh change     NVCRE's controller to v0.7.0 by hand (cos has set skip-reconcile)
#   scripts/readiness/drift-demo.sh drifted    snapshot, then aicr diff against the one before
#   scripts/readiness/drift-demo.sh healed     after cos removes skip-reconcile: wait for v0.8.0, snapshot, diff
#   scripts/readiness/drift-demo.sh cleanup    remove the aicr-validation namespace the agent used
#
# Split agreed with cos on 21 October: cos sets and removes the
# argocd.argoproj.io/skip-reconcile annotation on the nvcre Application, I
# change the image in my nvcre namespace and take the snapshots. Time box 10
# minutes from the annotation; not during an NVCRE run.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools kubectl
require_kubeconfig
LOG="$REPO_ROOT/docs/artifacts/readiness/aicr/drift-demo-par.txt"
OLD="ghcr.io/nvidia/cluster-readiness-engine/manager:v0.7.0"
mkdir -p "$(dirname "$LOG")"

run() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) \$ $*" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
}

image() {
  kubectl_cp -n nvcre get deploy nvcre-manager -o jsonpath='{.spec.template.spec.containers[0].image}'
}

case "${1:-}" in
  before | drifted)
    [ "$1" = before ] && echo "# Drift demo on par, use case 1. Every line starts with the UTC time it ran." >> "$LOG"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) nvcre-manager image: $(image)" | tee -a "$LOG"
    run make --no-print-directory aicr-snapshot SITE=par
    [ "$1" = drifted ] && run make --no-print-directory aicr-drift SITE=par
    ;;

  change)
    skip="$(kubectl_cp -n argocd get application nvcre -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}')"
    [ "$skip" = true ] || die "the nvcre Application isn't paused (skip-reconcile=$skip); cos sets it first"
    run kubectl --kubeconfig "$KUBECONFIG_PATH" -n nvcre set image deploy/nvcre-manager "manager=$OLD"
    run kubectl --kubeconfig "$KUBECONFIG_PATH" -n nvcre rollout status deploy/nvcre-manager --timeout=180s
    ;;

  healed)
    deadline=$(( $(date +%s) + 300 ))
    while [ "$(image)" = "$OLD" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 5; done
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) nvcre-manager image: $(image)" | tee -a "$LOG"
    [ "$(image)" != "$OLD" ] || die "still $OLD after 5 minutes: cos syncs nvcre by hand"
    run kubectl --kubeconfig "$KUBECONFIG_PATH" -n nvcre rollout status deploy/nvcre-manager --timeout=180s
    run make --no-print-directory aicr-snapshot SITE=par
    run make --no-print-directory aicr-drift SITE=par
    ;;

  cleanup)
    run kubectl --kubeconfig "$KUBECONFIG_PATH" delete namespace aicr-validation --ignore-not-found --wait=false
    ;;

  *)
    die "usage: scripts/readiness/drift-demo.sh before|change|drifted|healed|cleanup"
    ;;
esac

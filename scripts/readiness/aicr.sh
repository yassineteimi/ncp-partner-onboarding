#!/usr/bin/env bash
#
# Use case 1: AICR v1.1.0 as the known-good reference for the H200 pool.
#
#   scripts/readiness/aicr.sh recipes     the H200 recipes that resolve, and the refusals for what we run
#   scripts/readiness/aicr.sh bundle      render the reference recipe for Argo CD, never synced
#
# Yassine's decision (20 October): AICR is a reference on fin, not its deployer.
# fin keeps the base platform; this lane compares versions and validates. The
# commands and what each criterion means are in AICR's docs/user/cli-reference.md
# at v1.1.0.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

AICR="${AICR:-$REPO_ROOT/.cache/readiness/bin/aicr}"
[ -x "$AICR" ] || die "no $AICR: make readiness-tools"
OUT="$REPO_ROOT/docs/artifacts/readiness/aicr"
mkdir -p "$OUT"

# One query, its exit code and its output, into the summary.
try() {
  local name="$1"
  shift
  local rc=0
  "$AICR" recipe "$@" -o "$OUT/recipe-$name.yaml" > "$OUT/recipe-$name.log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || rm -f "$OUT/recipe-$name.yaml"
  printf '%-22s exit=%s  aicr recipe %s\n' "$name" "$rc" "$*"
  [ "$rc" = 0 ] || sed 's/^/    /' "$OUT/recipe-$name.log" | head -12
}

case "${1:-}" in
  recipes)
    {
      echo "# aicr recipe, $("$AICR" --version 2>&1 | head -1), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "# What resolves for the H200 training pool:"
      try eks-h200-training --service eks --accelerator h200 --os ubuntu --intent training
      try eks-h200-kubeflow --service eks --accelerator h200 --os ubuntu --intent training --platform kubeflow
      try k0s-h200-training --service k0s --accelerator h200 --os ubuntu --intent training
      echo "# What we run, or the closest names to it, refused:"
      try kubeadm-h200 --service kubeadm --accelerator h200 --os ubuntu --intent training
      try generic-h200 --service generic --accelerator h200 --os ubuntu --intent training
      try metal3-h200 --service metal3 --accelerator h200 --os ubuntu --intent training
      try kind-h200 --service kind --accelerator h200 --os ubuntu --intent training
      try bcm-h200 --service bcm --accelerator h200 --os ubuntu --intent training
      try k0s-h200-kubeflow --service k0s --accelerator h200 --os ubuntu --intent training --platform kubeflow
      echo "# The L4 pool:"
      try generic-l4 --service generic --accelerator l4 --os ubuntu --intent inference
      try eks-l4 --service eks --accelerator l4 --os ubuntu --intent inference
    } | tee "$OUT/recipes-summary.txt"
    ;;

  bundle)
    recipe="$OUT/recipe-k0s-h200-training.yaml"
    [ -f "$recipe" ] || die "run scripts/readiness/aicr.sh recipes first"
    rm -rf "$OUT/bundle-argocd"
    "$AICR" bundle --recipe "$recipe" --deployer argocd --output "$OUT/bundle-argocd" \
      --repo https://github.com/yassineteimi/ncp-partner-onboarding \
      2>&1 | tee "$OUT/bundle-argocd.log"
    ;;

  *)
    die "usage: scripts/readiness/aicr.sh recipes|bundle"
    ;;
esac

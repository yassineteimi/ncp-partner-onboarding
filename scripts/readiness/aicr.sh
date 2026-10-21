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

# AICR's CLI and its recipe comments use em dashes, which this repository's
# lint refuses in every tracked file. Everything aicr writes here is saved with
# "--" in their place, and nothing else changed.
no_em_dashes() {
  find "$OUT" -type f \( -name '*.yaml' -o -name '*.log' -o -name '*.txt' -o -name '*.md' \) \
    -exec perl -CSD -pi -e 's/\x{2014}/--/g' {} +
}

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
      echo "# Em dashes in aicr's output are written as -- (this repository's lint refuses them)."
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
    no_em_dashes
    ;;

  bundle)
    # Rendered outside docs/ and kept as a tarball of AICR's untouched output,
    # so its checksums.txt still matches; a listing beside it is readable on
    # GitHub. Never synced: no Application reads docs/.
    recipe="$OUT/recipe-k0s-h200-training.yaml"
    [ -f "$recipe" ] || die "run scripts/readiness/aicr.sh recipes first"
    work="$REPO_ROOT/.cache/readiness/aicr-bundle"
    rm -rf "$work" "$OUT/bundle-argocd"
    "$AICR" bundle --recipe "$recipe" --deployer argocd --output "$work/bundle-argocd" \
      --repo https://github.com/yassineteimi/ncp-partner-onboarding > "$OUT/bundle-argocd.log" 2>&1
    (cd "$work/bundle-argocd" && shasum -a 256 -c checksums.txt --quiet) \
      || die "AICR's bundle doesn't match its own checksums.txt"
    tar -czf "$OUT/bundle-argocd.tar.gz" -C "$work" bundle-argocd
    {
      echo "# aicr bundle --deployer argocd of recipe-k0s-h200-training.yaml, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "# The bundle itself: bundle-argocd.tar.gz, AICR's output untouched (checksums.txt verified)."
      echo "# Reference only: nothing here is synced to a cluster."
      (cd "$work/bundle-argocd" && find . -type f | sort | sed 's#^\./#  #')
      echo
      echo "# bundle-info.yaml"
      cat "$work/bundle-argocd/bundle-info.yaml"
    } > "$OUT/bundle-argocd.txt"
    no_em_dashes
    log "bundle in ${OUT#"$REPO_ROOT"/}/bundle-argocd.{tar.gz,txt}"
    ;;

  snapshot)
    # What a site runs, as AICR sees it: images, ClusterPolicy, node OS,
    # kernel, labels, taints. The agent runs as a privileged Job on the GPU node
    # (on par without a GPU, the CPU worker) and tolerates every taint, the
    # staging one included.
    SITE="${SITE:?SITE=par or SITE=fin}"
    use_site "$SITE"
    require_kubeconfig
    pool=gpu
    [ "$SITE" = par ] && [ -z "$(kubectl_cp get nodes -l eu1.io/pool=gpu -o name)" ] && pool=cpu
    file="$OUT/snapshot-$SITE-$(date -u +%Y%m%dT%H%M%SZ).yaml"
    "$AICR" snapshot -k "$KUBECONFIG_PATH" -n aicr-validation --node-selector "eu1.io/pool=$pool" \
      -o "$file" 2>&1 | tee "$file.log"
    no_em_dashes
    log "snapshot of $SITE ($pool node) in ${file#"$REPO_ROOT"/}"
    ;;

  validate)
    # fin against the reference recipe, deployment phase only: the conformance
    # phase expects AICR's own components (KAI's queue, the DRA driver), which
    # fin doesn't run by decision. No GPU is requested, so it can run beside
    # other work; the nvidia-smi check, which asks for a GPU, is skipped. Ubuntu
    # 26.04 is expected to fail the readiness pre-flight (the recipe says 24.04);
    # that refusal is the finding, and it's kept.
    SITE="${SITE:?SITE=par or SITE=fin}"
    use_site "$SITE"
    require_kubeconfig
    snap="$(compgen -G "$OUT/snapshot-$SITE-*Z.yaml" | sort | tail -1)"
    [ -n "$snap" ] || die "no snapshot of $SITE: run SITE=$SITE scripts/readiness/aicr.sh snapshot first"
    file="$OUT/validate-$SITE-$(date -u +%Y%m%dT%H%M%SZ)"
    rc=0
    "$AICR" validate -k "$KUBECONFIG_PATH" -n aicr-validation \
      --recipe "$OUT/recipe-k0s-h200-training.yaml" --snapshot "$snap" \
      --phase deployment --skip-check check-nvidia-smi --fail-on-error=false \
      -o "$file.json" > "$file.log" 2>&1 || rc=$?
    echo "aicr validate exit=$rc (2 = readiness pre-flight failed)" | tee -a "$file.log"
    no_em_dashes
    log "validation of $SITE in ${file#"$REPO_ROOT"/}.{json,log}"
    ;;

  diff)
    # Drift between the two newest snapshots of a site.
    SITE="${SITE:?SITE=par or SITE=fin}"
    [ "$(compgen -G "$OUT/snapshot-$SITE-*Z.yaml" | wc -l)" -ge 2 ] || die "need two snapshots of $SITE"
    baseline="$(compgen -G "$OUT/snapshot-$SITE-*Z.yaml" | sort | tail -2 | head -1)"
    target="$(compgen -G "$OUT/snapshot-$SITE-*Z.yaml" | sort | tail -1)"
    rc=0
    "$AICR" diff --baseline "$baseline" --target "$target" --format table \
      > "$OUT/diff-$SITE-$(date -u +%Y%m%dT%H%M%SZ).txt" 2>&1 || rc=$?
    no_em_dashes
    cat "$OUT"/diff-"$SITE"-*Z.txt | tail -40
    echo "aicr diff exit=$rc"
    ;;

  *)
    die "usage: scripts/readiness/aicr.sh recipes|bundle|snapshot|validate|diff"
    ;;
esac

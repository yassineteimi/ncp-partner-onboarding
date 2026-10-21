#!/usr/bin/env bash
#
# Render every readiness chart the way Argo CD will, and check the result.
#
#   scripts/readiness/render.sh            render and check, print a summary
#   scripts/readiness/render.sh --save     also write the summary to docs/artifacts/readiness/
#
# Argo CD renders with `helm template`, so this does too, with the same chart
# version and values files as each Application. The checks are the ones that
# would cost window time if they failed on the cluster: see render_check.py.
#
# The chart table must match the Applications; the script refuses to run if a
# version here isn't the targetRevision of the Application it names.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools helm
PYTHON="${PYTHON:-$REPO_ROOT/.venv/bin/python}"
[ -x "$PYTHON" ] || die "no $PYTHON: make readiness-venv"

OUT="$REPO_ROOT/.cache/readiness/render"
mkdir -p "$OUT"

# application file | release | namespace | chart reference | version | values files (comma separated)
CHARTS=(
  "par/readiness/nvsentinel.yaml|nvsentinel|nvsentinel|oci://ghcr.io/nvidia/nvsentinel|v1.28.0|readiness/nvsentinel-par.yaml"
  "par/readiness/kubeflow-trainer.yaml|kubeflow-trainer|kubeflow-system|oci://ghcr.io/kubeflow/charts/kubeflow-trainer|2.2.1|readiness/kubeflow-trainer-par.yaml"
  "par/readiness/nvcre.yaml|nvcre|nvcre|oci://ghcr.io/nvidia/cluster-readiness-engine|v0.8.0|readiness/nvcre-par.yaml"
  "fin/readiness/kubeflow-trainer.yaml|kubeflow-trainer|kubeflow-system|oci://ghcr.io/kubeflow/charts/kubeflow-trainer|2.2.1|readiness/kubeflow-trainer-fin.yaml"
  "fin/readiness/nvcre.yaml|nvcre|nvcre|oci://ghcr.io/nvidia/cluster-readiness-engine|v0.8.0|readiness/nvcre-fin.yaml"
  "fin/base/gpu-operator.yaml|gpu-operator|gpu-operator|gpu-operator --repo https://helm.ngc.nvidia.com/nvidia|v26.7.2|base/gpu-operator.yaml,base/gpu-operator-fin.yaml,readiness/gpu-operator-fin.yaml"
)

for entry in "${CHARTS[@]}"; do
  IFS='|' read -r app release ns chart version values <<<"$entry"
  grep -q "targetRevision: $version\$" "$REPO_ROOT/gitops/apps/$app" \
    || die "gitops/apps/$app doesn't pin $version; update the table in this script"

  name="${app//\//-}"
  name="${name%.yaml}"
  args=()
  IFS=',' read -r -a files <<<"$values"
  for f in "${files[@]}"; do args+=(-f "$REPO_ROOT/gitops/values/$f"); done

  # shellcheck disable=SC2086 # the chart reference is two words for a plain repository
  # --include-crds because Argo CD applies the charts' crds/ directories too.
  helm template "$release" $chart --version "$version" -n "$ns" --include-crds "${args[@]}" \
    > "$OUT/$name.yaml" 2> "$OUT/$name.err" \
    || { cat "$OUT/$name.err" >&2; die "helm template failed for $app"; }
done

# NVSentinel's later stages, switched on here before their commits exist, so
# their pods and webhooks are checked ahead of time.
helm template nvsentinel oci://ghcr.io/nvidia/nvsentinel --version v1.28.0 -n nvsentinel --include-crds \
  -f "$REPO_ROOT/gitops/values/readiness/nvsentinel-par.yaml" \
  --set global.faultQuarantine.enabled=true --set global.nodeDrainer.enabled=true \
  --set global.faultRemediation.enabled=true --set global.janitor.enabled=true \
  --set global.janitorProvider.enabled=true \
  > "$OUT/par-readiness-nvsentinel-all-stages.yaml" || die "helm template failed for NVSentinel with all stages"

summary="$("$PYTHON" -I "$REPO_ROOT/scripts/readiness/render_check.py" "$OUT")" || { echo "$summary"; die "render checks failed"; }
echo "$summary"

if [ "${1:-}" = --save ]; then
  file="$REPO_ROOT/docs/artifacts/readiness/render-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    echo "# scripts/readiness/render.sh at $(git -C "$REPO_ROOT" rev-parse --short HEAD), $(date -u +%Y-%m-%dT%H:%M:%SZ), helm $(helm version --short)"
    echo "$summary"
  } > "$file"
  log "saved ${file#"$REPO_ROOT"/}"
fi

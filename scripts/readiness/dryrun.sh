#!/usr/bin/env bash
#
# Server-side dry run on par of everything the readiness lane renders.
#
#   scripts/readiness/dryrun.sh          after scripts/readiness/render.sh
#   scripts/readiness/dryrun.sh --save   also keep the result, with the render
#                                        summary, in docs/artifacts/readiness/
#
# The API server validates every object against its real schemas and admission
# chain, then throws it away. Objects whose kind the cluster doesn't serve yet
# (custom resources of CRDs that only exist after a real sync) can't be dry-run
# and are listed instead; see dryrun_split.py.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools kubectl
require_kubeconfig
PYTHON="${PYTHON:-$REPO_ROOT/.venv/bin/python}"
[ -x "$PYTHON" ] || die "no $PYTHON: make readiness-venv"

RENDER="$REPO_ROOT/.cache/readiness/render"
WORK="$REPO_ROOT/.cache/readiness/dryrun"
mkdir -p "$WORK"
compgen -G "$RENDER/par-*.yaml" >/dev/null || die "nothing rendered; run scripts/readiness/render.sh first"

kubectl_cp api-resources -o wide --no-headers > "$WORK/api-resources.txt"
split="$("$PYTHON" -I "$REPO_ROOT/scripts/readiness/dryrun_split.py" "$WORK/api-resources.txt" "$WORK" "$RENDER"/par-*.yaml)"

results=""
failed=0
for f in "$WORK"/par-*.yaml; do
  if out="$(kubectl_cp apply --dry-run=server --server-side --field-manager=readiness-dryrun -n default -f "$f" 2>&1)"; then
    results+="$(basename "$f" .yaml): $(grep -c 'server dry run' <<<"$out") objects accepted"$'\n'
  else
    failed=1
    results+="$(basename "$f" .yaml): FAILED"$'\n'"$out"$'\n'
  fi
done

report="$(cat <<EOF
# FC7: kubectl apply --dry-run=server --server-side on par, $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Namespaces stripped and dry-run in default: the lane's namespaces don't exist
# until Argo CD creates them, and a dry run into a missing namespace fails first.
$split
$results
EOF
)"
echo "$report"

if [ "${1:-}" = --save ]; then
  file="$REPO_ROOT/docs/artifacts/readiness/fc6-fc7-render-dryrun-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    echo "# FC6: scripts/readiness/render.sh at $(git -C "$REPO_ROOT" rev-parse --short HEAD), helm $(helm version --short)"
    "$PYTHON" -I "$REPO_ROOT/scripts/readiness/render_check.py" "$RENDER"
    echo
    echo "$report"
  } > "$file"
  log "saved ${file#"$REPO_ROOT"/}"
fi

[ "$failed" = 0 ] || die "the dry run refused something, see above"

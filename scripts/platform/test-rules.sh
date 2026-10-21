#!/usr/bin/env bash
#
# Unit test the platform lane's recording rules and dashboard queries offline,
# with no cluster. Part 1's scripts/test-rules.sh, pointed at gpu-rules.
#
# The rules live in a PrometheusRule resource so ArgoCD can deploy them.
# promtool reads plain Prometheus rule files, so this lifts everything under
# spec: into a temporary rules file first. That relies on spec being the last
# top-level key, which the file says at the top.
#
# With BREAK=1 it first swaps the per-GPU grouping for a per-pod one, and
# expects the tests to fail: a rule that can't make its tests fail isn't tested.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools promtool sed

SRC="$REPO_ROOT/gitops/manifests/platform/gpu-rules"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sed -n '/^spec:/,$p' "$SRC/gpu-cardinality.yaml" | sed '1d; s/^  //' > "$WORK/gpu-cardinality.rules.yaml"
cp "$SRC/tests/gpu-cardinality.test.yaml" "$WORK/"

if [ "${BREAK:-0}" = 1 ]; then
  sed -i.bak 's/count by (hostname, gpu, UUID, modelName)/count by (hostname, gpu, UUID, modelName, pod)/' \
    "$WORK/gpu-cardinality.rules.yaml"
  grep -q 'modelName, pod)' "$WORK/gpu-cardinality.rules.yaml" || die "the break did not apply"
fi

log "promtool $(promtool --version 2>&1 | head -n1 | awk '{print $3}')"
log "checking rule syntax"
promtool check rules "$WORK/gpu-cardinality.rules.yaml"

log "running unit tests"
if [ "${BREAK:-0}" = 1 ]; then
  if (cd "$WORK" && promtool test rules gpu-cardinality.test.yaml); then
    die "the broken rule passed its tests"
  fi
  log "the broken rule failed its tests, as it should"
else
  (cd "$WORK" && promtool test rules gpu-cardinality.test.yaml)
fi

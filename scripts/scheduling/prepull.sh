#!/usr/bin/env bash
#
# W2 step S0 on fin: pull the gang's 4.1 GB image onto the H200 node while
# NVCRE certifies it (workloads/scheduling/prepull/daemonset.yaml).
#
#   prepull.sh up      start it, right after the node joins
#   prepull.sh status  is the image there yet, and how long did the pull take
#   prepull.sh down    remove it, before step 4
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site fin
require_kubeconfig
require_tools kubectl

MANIFEST="$REPO_ROOT/workloads/scheduling/prepull/daemonset.yaml"

case "${1:-}" in
  up)
    kubectl_cp apply -f "$MANIFEST"
    ;;
  status)
    kubectl_cp -n team-a get pods -l app=prepull-trainer -o wide
    # The kubelet's Pulled event says how long the pull took.
    kubectl_cp -n team-a get events --field-selector reason=Pulled \
      -o custom-columns='TIME:.lastTimestamp,OBJECT:.involvedObject.name,MESSAGE:.message' | grep -E 'prepull|TIME' || true
    ;;
  down)
    kubectl_cp delete -f "$MANIFEST" --ignore-not-found
    ;;
  *)
    die "usage: $0 up|status|down"
    ;;
esac

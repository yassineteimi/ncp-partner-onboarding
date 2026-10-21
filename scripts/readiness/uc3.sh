#!/usr/bin/env bash
#
# Use case 3 in W1: NVSentinel against Part 1's goodput run, on par's L4.
#
#   scripts/readiness/uc3.sh check          NVSentinel ready on the GPU node, before anything is injected
#   scripts/readiness/uc3.sh watch          clock offsets, then record the outage until Ctrl-C
#   scripts/readiness/uc3.sh inject [XID]   SIMULATED: the kernel log line (default 79)
#   scripts/readiness/uc3.sh inject-dcgm    SIMULATED: XID 79 into DCGM's cache
#   scripts/readiness/uc3.sh capture        after the Job completes: goodput, phases, NVSentinel's state
#
# The goodput Job itself is scripts/readiness/goodput.sh start, Part 1's Job.
# Every injection is simulated and listed in docs/simulated.md.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools kubectl jq
require_kubeconfig
PYTHON="${PYTHON:-$REPO_ROOT/.venv/bin/python}"
OUT="$REPO_ROOT/docs/artifacts/readiness"
REC="$REPO_ROOT/.cache/readiness/uc3-recorder.jsonl"
mkdir -p "$OUT" "$(dirname "$REC")"

stamp() { date -u +%Y%m%dT%H%M%SZ; }

gpu_node() {
  local node
  node="$(kubectl_cp get nodes -l eu1.io/site=par,eu1.io/pool=gpu -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$node" ] || die "no GPU node on par"
  echo "$node"
}

# Every restarted container in the lane's namespaces, with its last exit.
# Counts above zero before the run aren't the run's: by 21 October par's
# controllers had restarted 8 to 10 times each, last when the API server
# stalled at 12:07 UTC. The exit times say which restarts happened during it.
restarts() {
  local ns
  for ns in nvsentinel nvcre kubeflow-system; do
    kubectl_cp -n "$ns" get pods -o json | jq -r --arg ns "$ns" '.items[] | .metadata.name as $p
      | .status.containerStatuses[]? | select(.restartCount > 0)
      | "\($ns)/\($p) \(.name) restarts=\(.restartCount) last_exit=\(.lastState.terminated.finishedAt // "-") \(.lastState.terminated.reason // "")"'
  done
}

# Offset of a machine's clock from this laptop's, in seconds: its clock read
# over SSH, against the middle of the round trip. Printed with the round trip,
# which bounds the error.
offset() {
  local host="$1" before after remote
  before="$(python3 -c 'import time; print(f"{time.time():.3f}")')"
  remote="$(node_ssh "$host" 'date +%s.%N')"
  after="$(python3 -c 'import time; print(f"{time.time():.3f}")')"
  python3 -c "b,a,r=$before,$after,$remote; print(f'offset_s={r-(b+a)/2:+.3f} round_trip_s={a-b:.3f}')"
}

case "${1:-}" in
  check)
    node="$(gpu_node)"
    file="$OUT/uc3-check-$(stamp).txt"
    {
      echo "# NVSentinel on $node before injection, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "== NVSentinel labels on the node"
      kubectl_cp get node "$node" -o json | jq -r '.metadata.labels | to_entries[] | select(.key | test("nvsentinel")) | "\(.key)=\(.value)"'
      echo "== NVSentinel pods"
      kubectl_cp -n nvsentinel get pods -o wide
      echo "== restarts so far (the baseline for capture)"
      restarts
      echo "== node conditions"
      kubectl_cp get node "$node" -o json | jq -r '.status.conditions[] | "\(.type)=\(.status) \(.reason // "") \(.lastTransitionTime)"'
      echo "== circuit breaker"
      kubectl_cp -n nvsentinel get deploy fault-quarantine -o json 2>/dev/null \
        | jq -r '.spec.template.spec.containers[0].args[]? | select(test("circuit"))' || echo "fault-quarantine not deployed"
      echo "== persistent journal on the node"
      load_env
      resolve_ssh_keypair
      node_ssh "$(tf_output gpu_node_public_ip)" 'ls -ld /var/log/journal && journalctl --header | grep -m1 "File path"'
    } 2>&1 | tee "$file"
    ;;

  watch)
    node="$(gpu_node)"
    load_env
    resolve_ssh_keypair
    {
      echo "clock_offsets_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) reference=laptop"
      echo "gpu_node $node $(offset "$(tf_output gpu_node_public_ip)")"
      echo "control_plane $(offset "$(tf_output control_plane_public_ip)")"
    } | tee -a "$OUT/uc3-timeline.txt"
    log "recording to ${REC#"$REPO_ROOT"/}; Ctrl-C after the trainer has resumed"
    "$PYTHON" -I "$REPO_ROOT/scripts/readiness/timeline.py" record "$REC" --node "$node" --kubeconfig "$KUBECONFIG_PATH"
    ;;

  inject)
    "$REPO_ROOT/scripts/readiness/inject-xid.sh" "$(gpu_node)" "${2:-79}"
    ;;

  inject-dcgm)
    "$REPO_ROOT/scripts/readiness/inject-xid-dcgm.sh" 79
    ;;

  capture)
    node="$(gpu_node)"
    ts="$(stamp)"
    "$REPO_ROOT/scripts/readiness/goodput.sh" capture
    injected="$(grep 'xid=79 ' "$OUT/xid-timeline.txt" | tail -1 | sed -E 's/^xid_injected=([^ ]+).*/\1/')"
    [ -n "$injected" ] || die "no XID 79 injection in docs/artifacts/readiness/xid-timeline.txt"
    [ -f "$REC" ] && cp "$REC" "$OUT/uc3-recorder-$ts.jsonl"
    "$PYTHON" -I "$REPO_ROOT/scripts/readiness/timeline.py" phases "$OUT/uc3-recorder-$ts.jsonl" \
      --injected "$injected" --goodput "$OUT/uc3-goodput.json" | tee "$OUT/uc3-phases-$ts.json"
    {
      echo "# NVSentinel's state after the run, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "== node"
      kubectl_cp get node "$node" -o yaml
      echo "== RebootNode objects"
      kubectl_cp get rebootnodes.janitor.dgxc.nvidia.com -o yaml
      echo "== events on the node"
      kubectl_cp get events -A --field-selector "involvedObject.name=$node" --sort-by=.lastTimestamp \
        -o custom-columns='TIME:.lastTimestamp,SOURCE:.source.component,REASON:.reason,MESSAGE:.message'
      echo "== reboot Jobs"
      kubectl_cp -n nvsentinel get jobs -o wide
      echo "== NVSentinel pods"
      kubectl_cp -n nvsentinel get pods -o wide
      echo "== restarts (compare with the uc3-check file; a last exit after the injection is the run's)"
      restarts
    } > "$OUT/uc3-nvsentinel-state-$ts.txt" 2>&1
    log "evidence in docs/artifacts/readiness/uc3-*-$ts.*"
    ;;

  *)
    die "usage: scripts/readiness/uc3.sh check|watch|inject [XID]|inject-dcgm|capture"
    ;;
esac

#!/usr/bin/env bash
#
# The two-pod KAI gang running an all-reduce between its pods (use case 4).
#
#   gang.sh par   free check on the CPU worker: real containers, gloo, no GPU.
#                 Tests the pod grouper's gang, the rendezvous and allreduce.py.
#   gang.sh fin   W2 step 4 on the H200 node: one GPU per pod, NCCL, then a
#                 gang of 3 on 2 GPUs that must stay Pending with no pod bound
#
# Writes docs/artifacts/scheduling/gang-<site>-<stamp>.txt: placement and bind
# times, the PodGroup, the queues, both pods' logs (rank 0 prints bus
# bandwidth; NCCL_DEBUG=INFO prints the transport) and a summary of the
# transport lines. Time box in W2: 20 min. Abort if the gang isn't Running
# 5 min after submit (GANG_TIMEOUT) or the job hasn't finished 10 min after.
# KEEP=1 leaves the Jobs in place.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
SITE_ARG="${1:-}"
case "$SITE_ARG" in par | fin) ;; *) die "usage: $0 par|fin" ;; esac
use_site "$SITE_ARG"
require_kubeconfig
require_tools kubectl perl
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GANG_TIMEOUT="${GANG_TIMEOUT:-300}"
RUN_TIMEOUT="${RUN_TIMEOUT:-600}"
case "$SITE" in
  par) overlay=par-gloo ;;
  fin) overlay=fin ;;
esac
OVERLAYS="$REPO_ROOT/workloads/scheduling/allreduce"
failures=0
note_fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

cleanup() {
  kubectl_cp delete -k "$OVERLAYS/$overlay" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  if [ "$SITE" = fin ]; then
    kubectl_cp delete -k "$OVERLAYS/fin-too-big" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  fi
}

start_capture gang

section "Before"
kubectl_cp get nodes -L eu1.io/pool \
  -o custom-columns='NODE:.metadata.name,POOL:.metadata.labels.eu1\.io/pool,GPU:.status.allocatable.nvidia\.com/gpu,TAINTS:.spec.taints[*].key'
cleanup
wait_for "no gang pods left" 120 no_pods team-a app=allreduce-gang || true
kai_state team-a

section "Submit the gang of 2 ($overlay)"
kubectl_cp apply -k "$OVERLAYS/$overlay"
submitted="$(kubectl_cp -n team-a get job allreduce-gang -o jsonpath='{.metadata.creationTimestamp}')"
echo "Job created at $submitted (API server)"
if ! wait_for "both gang pods bound" "$GANG_TIMEOUT" bound_at_least team-a allreduce-gang 2; then
  note_fail "gang not bound within ${GANG_TIMEOUT}s"
  kubectl_cp -n team-a describe pods -l job-name=allreduce-gang | tail -30
fi
echo "PodScheduled per pod (API server time):"
kubectl_cp -n team-a get pods -l job-name=allreduce-gang \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.nodeName}{"  scheduled "}{.status.conditions[?(@.type=="PodScheduled")].lastTransitionTime}{"  started "}{.status.startTime}{"\n"}{end}'
kai_state team-a

section "Run"
if ! wait_for "the all-reduce Job finished" "$RUN_TIMEOUT" job_finished team-a allreduce-gang; then
  note_fail "Job not finished within ${RUN_TIMEOUT}s"
fi
job_complete team-a allreduce-gang || note_fail "Job did not complete"
job_pods team-a allreduce-gang

section "Logs"
for i in 0 1; do
  pod="$(kubectl_cp -n team-a get pods -l job-name=allreduce-gang,batch.kubernetes.io/job-completion-index=$i -o name | head -n1)"
  echo "### rank $i ($pod)"
  kubectl_cp -n team-a logs "$pod" 2>&1 || true
done > "$OUTFILE.logs"
echo "full logs: ${OUTFILE#"$REPO_ROOT"/}.logs"
grep -E '^rank |^ +[0-9]+ B |^RESULT ' "$OUTFILE.logs" || true

section "NCCL transport"
if [ "$SITE" = fin ]; then
  # NCCL prints one line per channel and peer, ending in "via <transport>".
  grep -E 'via (P2P|SHM|NET|NVLS|CollNet)|NET/(Socket|IB)|Using network|comm .* nRanks' "$OUTFILE.logs" | sort | uniq -c | sort -rn | head -20 \
    || echo "(no transport lines: was NCCL_DEBUG=INFO set?)"
else
  echo "gloo on par: no NCCL transport to report"
fi

if [ "$SITE" = fin ]; then
  section "Gang of 3 on 2 GPUs: none may bind"
  kubectl_cp apply -k "$OVERLAYS/fin-too-big"
  if wait_for "a pod of the gang of 3 bound" 60 bound_at_least team-a allreduce-gang-3 1; then
    note_fail "a pod of the gang of 3 was bound"
  fi
  job_pods team-a allreduce-gang-3
  pg="$(kubectl_cp -n team-a get podgroups.scheduling.run.ai -o name | grep allreduce-gang-3 || true)"
  if [ -n "$pg" ]; then
    echo "### why KAI holds the gang ($pg)"
    kubectl_cp -n team-a get "$pg" -o jsonpath='{.status.schedulingConditions}' | tr ',' '\n' | head -20
    echo
  fi
  kai_state team-a
fi

events_since_start team-a | grep -E 'allreduce-gang' | tail -30 || true

if [ "${KEEP:-}" != "1" ]; then
  section "Cleanup"
  cleanup
fi

section "Result"
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed, see above"
  exit 1
fi
echo "gang bound together, all-reduce completed"

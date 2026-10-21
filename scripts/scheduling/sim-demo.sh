#!/usr/bin/env bash
#
# Use case 4 on par, with SIMULATED GPUs (two KWOK nodes, 4 each): what KAI's
# queues do when two teams share 8 GPUs.
#
#   1. team-a bursts to 8 GPUs while team-b is idle (quota 4, borrows 4)
#   2. team-b submits a gang of 4: KAI reclaims team-a's 4 borrowed GPUs, never
#      its in-quota 4, and binds team-b's 4 pods together
#   3. with team-a gone and 4 GPUs free, team-b asks for a gang of 6: none of
#      the 6 binds, and the 4 free GPUs stay free
#
# Needs the CPU worker on (KAI, KWOK and the fake GPU operator run there).
# Writes docs/artifacts/scheduling/sim-demo-par-<stamp>.txt and exits non-zero
# if any step didn't behave as described. KEEP=1 leaves the Jobs in place.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par
require_kubeconfig
require_tools kubectl perl
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DEMO="$REPO_ROOT/workloads/scheduling/sim-demo"
failures=0
check() {
  if [ "$2" = "$3" ]; then echo "PASS: $1 ($2)"; else echo "FAIL: $1 (got $2, expected $3)"; failures=$((failures + 1)); fi
}

sim_gpus_allocatable() {
  kubectl_cp get nodes -l eu1.io/pool=sim-gpu -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
    | awk '{s += $1} END {print s + 0}'
}

delete_demo_jobs() {
  local ns
  for ns in team-a team-b; do
    kubectl_cp -n "$ns" delete jobs -l eu1.io/simulated=true --ignore-not-found --wait=true >/dev/null
    wait_for "no demo pods left in $ns" 120 no_pods "$ns" eu1.io/simulated=true || true
  done
}

start_capture sim-demo

section "Before: simulated nodes, KAI, queues"
echo "SIMULATED: the eu1-par-sim-gpu-* nodes are KWOK nodes; their GPUs come from the fake GPU operator."
kubectl_cp get nodes -L eu1.io/pool,eu1.io/simulated,run.ai/simulated-gpu-node-pool \
  -o custom-columns='NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,POOL:.metadata.labels.eu1\.io/pool,GPU:.status.allocatable.nvidia\.com/gpu'
kubectl_cp -n kai-scheduler get pods -o wide
check "simulated GPUs allocatable" "$(sim_gpus_allocatable)" 8
delete_demo_jobs
kai_state team-a team-b

section "1. team-a bursts to 8 GPUs while team-b is idle"
kubectl_cp apply -f "$DEMO/1-a-burst.yaml"
wait_for "8 team-a pods bound" 180 bound_at_least team-a a-burst 8 || true
job_pods team-a a-burst
check "team-a pods bound, 4 of them over quota" "$(job_bound_count team-a a-burst)" 8
kai_state team-a

section "2. team-b submits a gang of 4; KAI reclaims team-a's borrowed GPUs"
submitted="$(date -u +%H:%M:%SZ)"
kubectl_cp apply -f "$DEMO/2-b-gang.yaml"
wait_for "team-b's 4 gang pods bound" 300 bound_at_least team-b b-gang 4 || true
sleep 10
echo "submitted at $submitted; PodScheduled per team-b pod (API server time):"
kubectl_cp -n team-b get pods -l job-name=b-gang \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.nodeName}{"  "}{.status.conditions[?(@.type=="PodScheduled")].lastTransitionTime}{"\n"}{end}'
job_pods team-b b-gang
job_pods team-a a-burst
check "team-b gang pods bound" "$(job_bound_count team-b b-gang)" 4
check "team-a pods still Running (its quota)" "$(job_phase_count team-a a-burst Running)" 4
kai_state team-a team-b
events_since_start team-a team-b | grep -i -E "evict|reclaim|preempt|Scheduled|Unschedulable|NotReady" || true

section "3. team-a done; team-b asks for a gang of 6 with 4 GPUs free"
kubectl_cp -n team-a delete job a-burst --wait=true
wait_for "team-a's pods gone" 120 no_pods team-a job-name=a-burst || true
kubectl_cp apply -f "$DEMO/3-b-gang-too-big.yaml"
echo "waiting 90 s: none of the 6 pods may bind"
if wait_for "a b-gang-too-big pod bound" 90 bound_at_least team-b b-gang-too-big 1; then
  echo "a pod of the gang of 6 was bound"
fi
job_pods team-b b-gang-too-big
check "gang of 6: pods bound" "$(job_bound_count team-b b-gang-too-big)" 0
check "gang of 6: pods Pending" "$(job_phase_count team-b b-gang-too-big Pending)" 6
kai_state team-b
pg="$(kubectl_cp -n team-b get podgroups.scheduling.run.ai -o name | grep b-gang-too-big || true)"
if [ -n "$pg" ]; then
  echo "### why KAI holds the gang ($pg)"
  kubectl_cp -n team-b get "$pg" -o jsonpath='{.status.schedulingConditions}' | tr ',' '\n' | head -20
  echo
fi
events_since_start team-b | grep -i b-gang-too-big | tail -10 || true

if [ "${KEEP:-}" != "1" ]; then
  section "Cleanup"
  delete_demo_jobs
fi

section "Result"
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed, see above"
  exit 1
fi
echo "all checks passed"

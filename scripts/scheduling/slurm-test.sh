#!/usr/bin/env bash
#
# Use case 5 on par: an HPC user's view of Slurm through Slinky, and the two
# ways a Slurm node leaves service.
#
#   1. the cluster as Kubernetes and Slurm each see it: pods, Slinky objects,
#      sinfo
#   2. from the login pod: srun -N2 hostname across both Slurm nodes, and an
#      sbatch job to completion
#   3. prolog health check: a SIMULATED fault marker on one node makes the
#      prolog fail; Slurm drains that node ("Prolog error") and holds the job.
#      The marker is removed, the node resumed, the job released and run
#   4. Kubernetes to Slurm: the pod-cordon annotation on a NodeSet pod drains
#      its Slurm node with a "slurm-operator:" reason, visible in sinfo and in
#      the pod's SlurmNodeStateDrain condition; removing it undrains
#
# Step 4 uses the pod annotation rather than cordoning the CPU worker, so other
# lanes' scheduling isn't touched; cordoning the Kubernetes node drives the
# same path (docs/concepts/nodeset-controller.md at 1.2.3).
#
# Needs the CPU worker on and the slinky Application healthy. Writes
# docs/artifacts/scheduling/slurm-par-<stamp>.txt; exits non-zero if a step
# didn't behave as described.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par
require_kubeconfig
require_tools kubectl perl
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NS=slurm
CORDON_ANNOTATION=nodeset.slinky.slurm.net/pod-cordon
FAULT_MARKER=/var/run/eu1-simulated-fault
failures=0
note_fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

login_pod() { kubectl_cp -n "$NS" get pods -o name | grep -m1 login; }
# Run a command in the login pod, as an HPC user would after ssh.
slurm() { kubectl_cp -n "$NS" exec "$LOGIN" -c login -- bash -lc "$*"; }
nodeset_pods() {
  kubectl_cp -n "$NS" get pods -l nodeset.slinky.slurm.net/pod-index \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.nodeset\.slinky\.slurm\.net/pod-hostname}{"\n"}{end}' \
    | sort
}
node_state() { slurm "sinfo -h -N -n $1 -o %T" 2>/dev/null | head -n1; }
node_drained() { node_state "$1" | grep -q -E 'drain'; }
node_idle() { node_state "$1" | grep -q -E '^idle$'; }
job_state() { slurm "scontrol show job $1 -o" 2>/dev/null | grep -o 'JobState=[A-Z_]*' | cut -d= -f2; }
job_completed() { [ "$(job_state "$1")" = COMPLETED ]; }
show_drain_condition() {
  kubectl_cp -n "$NS" get pod "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="SlurmNodeStateDrain")]}{.type}={.status} message="{.message}" since {.lastTransitionTime}{"\n"}{end}'
}

start_capture slurm

section "1. The cluster, from Kubernetes"
kubectl_cp -n "$NS" get pods -o wide
kubectl_cp -n "$NS" get controllers.slinky.slurm.net,nodesets.slinky.slurm.net,loginsets.slinky.slurm.net,restapis.slinky.slurm.net 2>&1 || true
LOGIN="$(login_pod)"
[ -n "$LOGIN" ] || die "no login pod in $NS"
# Pod name and Slurm hostname of the first two NodeSet pods (no mapfile: macOS
# ships bash 3.2).
{ read -r POD_A NODE_A; read -r POD_B NODE_B; } < <(nodeset_pods)
[ -n "${POD_B:-}" ] || die "expected 2 NodeSet pods in $NS"
echo "Slurm nodes: $NODE_A ($POD_A), $NODE_B ($POD_B); login: $LOGIN"

section "1. The cluster, from Slurm"
slurm "sinfo; echo; sinfo -N -l; echo; scontrol show partition | head -20"

section "2. srun across both nodes, then sbatch"
slurm "srun -N2 -l hostname" || note_fail "srun -N2 failed"
job="$(slurm "sbatch --parsable --job-name=eu1-hello --wrap 'hostname; nproc; sleep 5'" | tr -d '\r')"
echo "submitted job $job"
wait_for "job $job completed" 120 job_completed "$job" || note_fail "job $job did not complete"
slurm "scontrol show job $job | grep -E 'JobId|JobState|NodeList|RunTime|ExitCode'"

section "3. Prolog health check: SIMULATED fault on $NODE_A"
kubectl_cp -n "$NS" exec "$POD_A" -c slurmd -- touch "$FAULT_MARKER"
echo "marker $FAULT_MARKER created in $POD_A at $(date -u +%H:%M:%SZ)"
job="$(slurm "sbatch --parsable --job-name=eu1-on-faulty -w $NODE_A --wrap 'hostname'" | tr -d '\r')"
echo "submitted job $job to $NODE_A"
wait_for "$NODE_A drained by the prolog" 120 node_drained "$NODE_A" || note_fail "$NODE_A not drained"
slurm "sinfo -R; echo; scontrol show job $job | grep -E 'JobId|JobState|Reason'"
show_drain_condition "$POD_A"
echo "### fix: remove the marker, resume the node, release the held job"
kubectl_cp -n "$NS" exec "$POD_A" -c slurmd -- rm -f "$FAULT_MARKER"
slurm "scontrol update nodename=$NODE_A state=resume; scontrol release $job" || true
wait_for "job $job completed after the fix" 180 job_completed "$job" || note_fail "job $job did not complete after resume"
slurm "sinfo -N -n $NODE_A; scontrol show job $job | grep -E 'JobId|JobState|Restarts|NodeList'"

section "4. Kubernetes to Slurm: $CORDON_ANNOTATION=true on $POD_B"
kubectl_cp -n "$NS" annotate pod "$POD_B" "$CORDON_ANNOTATION=true" --overwrite
wait_for "$NODE_B drained by the operator" 120 node_drained "$NODE_B" || note_fail "$NODE_B not drained"
slurm "sinfo -R"
show_drain_condition "$POD_B"
kubectl_cp -n "$NS" annotate pod "$POD_B" "$CORDON_ANNOTATION-"
wait_for "$NODE_B back to idle" 120 node_idle "$NODE_B" || note_fail "$NODE_B not undrained"
slurm "sinfo -N"

events_since_start "$NS" | grep -i -E 'drain|cordon|nodeset' | tail -20 || true

section "Result"
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed, see above"
  exit 1
fi
echo "jobs ran from the login pod; prolog and Kubernetes drains both seen from Slurm and Kubernetes"

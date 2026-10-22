#!/usr/bin/env bash
#
# W2 step 5 on fin: MIG on the H200s, then one tenant per slice (use case 4).
#
#   1. checks no pod holds a GPU on the H200 node (mig-manager refuses, or
#      waits, while a GPU is in use)
#   2. waits for the node label nvidia.com/mig.config=h200-split, which cos
#      sets in W2 (a node label is cluster-scoped, so it's cos's line in the
#      run sheet); LABEL=1 makes the script set it itself, outside W2. The GPU
#      Operator's MIG manager then splits GPU0 into two 3g.71gb instances and
#      leaves GPU1 whole
#   3. waits for nvidia.com/mig.config.state=success (MIG_TIMEOUT, 10 min) and
#      for the device plugin to advertise nvidia.com/mig-3g.71gb: 2
#   4. starts workloads/scheduling/mig/tenants.yaml: team-a and team-b on one
#      slice each, team-a on the whole GPU1, and captures what each pod sees
#
# Abort rule from the W2 run sheet: state not success in 10 min, or failed
# (for example mig-parted's nvidia-smi -r reset path failing in the VM). Then
# the script captures the MIG manager's logs and the GPUs' MIG state, and
# exits non-zero; the node is never rebooted (WITH_REBOOT=false in
# gitops/values/scheduling/gpu-operator-fin.yaml). The MIG layout is left as
# is: the node is deleted at teardown.
#
# Writes docs/artifacts/scheduling/mig-fin-<stamp>.txt. KEEP=1 leaves the
# tenant pods running. MIG_CONFIG=rtxpro-split runs the same steps on 2x RTX
# PRO 6000 instead (2g.48gb slices), only with Yassine's approval.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site fin
require_kubeconfig
require_tools kubectl perl
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MIG_TIMEOUT="${MIG_TIMEOUT:-600}"
TENANTS="$REPO_ROOT/workloads/scheduling/mig/tenants.yaml"

# The layout, from gitops/values/scheduling/gpu-operator-fin.yaml. h200-split
# is the plan. MIG_CONFIG=rtxpro-split is the fallback on 2x RTX PRO 6000,
# used only with Yassine's approval at the time.
MIG_CONFIG="${MIG_CONFIG:-h200-split}"
case "$MIG_CONFIG" in
  h200-split) MIG_PROFILE=3g.71gb MIG_EXPECT_GB=71 ;;
  rtxpro-split) MIG_PROFILE=2g.48gb MIG_EXPECT_GB=48 ;;
  *) die "unknown MIG_CONFIG '$MIG_CONFIG', expected h200-split or rtxpro-split" ;;
esac
MIG_RESOURCE="nvidia.com/mig-$MIG_PROFILE"

node="$(kubectl_cp get nodes -l eu1.io/pool=gpu -o jsonpath='{.items[0].metadata.name}')"
[ -n "$node" ] || die "no node with eu1.io/pool=gpu on fin"

node_label() {
  kubectl_cp get node "$node" -o jsonpath="{.metadata.labels.${1//./\\.}}"
}
mig_state_is() { [ "$(node_label nvidia.com/mig.config.state)" = "$1" ]; }
mig_allocatable_is() {
  [ "$(kubectl_cp get node "$node" -o jsonpath="{.status.allocatable.${MIG_RESOURCE//./\\.}}")" = "$1" ]
}
mig_manager_pod() {
  kubectl_cp -n gpu-operator get pods -l app=nvidia-mig-manager \
    --field-selector "spec.nodeName=$node" -o name | head -n1
}
show_node() {
  kubectl_cp get node "$node" -o jsonpath='{"mig.capable="}{.metadata.labels.nvidia\.com/mig\.capable}{"  mig.config="}{.metadata.labels.nvidia\.com/mig\.config}{"  mig.config.state="}{.metadata.labels.nvidia\.com/mig\.config\.state}{"  mig.strategy="}{.metadata.labels.nvidia\.com/mig\.strategy}{"\n"}'
  kubectl_cp get node "$node" -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep -E 'nvidia.com' || true
  echo
}
capture_mig_manager() {
  local pod
  pod="$(mig_manager_pod)"
  echo "### MIG manager ($pod) logs"
  [ -n "$pod" ] && kubectl_cp -n gpu-operator logs "$pod" --tail=200 || echo "(no MIG manager pod on $node)"
  echo "### MIG layout the node reports (nvidia-mig-parted export)"
  [ -n "$pod" ] && kubectl_cp -n gpu-operator exec "$pod" -- nvidia-mig-parted export 2>&1 || true
}

start_capture mig

section "Before: $node"
show_node
echo "### pods on $node asking for a GPU (must be none)"
busy="$(kubectl_cp get pods -A --field-selector "spec.nodeName=$node,status.phase=Running" \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.containers[*].resources.limits}{"\n"}{end}' \
  | grep 'nvidia.com/' || true)"
if [ -n "$busy" ]; then
  echo "$busy"
  die "pods still hold GPUs on $node; delete them (NVCRE, the gang) before MIG"
fi
echo "(none)"

mig_config_is() { [ "$(node_label nvidia.com/mig.config)" = "$MIG_CONFIG" ]; }
if [ "${LABEL:-0}" = "1" ]; then
  section "Label $node nvidia.com/mig.config=$MIG_CONFIG"
  kubectl_cp label node "$node" "nvidia.com/mig.config=$MIG_CONFIG" --overwrite
else
  section "Waiting for cos to label $node nvidia.com/mig.config=$MIG_CONFIG"
  echo "cos runs: kubectl label node $node nvidia.com/mig.config=$MIG_CONFIG --overwrite"
  if ! wait_for "node labelled $MIG_CONFIG" 300 mig_config_is; then
    echo "not labelled in 5 min; nothing changed on the node"
    exit 1
  fi
fi
echo "label nvidia.com/mig.config=$(node_label nvidia.com/mig.config) seen at $(date -u +%H:%M:%SZ)"

section "Wait for the MIG manager (time box ${MIG_TIMEOUT}s)"
# Watch the state change, printing each transition. The node already reads
# success from all-disabled, so success only counts once the MIG manager has
# set pending for the new config (reconfigure.go:158 at v0.15.1). If the
# config was already applied it goes straight to success with no pending
# (reconfigure.go:144); after 60 s of success the allocatable check below
# decides.
last=""
saw_pending=""
start="$(date +%s)"
while :; do
  state="$(node_label nvidia.com/mig.config.state)"
  elapsed=$(($(date +%s) - start))
  if [ "$state" != "$last" ]; then
    echo "$(date -u +%H:%M:%SZ) +${elapsed}s mig.config.state=${state:-<none>}"
    last="$state"
  fi
  case "$state" in
    pending | rebooting) saw_pending=1 ;;
    failed) break ;;
    success)
      if [ -n "$saw_pending" ] || [ "$elapsed" -ge 60 ]; then break; fi
      ;;
  esac
  [ "$elapsed" -ge "$MIG_TIMEOUT" ] && break
  sleep 5
done

if ! mig_state_is success; then
  section "ABORT: MIG not applied (state=${last:-<none>})"
  capture_mig_manager
  show_node
  echo "Cut per the run sheet; recorded as a finding. No reboot."
  exit 1
fi

section "Device plugin advertises the slices"
if ! wait_for "$MIG_RESOURCE: 2 allocatable" 180 mig_allocatable_is 2; then
  show_node
  capture_mig_manager
  echo "MIG applied but the slices are not advertised; cut."
  exit 1
fi
show_node
capture_mig_manager

section "Tenants on their slices"
# tenants.yaml asks for the H200 slice; the fallback swaps in its own.
echo "each slice pod should see about $MIG_EXPECT_GB GB ($MIG_RESOURCE); the whole-GPU pod sees the full card"
sed "s#nvidia.com/mig-3g.71gb#$MIG_RESOURCE#" "$TENANTS" | kubectl_cp apply -f -
pod_running() { [ "$(kubectl_cp -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]; }
not_running=()
for pod in team-a/mig-a team-b/mig-b team-a/whole-a; do
  ns="${pod%/*}" name="${pod#*/}"
  wait_for "$pod running" 300 pod_running "$ns" "$name" || not_running+=("$pod")
done
# A pod KAI holds says why on its PodGroup; record it rather than a bare timeout.
# (bash 3.2 on macOS treats an empty array as unset under set -u.)
for pod in ${not_running[@]+"${not_running[@]}"}; do
  ns="${pod%/*}" name="${pod#*/}"
  pg="$(kubectl_cp -n "$ns" get podgroups.scheduling.run.ai -o name | grep "pg-$name-" | head -n1)"
  echo "### why KAI holds $pod ($pg)"
  [ -n "$pg" ] && kubectl_cp -n "$ns" get "$pg" -o jsonpath='{.status.schedulingConditions[*].message}{"\n"}'
done
sleep 20
kubectl_cp get pods -A -l app=mig-tenant -o wide
for pod in team-a/mig-a team-b/mig-b team-a/whole-a; do
  ns="${pod%/*}" name="${pod#*/}"
  echo "### $pod: $(kubectl_cp -n "$ns" get pod "$name" -o jsonpath='{.spec.containers[0].resources.limits}')"
  kubectl_cp -n "$ns" logs "$name" 2>&1 || true
done
kai_state team-a team-b

if [ "${KEEP:-}" != "1" ]; then
  section "Cleanup (MIG layout kept until teardown)"
  kubectl_cp delete -f "$TENANTS" --ignore-not-found --wait=false
fi

section "Result"
if [ "${#not_running[@]}" -gt 0 ]; then
  echo "MIG $MIG_CONFIG applied on $node; not placed: ${not_running[*]}"
  exit 1
fi
echo "MIG $MIG_CONFIG applied on $node; tenants placed by KAI"

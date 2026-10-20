#!/usr/bin/env bash
#
# Power the par CPU worker off between uses. Drain it first, so the lanes'
# pods stop cleanly and wait Pending for its return, remove its Node object,
# then power it off.
# Scaleway stops billing compute for a powered-off instance and keeps billing
# its disk and IP, about 0.02 euros an hour.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools terraform kubectl curl jq
load_env
require_scaleway_env

CPU_TFVARS="$TF_DIR/cpu.auto.tfvars"
NAME="$(tf_output cpu_worker_name)"

if [ "$(tf_output cpu_worker_enabled)" != "true" ]; then
  log "there is no CPU worker, nothing to power off"
  exit 0
fi

if [ -f "$KUBECONFIG_PATH" ] && kubectl_cp get node "$NAME" >/dev/null 2>&1; then
  log "cordoning and draining $NAME"
  kubectl_cp cordon "$NAME" || warn "cordon failed, continuing"
  # --force for bare pods, and a timeout because a pod that can't go anywhere
  # else (a VM, a pod pinned to this node) would block the drain forever. What
  # is still running when it gives up stops with the power.
  kubectl_cp drain "$NAME" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s \
    || warn "drain did not finish cleanly, powering off anyway"

  # A powered-off node left in the cluster keeps every DaemonSet at one pod
  # short (flannel, kube-proxy, node-exporter), which holds the Applications
  # that own them at Progressing until it returns. So the Node object goes.
  # On power-on the kubelet still has its credentials on disk and registers
  # the node again; cpu-up.sh puts its labels back.
  log "deleting the node object; the kubelet registers it again on power-on"
  kubectl_cp delete node "$NAME" --wait=false || warn "delete node failed, continuing"
fi

cat > "$CPU_TFVARS" <<TFVARS
# Written by scripts/par/cpu-down.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored.
# scripts/par/cpu-up.sh powers the worker back on.
cpu_worker_enabled = true
cpu_worker_running = false
TFVARS

trap 'scaleway_sweep "$(tf_output cluster_name)"' EXIT

log "terraform apply, CPU worker off"
guarded_apply 'cpu_worker' 'CPU worker'
session_close "$NAME"

log "$NAME is powered off. Its disk and IP still bill, about EUR 0.02/h."

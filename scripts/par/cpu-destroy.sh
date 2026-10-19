#!/usr/bin/env bash
#
# Remove the par CPU worker for good, with its disk and its lanes' local-path
# volumes. For the end of the project; between uses, make par-cpu-down powers
# it off instead.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools terraform kubectl curl jq
load_env
require_scaleway_env

CPU_TFVARS="$TF_DIR/cpu.auto.tfvars"
NAME="$(tf_output cpu_worker_name)"
IP="$(tf_output cpu_worker_public_ip)"

if [ -f "$KUBECONFIG_PATH" ] && kubectl_cp get node "$NAME" >/dev/null 2>&1; then
  kubectl_cp cordon "$NAME" || true
  kubectl_cp drain "$NAME" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s \
    || warn "drain did not finish cleanly, continuing"
  kubectl_cp delete node "$NAME" --wait=false || warn "delete node failed, continuing"
fi

cat > "$CPU_TFVARS" <<TFVARS
# Written by scripts/par/cpu-destroy.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored.
cpu_worker_enabled = false
cpu_worker_running = false
TFVARS

trap 'scaleway_sweep "$(tf_output cluster_name)"' EXIT

log "terraform apply, destroying the CPU worker"
guarded_apply 'cpu_worker' 'CPU worker'
[ -n "$IP" ] && forget_host "$IP"
session_close "$NAME"

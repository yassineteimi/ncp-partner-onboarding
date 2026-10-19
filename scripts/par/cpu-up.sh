#!/usr/bin/env bash
#
# Start the par CPU worker: create it the first time, power it on after that,
# and wait until it is a Ready, schedulable node.
#
# The first time, the node runs its bootstrap and joins with a fresh token,
# exactly like the L4. After a power-off it comes back with its disk, its
# local-path volumes and its kubelet credentials, so it only has to report
# Ready and be uncordoned.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools terraform kubectl ssh ssh-keygen
load_env
require_scaleway_env
require_kubeconfig

CPU_TFVARS="$TF_DIR/cpu.auto.tfvars"
CP_PUBLIC_IP="$(tf_output control_plane_public_ip)"
[ -n "$CP_PUBLIC_IP" ] || die "no control plane in the Terraform state. Run make par-cluster first."

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timeline_start "$ARTIFACTS/cpu-up-$(date -u +%Y%m%dT%H%M%SZ).txt"
mark apply_started

cat > "$CPU_TFVARS" <<TFVARS
# Written by scripts/par/cpu-up.sh at $STARTED. Gitignored.
# scripts/par/cpu-down.sh powers the worker off; cpu-destroy.sh removes it.
cpu_worker_enabled = true
cpu_worker_running = true
TFVARS

log "terraform apply, CPU worker on"
guarded_apply 'cpu_worker' 'CPU worker'
mark instance_running

NAME="$(tf_output cpu_worker_name)"
IP="$(tf_output cpu_worker_public_ip)"
[ -n "$IP" ] || die "terraform produced no CPU worker address"

session_open "$NAME" "$(tf_output cpu_worker_type)" "$PAR_CPU_HOURLY_EUR" EUR "$STARTED"

if kubectl_cp get node "$NAME" >/dev/null 2>&1; then
  log "$NAME is already a member of the cluster: waiting for it to come back Ready"
  kubectl_cp wait --for=condition=Ready "node/$NAME" --timeout=600s
  mark node_ready
  kubectl_cp uncordon "$NAME"
else
  forget_host "$IP"
  wait_for_ssh "$IP" 600
  wait_for_bootstrap "$IP" 1800
  mark bootstrap_complete

  log "asking the control plane for a fresh join command"
  JOIN_COMMAND="$(node_ssh "$CP_PUBLIC_IP" 'kubeadm token create --ttl 30m --print-join-command')"
  case "$JOIN_COMMAND" in
    "kubeadm join "*--discovery-token-ca-cert-hash*) : ;;
    *) die "the control plane did not return a usable join command" ;;
  esac

  log "joining $NAME to the cluster"
  node_ssh "$IP" "$JOIN_COMMAND --node-name $NAME --cri-socket unix:///run/containerd/containerd.sock"
  kubectl_cp wait --for=condition=Ready "node/$NAME" --timeout=600s
  mark node_ready
  kubectl_cp label node "$NAME" eu1.io/site=par eu1.io/pool=cpu --overwrite

  mkdir -p "$ARTIFACTS"
  {
    echo "# $NAME, captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/par/cpu-up.sh"
    node_ssh "$IP" cat /var/lib/eu1/bootstrap-facts.txt /var/lib/eu1/virtualisation.txt
  } > "$ARTIFACTS/cpu-worker-facts.txt"
  log "node facts, including whether /dev/kvm exists, saved to ${ARTIFACTS#"$REPO_ROOT"/}/cpu-worker-facts.txt"
fi

kubectl_cp get nodes -o wide

cat <<TXT

CPU worker $NAME is up and billing at about EUR $PAR_CPU_HOURLY_EUR/h. Power it off with:

  make par-cpu-down

TXT

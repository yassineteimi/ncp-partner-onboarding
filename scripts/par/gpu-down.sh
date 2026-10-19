#!/usr/bin/env bash
#
# End a GPU window on site par: take the L4 node out of the cluster properly,
# then destroy it.
#
# The order matters. Cordon so nothing new lands on it, drain so running pods
# are evicted and rescheduled rather than killed with the instance, delete the
# node object so the control plane stops waiting for a kubelet that is never
# coming back, and only then destroy the hardware.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools terraform kubectl ssh-keygen curl jq
load_env
require_scaleway_env

GPU_NODE_NAME="$(tf_output gpu_node_name)"
GPU_PUBLIC_IP="$(tf_output gpu_node_public_ip)"
CLUSTER_NAME="$(tf_output cluster_name)"

if [ "$(tf_output gpu_node_enabled)" != "true" ]; then
  log "gpu_node_enabled is already false, nothing to tear down"
else
  if [ -f "$KUBECONFIG_PATH" ] && [ -n "$GPU_NODE_NAME" ]; then
    if kubectl_cp get node "$GPU_NODE_NAME" >/dev/null 2>&1; then
      log "cordoning $GPU_NODE_NAME"
      kubectl_cp cordon "$GPU_NODE_NAME" || warn "cordon failed, continuing"

      log "draining $GPU_NODE_NAME"
      kubectl_cp drain "$GPU_NODE_NAME" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=180s || warn "drain did not finish cleanly, continuing"

      log "deleting the node object"
      kubectl_cp delete node "$GPU_NODE_NAME" --wait=false || warn "delete node failed, continuing"
    else
      warn "$GPU_NODE_NAME is not in the cluster, skipping the drain"
    fi
  else
    warn "no kubeconfig or no node name, skipping the drain"
  fi
fi

########################################
# Destroy
########################################

cat > "$GPU_TFVARS" <<EOF
# Written by scripts/par/gpu-down.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored.
# scripts/par/gpu-up.sh sets this back to true.
gpu_node_enabled = false
EOF

# The sweep runs whether the apply worked or not. In Part 1 a failed boot left
# a 150 GB volume billing where Terraform couldn't see it.
trap 'scaleway_sweep "${CLUSTER_NAME:-eu1-par}"' EXIT

log "terraform apply, destroying the GPU node"
apply_gpu_only

[ -n "$GPU_PUBLIC_IP" ] && forget_host "$GPU_PUBLIC_IP"
[ -n "$GPU_NODE_NAME" ] && session_close "$GPU_NODE_NAME"

log "GPU node destroyed. Nothing GPU shaped is billing on par."
"$REPO_ROOT/scripts/par/cost-report.sh" || true

#!/usr/bin/env bash
#
# Bring up the fin control plane: preflight, the instance, kubeadm, ArgoCD.
#
# It costs cents an hour, so in a window it runs first, before the H200 is
# ordered: by the time the GPU node joins, ArgoCD has already synced the base
# platform and the GPU node's paid minutes go to the GPU node alone.
#
#   make fin-cp-up            HOURS=2 by default, for the preflight's budget
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site fin

require_tools terraform kubectl helm ssh ssh-keygen curl jq
load_env
require_verda_env

CP_TFVARS="$TF_DIR/cp.auto.tfvars"
POD_SUBNET="10.244.0.0/16"
SERVICE_SUBNET="10.96.0.0/12"
FLANNEL_VERSION="v0.28.9"

tf init -input=false >/dev/null

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timeline_start "$ARTIFACTS/cp-bringup-$(date -u +%Y%m%dT%H%M%SZ).txt"
mark started

if [ "$(tf_output cp_enabled)" = "true" ]; then
  warn "the fin control plane is already declared. Converging rather than creating."
  CP_PRICE="$(jq -r '.control_plane.price_per_hour' "$(ls -t "$ARTIFACTS"/preflight-*.json | head -1)")"
else
  log "preflight, control plane only"
  "$REPO_ROOT/scripts/fin/preflight.sh" --cp-only
  RECORD="$(ls -t "$ARTIFACTS"/preflight-*.json | head -1)"
  CP_PRICE="$(jq -r '.control_plane.price_per_hour' "$RECORD")"

  cat > "$CP_TFVARS" <<TFVARS
# Written by scripts/fin/cp-up.sh at $STARTED from ${RECORD#"$REPO_ROOT"/}. Gitignored.
cp_enabled       = true
cp_location      = "$(jq -r '.gpu.location' "$RECORD")"
cp_instance_type = "$(jq -r '.control_plane.type' "$RECORD")"
cp_image         = "$(jq -r '.images.control_plane.type' "$RECORD")"
TFVARS
fi
mark preflight_done

# Nothing may be destroyed or replaced by bringing a node up.
log "terraform apply, control plane"
guarded_apply '^$' 'nothing'
mark instance_running

NAME="$(tf_output cp_name)"
IP="$(tf_output cp_ip)"
[ -n "$IP" ] || die "terraform produced no control plane address"
session_open "$NAME" "$(tf_output cp_instance_type)" "$CP_PRICE" USD "$STARTED"
log "control plane is $NAME at $IP"

# par's Thanos Receive NodePort opens to this address, and only this one.
"$REPO_ROOT/scripts/par/metrics-peers.sh" "$IP"

forget_host "$IP"
wait_for_ssh "$IP" 600
wait_for_bootstrap "$IP" 1200
mark bootstrap_complete

NODE_IP="$(node_ssh "$IP" "NODE_NAME=$NAME PUBLIC_IP=$IP bash -s" < "$REPO_ROOT/scripts/fin/remote/node-address.sh")"
log "the kubelet advertises $NODE_IP"

node_ssh "$IP" "NODE_NAME=$NAME NODE_IP=$NODE_IP PUBLIC_IP=$IP CLUSTER_NAME=$(tf_output cluster_name) POD_SUBNET=$POD_SUBNET SERVICE_SUBNET=$SERVICE_SUBNET FLANNEL_VERSION=$FLANNEL_VERSION bash -s" \
  < "$REPO_ROOT/scripts/fin/remote/cp-init.sh"
mark kubeadm_ready

########################################
# Kubeconfig, pointed at the public address, which is a certificate SAN
########################################

umask 077
node_ssh "$IP" cat /etc/kubernetes/admin.conf > "$KUBECONFIG_PATH"
if [ "$NODE_IP" != "$IP" ]; then
  sed -i.bak "s#https://$NODE_IP:6443#https://$IP:6443#" "$KUBECONFIG_PATH"
  rm -f "$KUBECONFIG_PATH.bak"
fi
chmod 600 "$KUBECONFIG_PATH"
umask 022
kubectl_cp wait --for=condition=Ready "node/$NAME" --timeout=300s

########################################
# Use case 6 hook, before the root Application
#
# fin's Prometheus remote-writes to par over mTLS, and its client certificate
# has to be in fin's monitoring namespace before kube-prometheus-stack syncs:
# without it the Prometheus Operator can't render the remote-write config,
# kube-prometheus-stack stays Degraded at wave 0, and the GPU Operator at wave
# 1 never syncs. ws-platform owns the script; this only calls it. Missing, it
# is skipped (fin then works without use case 6). Failing, it stops here, at
# the control plane stage, before any GPU is ordered.
########################################

HOOK="$REPO_ROOT/scripts/platform/fin-remote-write-secret.sh"
if [ -x "$HOOK" ]; then
  log "running the use case 6 hook ${HOOK#"$REPO_ROOT"/}"
  PAR_KUBECONFIG="$REPO_ROOT/kubeconfig-par" FIN_KUBECONFIG="$KUBECONFIG_PATH" "$HOOK" \
    || die "the use case 6 hook failed. To run the window without use case 6, remove gitops/values/platform/kube-prometheus-stack-fin.yaml on main first."
  mark platform_hook_done
else
  warn "no ${HOOK#"$REPO_ROOT"/}: fin comes up without the remote-write secret (use case 6 off)"
fi

bootstrap_argocd
mark argocd_installed

########################################
# Evidence: what landed on the node, read off the node
########################################

FACTS="$ARTIFACTS/control-plane-facts.txt"
{
  echo "# $NAME, captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/fin/cp-up.sh"
  node_ssh "$IP" cat /var/lib/eu1/bootstrap-facts.txt
  echo
  node_ssh "$IP" cat /var/lib/eu1/image-inventory.txt
  echo
  kubectl_cp get nodes -o wide
} > "$FACTS"
log "node facts saved to ${FACTS#"$REPO_ROOT"/}, bring-up timeline to ${TIMELINE#"$REPO_ROOT"/}"

cat <<EOF

fin control plane $NAME is up at $IP, billing about $CP_PRICE USD/h. Next:

  make fin-gpu-up      the GPU node joins this control plane
  make fin-down        delete the whole site, with its volumes

EOF

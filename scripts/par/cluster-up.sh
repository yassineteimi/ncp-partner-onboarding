#!/usr/bin/env bash
#
# Create the persistent half of site par: the private network and the control
# plane node. Idempotent. Run it once at the start of the project and again any
# time the control plane has been destroyed.
#
# The CPU worker and the L4 are not touched here. They have their own up and
# down scripts, so that nothing bigger than the control plane bills while
# nobody needs it.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools terraform kubectl ssh ssh-keygen
load_env
require_scaleway_env

log "terraform init"
tf init -input=false

log "terraform apply, control plane and network"
tf apply -input=false -auto-approve

CP_PUBLIC_IP="$(tf_output control_plane_public_ip)"
CP_NODE_NAME="$(tf_output control_plane_name)"
[ -n "$CP_PUBLIC_IP" ] || die "terraform produced no control plane address"

log "control plane is $CP_NODE_NAME at $CP_PUBLIC_IP"

forget_host "$CP_PUBLIC_IP"
wait_for_ssh "$CP_PUBLIC_IP" 300
wait_for_bootstrap "$CP_PUBLIC_IP" 1200

########################################
# Kubeconfig
#
# kubeadm writes admin.conf pointing at the control plane endpoint, which in
# private mode is an address only the cluster can reach. The public address is
# already a certificate SAN, so rewriting the server field here is enough to
# make the same credentials work from a laptop.
########################################

log "fetching the kubeconfig"
umask 077
node_ssh "$CP_PUBLIC_IP" cat /etc/kubernetes/admin.conf > "$KUBECONFIG_PATH"

CP_NODE_IP="$(tf_output control_plane_node_ip)"
if [ -n "$CP_NODE_IP" ] && [ "$CP_NODE_IP" != "$CP_PUBLIC_IP" ]; then
  sed -i.bak "s#https://$CP_NODE_IP:6443#https://$CP_PUBLIC_IP:6443#" "$KUBECONFIG_PATH"
  rm -f "$KUBECONFIG_PATH.bak"
fi
chmod 600 "$KUBECONFIG_PATH"

log "waiting for the control plane to report Ready"
kubectl_cp wait --for=condition=Ready "node/$CP_NODE_NAME" --timeout=300s

########################################
# Evidence: what actually landed on the node, read off the node.
########################################

umask 022
mkdir -p "$ARTIFACTS"
FACTS="$ARTIFACTS/control-plane-facts.txt"
{
  echo "# $CP_NODE_NAME, captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/par/cluster-up.sh"
  node_ssh "$CP_PUBLIC_IP" cat /var/lib/eu1/bootstrap-facts.txt
  echo
  kubectl_cp get nodes -o wide
} > "$FACTS"
log "node facts saved to ${FACTS#"$REPO_ROOT"/}"

kubectl_cp get nodes -o wide

cat <<EOF

Site par is up. Point kubectl at it with:

  export KUBECONFIG=$KUBECONFIG_PATH

Next, install ArgoCD and hand it gitops/sites/par/root.yaml:

  make par-argocd

EOF

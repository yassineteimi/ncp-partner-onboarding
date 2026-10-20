#!/usr/bin/env bash
#
# Bring up the fin GPU node and join it to the fin control plane, then wait
# for its GPUs to be allocatable. The timeline it writes, from order to GPUs
# allocatable, is EU1's Day 1 metric for the training pool.
#
#   make fin-gpu-up                 the 2x H200 node, after a full preflight
#   REHEARSAL=1 make fin-gpu-up     a CPU stand-in booting the GPU image, for
#                                   cents: everything but the GPUs themselves
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site fin

require_tools terraform kubectl ssh ssh-keygen curl jq
load_env
require_verda_env
require_kubeconfig

REHEARSAL="${REHEARSAL:-0}"
CP_IP="$(tf_output cp_ip)"
[ -n "$CP_IP" ] || die "no fin control plane. Run make fin-cp-up first."

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timeline_start "$ARTIFACTS/gpu-bringup-$(date -u +%Y%m%dT%H%M%SZ)$([ "$REHEARSAL" = 1 ] && echo -rehearsal).txt"
mark started

if [ "$REHEARSAL" = 1 ]; then
  # The cheapest CPU type orderable where the control plane runs.
  CP_LOCATION="$(sed -n 's/^cp_location *= *"\(.*\)"/\1/p' "$TF_DIR/cp.auto.tfvars")"
  verda_login
  TYPE=""
  for candidate in CPU.4V.16G CPU-TURIN.4V.16G CPU.8V.32G CPU-TURIN.8V.32G; do
    if verda_get instance-availability | jq -e --arg l "$CP_LOCATION" --arg t "$candidate" \
      '.[] | select(.location_code == $l) | .availabilities | index($t)' >/dev/null; then
      TYPE="$candidate"; break
    fi
  done
  [ -n "$TYPE" ] || die "no CPU type orderable in $CP_LOCATION for the rehearsal"
  PRICE="$(verda_get instance-types | jq -r --arg t "$TYPE" '.[] | select(.instance_type == $t) | .price_per_hour')"
  LOCATION="$CP_LOCATION" SPOT=false IMAGE="26.04.cuda13.4" CHECK=rehearsal
  warn "REHEARSAL: $TYPE boots the GPU image in $LOCATION. There is no GPU; this tests the node, not the hardware."
else
  log "preflight, GPU window"
  "$REPO_ROOT/scripts/fin/preflight.sh"
  RECORD="$(ls -t "$ARTIFACTS"/preflight-*.json | head -1)"
  TYPE="$(jq -r '.gpu.type' "$RECORD")"
  LOCATION="$(jq -r '.gpu.location' "$RECORD")"
  SPOT="$(jq -r '.gpu.spot' "$RECORD")"
  PRICE="$(jq -r '.gpu.price_per_hour' "$RECORD")"
  IMAGE="$(jq -r '.images.gpu.type' "$RECORD")"
  CHECK=required
fi
mark preflight_done

cat > "$GPU_TFVARS" <<TFVARS
# Written by scripts/fin/gpu-up.sh at $STARTED. Gitignored.
gpu_enabled       = true
gpu_location      = "$LOCATION"
gpu_instance_type = "$TYPE"
gpu_is_spot       = $SPOT
gpu_image         = "$IMAGE"
gpu_driver_check  = "$CHECK"
TFVARS

log "terraform apply, GPU node $TYPE in $LOCATION$([ "$SPOT" = true ] && echo ', on spot')"
guarded_apply '^$' 'nothing'
mark instance_running

NAME="$(tf_output gpu_name)"
IP="$(tf_output gpu_ip)"
[ -n "$IP" ] || die "terraform produced no GPU node address"
session_open "$NAME" "$TYPE" "$PRICE" USD "$STARTED"
log "GPU node is $NAME at $IP, billing $PRICE USD/h"

forget_host "$IP"
wait_for_ssh "$IP" 600
wait_for_bootstrap "$IP" 1500
mark bootstrap_complete

########################################
# The two nodes trust each other's address, and nothing else
########################################

node_ssh "$CP_IP" "echo $IP > /etc/eu1/peers && /usr/local/sbin/eu1-firewall"
node_ssh "$IP" "echo $CP_IP > /etc/eu1/peers && /usr/local/sbin/eu1-firewall"

########################################
# Join
########################################

NODE_IP="$(node_ssh "$IP" "NODE_NAME=$NAME PUBLIC_IP=$IP bash -s" < "$REPO_ROOT/scripts/fin/remote/node-address.sh")"

log "asking the control plane for a fresh join command"
JOIN_COMMAND="$(node_ssh "$CP_IP" 'kubeadm token create --ttl 30m --print-join-command')"
case "$JOIN_COMMAND" in
  "kubeadm join "*--discovery-token-ca-cert-hash*) : ;;
  *) die "the control plane did not return a usable join command" ;;
esac

log "joining $NAME, advertising $NODE_IP"
node_ssh "$IP" "$JOIN_COMMAND --node-name $NAME --cri-socket unix:///run/containerd/containerd.sock"
kubectl_cp wait --for=condition=Ready "node/$NAME" --timeout=600s
mark node_ready
kubectl_cp label node "$NAME" eu1.io/site=fin eu1.io/pool=gpu --overwrite

########################################
# The GPU Operator, with the provider's driver, advertises the GPUs
########################################

if [ "$REHEARSAL" != 1 ]; then
  EXPECTED="${GPU_EXPECTED:-2}"
  log "waiting for $EXPECTED nvidia.com/gpu on $NAME"
  deadline=$(( $(date +%s) + 1200 ))
  count=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    count="$(kubectl_cp get node "$NAME" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
    [ "${count:-0}" = "$EXPECTED" ] && break
    sleep 15
  done
  if [ "${count:-0}" = "$EXPECTED" ]; then
    mark gpu_allocatable
  else
    warn "only ${count:-0} of $EXPECTED GPUs allocatable after 20 minutes. Check: kubectl -n gpu-operator get pods"
  fi
fi

########################################
# Evidence: the image as it arrived, its driver, the node as it joined
########################################

INVENTORY="$ARTIFACTS/image-inventory-$(date -u +%Y%m%dT%H%M%SZ)$([ "$REHEARSAL" = 1 ] && echo -rehearsal).txt"
{
  echo "# $NAME ($TYPE, image $IMAGE), captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/fin/gpu-up.sh"
  node_ssh "$IP" cat /var/lib/eu1/image-inventory.txt /var/lib/eu1/bootstrap-facts.txt
  echo
  kubectl_cp get node "$NAME" -o wide
} > "$INVENTORY"
log "image inventory saved to ${INVENTORY#"$REPO_ROOT"/}, bring-up timeline to ${TIMELINE#"$REPO_ROOT"/}"

kubectl_cp get nodes -o wide

cat <<EOF

GPU node $NAME is up, billing $PRICE USD/h until:

  make fin-down

EOF

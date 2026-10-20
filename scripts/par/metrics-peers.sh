#!/usr/bin/env bash
#
# Set which fin addresses may reach par's Thanos Receive NodePort (use case 6),
# on the CPU worker's security group, and nothing else.
#
#   scripts/par/metrics-peers.sh 217.177.40.32 86.38.238.80   open to these
#   scripts/par/metrics-peers.sh                              close it
#
# Called by scripts/fin/cp-up.sh and gpu-up.sh once each fin instance has an
# address, and by scripts/fin/down.sh with none. The plan is limited to the
# security group with -target and checked before it is applied: it must
# update that one resource in place and touch nothing else.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools terraform jq
load_env
require_scaleway_env

SG='scaleway_instance_security_group.cpu_worker[0]'
PORT="$(tf_output metrics_ingress_port)"
PORT="${PORT:-30291}"
PEERS_TFVARS="$TF_DIR/fin-peers.auto.tfvars"

if [ "$(tf_output cpu_worker_enabled)" != "true" ]; then
  warn "there is no par CPU worker, so no security group to open: fin metrics can't reach par"
  exit 0
fi

ips="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))')"
cat > "$PEERS_TFVARS" <<TFVARS
# Written by scripts/par/metrics-peers.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored.
fin_peer_ips = $ips
TFVARS

plan="$TF_DIR/metrics-peers.tfplan"
tf plan -input=false -out="$plan" -target="$SG" >/dev/null
changes="$(terraform -chdir="$TF_DIR" show -json "$plan" \
  | jq -c '[.resource_changes[] | select(.change.actions != ["no-op"]) | {address, actions: .change.actions}]')"

case "$changes" in
  '[]')
    rm -f "$plan"
    if [ "$ips" = "[]" ]; then
      log "metrics port $PORT already closed to fin (no change)"
    else
      log "metrics port $PORT already open to $(jq -r 'join(", ")' <<<"$ips") (no change)"
    fi
    exit 0 ;;
  "[{\"address\":\"$SG\",\"actions\":[\"update\"]}]") : ;;
  *)
    rm -f "$plan"
    die "refusing: the plan does more than update $SG: $changes" ;;
esac

tf apply -input=false "$plan" >/dev/null
rm -f "$plan"
if [ "$ips" = "[]" ]; then
  log "metrics port $PORT closed to fin"
else
  log "metrics port $PORT open to $(jq -r 'join(", ")' <<<"$ips") only"
fi

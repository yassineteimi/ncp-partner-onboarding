#!/usr/bin/env bash
#
# Delete site fin: every instance with its OS volume, then sweep Verda for
# anything left. Never shutdown: a shut-down Verda instance keeps billing.
#
# The delete goes through the API rather than terraform destroy, with each
# instance's OS volume ID in volume_ids and delete_permanently set. Provider
# 1.1.4 sends volume_ids: null and relies on the API's default, and before
# 1.1.4 its destroy left every OS volume detached and billing (provider issue
# #17). Its Read also fails on an instance that no longer exists, so the
# deleted instances are then removed from the Terraform state by hand.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site fin

require_tools terraform jq curl ssh-keygen
load_env
require_verda_env

CP_TFVARS="$TF_DIR/cp.auto.tfvars"
tf init -input=false >/dev/null

INSTANCES="$(terraform -chdir="$TF_DIR" output -json instances 2>/dev/null || echo '{}')"
[ -n "$INSTANCES" ] && [ "$INSTANCES" != "null" ] || INSTANCES='{}'
CP_IP="$(tf_output cp_ip)" GPU_IP="$(tf_output gpu_ip)"
CP_NAME="$(tf_output cp_name)" GPU_NAME="$(tf_output gpu_name)"
CLUSTER="$(tf_output cluster_name)"

# The sweep runs whatever happens below.
trap 'verda_sweep "${CLUSTER:-eu1-fin}"' EXIT

if [ "$(jq 'length' <<<"$INSTANCES")" -eq 0 ]; then
  log "no fin instance in the Terraform state"
else
  ids="$(jq -c '[.[].id]' <<<"$INSTANCES")"
  volumes="$(jq -c '[.[].os_volume_id | select(. != null and . != "")]' <<<"$INSTANCES")"
  log "deleting $(jq -r '[.[].hostname] | join(", ")' <<<"$INSTANCES") with OS volumes $volumes, permanently"

  verda_login
  verda_put instances "$(jq -n --argjson id "$ids" --argjson v "$volumes" \
    '{action: "delete", id: $id, volume_ids: $v, delete_permanently: true}')" | jq -c '.' || die "the delete request failed"

  log "waiting for Verda to report the instances gone"
  deadline=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    left="$(verda_get instances | jq --argjson id "$ids" '[.[] | select(.id as $i | $id | index($i))] | length')"
    [ "$left" -eq 0 ] && break
    sleep 10
  done
  [ "${left:-1}" -eq 0 ] || warn "$left instance(s) still listed after 10 minutes; the sweep below shows them"

  # The volumes go after the instances: in the rehearsal on 20 October they
  # were still listed as detached 20 seconds after the instances had gone, and
  # gone 20 seconds later. Sweeping before that reports a false leftover.
  log "waiting for Verda to delete the OS volumes"
  deadline=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    left_volumes="$(verda_get volumes | jq --argjson v "$volumes" '[.[] | select(.id as $i | $v | index($i))] | length')"
    [ "$left_volumes" -eq 0 ] && break
    sleep 10
  done
  [ "${left_volumes:-1}" -eq 0 ] || warn "$left_volumes OS volume(s) still listed after 5 minutes; the sweep below shows them"

  for address in $(jq -r 'keys[]' <<<"$INSTANCES"); do
    tf state rm "$address" >/dev/null && log "removed $address from the Terraform state"
  done
fi

cat > "$CP_TFVARS" <<TFVARS
# Written by scripts/fin/down.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored.
cp_enabled = false
TFVARS
cat > "$GPU_TFVARS" <<TFVARS
# Written by scripts/fin/down.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored.
gpu_enabled = false
TFVARS

# What remains in the state is free (the SSH key and the startup scripts), and
# goes too, so that between windows nothing of the site is left at Verda.
log "terraform apply, removing the SSH key and startup scripts"
guarded_apply 'verda_ssh_key|verda_startup_script' 'SSH key or startup scripts'

session_close "$CP_NAME"
session_close "$GPU_NAME"
[ -n "$CP_IP" ] && forget_host "$CP_IP"
[ -n "$GPU_IP" ] && forget_host "$GPU_IP"
rm -f "$KUBECONFIG_PATH"

log "site fin deleted"
"$REPO_ROOT/scripts/par/cost-report.sh" || true

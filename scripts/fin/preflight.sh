#!/usr/bin/env bash
#
# Preflight for a fin window. Free: it only reads the Verda API and creates
# nothing. It refuses to let a window start unless:
#
#   - the H200 node can be ordered somewhere, on demand or else on spot (the
#     one fallback Yassine has pre-approved),
#   - the prepaid balance covers 1.5 times the window's budget,
#   - nothing is left over from an earlier window: no instance, no volume, no
#     volume in the trash.
#
#   scripts/fin/preflight.sh                 a 2 hour window with the H200 node
#   HOURS=1 scripts/fin/preflight.sh         a 1 hour window
#   scripts/fin/preflight.sh --cp-only       the control plane alone (rehearsal)
#
# It writes everything it read, and what it chose, to
# docs/artifacts/fin/preflight-<UTC>.json. scripts/fin/cp-up.sh and gpu-up.sh
# run it and turn its choices into Terraform variables.
#
# Exit codes: 0 go, 2 no H200 to order, 3 balance too low, 4 leftovers.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site fin

require_tools curl jq
load_env_optional
require_verda_env

HOURS="${HOURS:-2}"
GPU_TYPE="${GPU_TYPE:-2H200.141S.88V}"
FALLBACK_TYPE="2RTXPRO6000.60V"
GPU_IMAGE_TYPE="${GPU_IMAGE_TYPE:-26.04.cuda13.4}"
CP_IMAGE_TYPE="${CP_IMAGE_TYPE:-26.04.base}"
# The control plane runs kubeadm, ArgoCD, a light Prometheus and the NVCRE
# controller. 8 vCPU and 32 GB first; whatever the location offers after that.
CPU_PREFERENCE="${CPU_PREFERENCE:-CPU.8V.32G CPU-TURIN.8V.32G CPU.16V.64G CPU-TURIN.16V.64G CPU.4V.16G CPU-TURIN.4V.16G}"
CP_ONLY=false
[ "${1:-}" = "--cp-only" ] && CP_ONLY=true

# NVMe OS volumes of the nodes the window creates, billed per GB and month.
DISK_GB="${DISK_GB:-$([ "$CP_ONLY" = true ] && echo 100 || echo 300)}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ARTIFACTS/preflight-$STAMP.json"

verda_login
balance="$(verda_get balance)"
on_demand="$(verda_get instance-availability)"
spot="$(verda_get 'instance-availability?is_spot=true')"
types="$(verda_get instance-types)"
images="$(verda_get images)"
instances="$(verda_get instances)"
volumes="$(verda_get volumes)"
trash="$(verda_get volumes/trash)"
volume_types="$(verda_get volume-types)"

where() { # locations offering a type in an availability listing
  jq -r --arg t "$1" '[.[] | select(.availabilities | index($t)) | .location_code] | join(" ")' <<<"$2"
}

########################################
# Where the GPU node can be ordered
########################################

gpu_on_demand="$(where "$GPU_TYPE" "$on_demand")"
gpu_spot="$(where "$GPU_TYPE" "$spot")"
fallback_on_demand="$(where "$FALLBACK_TYPE" "$on_demand")"

location="" is_spot=false verdict=go exit_code=0 reason=""
if [ "$CP_ONLY" = true ]; then
  # A rehearsal goes where the H200 would go if it could, else FIN-01.
  location="${gpu_on_demand%% *}"; location="${location:-${gpu_spot%% *}}"; location="${location:-FIN-01}"
elif [ -n "$gpu_on_demand" ]; then
  location="${gpu_on_demand%% *}"
elif [ -n "$gpu_spot" ]; then
  location="${gpu_spot%% *}"; is_spot=true
  warn "$GPU_TYPE is only orderable on spot, in $gpu_spot. Spot is pre-approved; Verda can reclaim it mid-window."
else
  verdict=stop exit_code=2
  reason="$GPU_TYPE can't be ordered anywhere, on demand or on spot. $FALLBACK_TYPE on demand: ${fallback_on_demand:-nowhere}. Switching hardware needs Yassine's approval."
fi

########################################
# The control plane type, in the same location
########################################

cpu_type=""
if [ -n "$location" ]; then
  for candidate in $CPU_PREFERENCE; do
    if jq -e --arg l "$location" --arg t "$candidate" \
      '.[] | select(.location_code == $l) | .availabilities | index($t)' <<<"$on_demand" >/dev/null; then
      cpu_type="$candidate"; break
    fi
  done
  [ -n "$cpu_type" ] || { verdict=stop; exit_code=2; reason="no CPU type from '$CPU_PREFERENCE' can be ordered in $location"; }
fi

price() { # on demand or spot price of a type, per hour
  jq -r --arg t "$1" --arg field "$2" '.[] | select(.instance_type == $t) | .[$field] // empty' <<<"$types"
}
gpu_price="$(price "$GPU_TYPE" "$([ "$is_spot" = true ] && echo spot_price || echo price_per_hour)")"
cpu_price="$([ -n "$cpu_type" ] && price "$cpu_type" price_per_hour || echo 0)"
currency="$(jq -r '.currency' <<<"$balance")"
disk_price="$(jq -r --argjson gb "$DISK_GB" '.[] | select(.type == "NVMe") | .price.price_per_month_per_gb * $gb / 730' <<<"$volume_types")"

if [ "$CP_ONLY" = true ]; then
  budget="$(jq -n --argjson h "$HOURS" --argjson c "${cpu_price:-0}" --argjson d "${disk_price:-0}" '$h * ($c + $d)')"
else
  budget="$(jq -n --argjson h "$HOURS" --argjson g "${gpu_price:-0}" --argjson c "${cpu_price:-0}" --argjson d "${disk_price:-0}" '$h * ($g + $c + $d)')"
fi
required="$(jq -n --argjson b "$budget" '$b * 1.5')"
amount="$(jq -r '.amount' <<<"$balance")"

if [ "$verdict" = go ] && ! jq -e -n --argjson a "$amount" --argjson r "$required" '$a >= $r' >/dev/null; then
  verdict=stop exit_code=3
  reason="balance $amount $currency doesn't cover 1.5 times the budget ($required $currency)"
fi

########################################
# Leftovers from an earlier window
########################################

# Before the GPU node, make fin-cp-up has already created this window's control
# plane. Terraform's state knows it and its OS volume, so they are not
# leftovers; anything Terraform doesn't know still stops the window.
known="[]"
if [ "$CP_ONLY" = false ]; then
  known="$(terraform -chdir="$TF_DIR" output -json instances 2>/dev/null | jq -c '[.[] | .id, .os_volume_id]' 2>/dev/null || echo "[]")"
fi
leftovers="$(jq -n --argjson i "$instances" --argjson v "$volumes" --argjson t "$trash" --argjson k "$known" \
  '{instances: [$i[] | select(.id as $id | $k | index($id) | not) | {id, hostname, status}],
    volumes: [$v[] | select(.id as $id | $k | index($id) | not) | {id, name, status, instance_id}],
    trash: [$t[] | {id, name}]}')"
if [ "$verdict" = go ] && [ "$(jq '[.instances, .volumes, .trash] | map(length) | add' <<<"$leftovers")" -gt 0 ]; then
  verdict=stop exit_code=4
  reason="something from an earlier window is still at Verda, see leftovers; clean it up before ordering anything"
fi

########################################
# Images, and what we know of the driver
########################################

gpu_image="$(jq -r --arg t "$GPU_IMAGE_TYPE" '.[] | select(.image_type == $t) | .id' <<<"$images")"
cp_image="$(jq -r --arg t "$CP_IMAGE_TYPE" '.[] | select(.image_type == $t) | .id' <<<"$images")"
gpu_image_name="$(jq -r --arg t "$GPU_IMAGE_TYPE" '.[] | select(.image_type == $t) | .name' <<<"$images")"
[ -n "$gpu_image" ] && [ -n "$cp_image" ] || { verdict=stop; exit_code=2; reason="image $GPU_IMAGE_TYPE or $CP_IMAGE_TYPE not offered any more"; }

# The API names the CUDA release, not the driver. The first boot of the image
# records the driver; the newest such record is quoted here.
driver="unknown until the image's first boot"
inventory="$(ls -t "$ARTIFACTS"/image-inventory-*.txt 2>/dev/null | head -1 || true)"
if [ -n "$inventory" ]; then
  driver="$(grep -m1 -E '^driver_version=' "$inventory" | cut -d= -f2) (from ${inventory#"$REPO_ROOT"/})"
fi

########################################
# Record and decide
########################################

mkdir -p "$ARTIFACTS"
jq -n \
  --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg verdict "$verdict" --arg reason "$reason" \
  --arg gpu_type "$GPU_TYPE" --arg location "$location" --argjson is_spot "$is_spot" --argjson cp_only "$CP_ONLY" \
  --arg gpu_on_demand "$gpu_on_demand" --arg gpu_spot "$gpu_spot" --arg fallback_on_demand "$fallback_on_demand" \
  --arg cpu_type "$cpu_type" --arg gpu_price "$gpu_price" --arg cpu_price "$cpu_price" \
  --argjson hours "$HOURS" --argjson budget "$budget" --argjson required "$required" --argjson balance "$balance" \
  --argjson disk_gb "$DISK_GB" --arg disk_price "$disk_price" \
  --arg gpu_image "$gpu_image" --arg gpu_image_name "$gpu_image_name" --arg cp_image "$cp_image" --arg driver "$driver" \
  --arg gpu_image_type "$GPU_IMAGE_TYPE" --arg cp_image_type "$CP_IMAGE_TYPE" \
  --argjson leftovers "$leftovers" \
  '{checked_at: $checked_at, verdict: $verdict, reason: $reason, cp_only: $cp_only,
    gpu: {type: $gpu_type, location: $location, spot: $is_spot, price_per_hour: $gpu_price,
          orderable_on_demand_in: $gpu_on_demand, orderable_on_spot_in: $gpu_spot,
          fallback_2RTXPRO6000_on_demand_in: $fallback_on_demand},
    control_plane: {type: $cpu_type, price_per_hour: $cpu_price},
    disks: {nvme_gb: $disk_gb, price_per_hour: $disk_price},
    budget: {hours: $hours, cost: $budget, required_balance: $required, balance: $balance},
    images: {gpu: {type: $gpu_image_type, id: $gpu_image, name: $gpu_image_name, driver: $driver},
             control_plane: {type: $cp_image_type, id: $cp_image}},
    leftovers: $leftovers}' > "$OUT"
log "preflight record saved to ${OUT#"$REPO_ROOT"/}"

if [ "$verdict" != go ]; then
  warn "STOP: $reason"
  exit "$exit_code"
fi

log "GO: $([ "$CP_ONLY" = true ] && echo "control plane only" || echo "$GPU_TYPE $([ "$is_spot" = true ] && echo on spot || echo on demand) at $gpu_price $currency/h") in $location, control plane $cpu_type at $cpu_price $currency/h"
log "budget $budget $currency for $HOURS h; balance $amount $currency covers the 1.5x rule ($required $currency)"
log "GPU image $gpu_image_name ($gpu_image), driver: $driver"

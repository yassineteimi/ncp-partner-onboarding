#!/usr/bin/env bash
#
# Log where EU1's training node can be ordered right now, on demand and on
# spot, in every Verda location. Free: it only reads /v1/instance-availability
# and creates nothing.
#
#   scripts/fin/availability.sh           one check, appended to the CSV
#   scripts/fin/availability.sh --watch   the same every 10 minutes until stopped
#
# On 19 October 2026 at 20:55 UTC no 2x H200 could be ordered in any Finnish
# location. This log shows how often that is true before a window depends on
# it, and it is capacity evidence for the story: the hardware a partner plans
# around isn't always there to rent.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site fin

require_tools curl jq
load_env_optional
require_verda_env

TYPES="${TYPES:-2H200.141S.88V 1H200.141S.44V 2RTXPRO6000.60V}"
INTERVAL="${INTERVAL:-600}"
CSV="$ARTIFACTS/h200-availability.csv"

check_once() {
  local now on_demand spot type location od sp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  verda_login
  on_demand="$(verda_get instance-availability)"
  spot="$(verda_get 'instance-availability?is_spot=true')"

  mkdir -p "$ARTIFACTS"
  [ -f "$CSV" ] || echo "checked_at,instance_type,location,on_demand,spot" > "$CSV"

  for type in $TYPES; do
    for location in $(jq -r '.[].location_code' <<<"$on_demand"); do
      od="$(jq -r --arg l "$location" --arg t "$type" '[.[] | select(.location_code == $l) | .availabilities[] | select(. == $t)] | length > 0' <<<"$on_demand")"
      sp="$(jq -r --arg l "$location" --arg t "$type" '[.[] | select(.location_code == $l) | .availabilities[] | select(. == $t)] | length > 0' <<<"$spot")"
      echo "$now,$type,$location,$od,$sp" >> "$CSV"
    done
  done
  log "$now: $(grep "^$now,2H200" "$CSV" | awk -F, '{printf "%s od=%s spot=%s  ", $3, $4, $5}')"
}

if [ "${1:-}" = "--watch" ]; then
  log "checking every ${INTERVAL}s into ${CSV#"$REPO_ROOT"/}. Ctrl-C or kill to stop."
  while true; do
    check_once || warn "check failed, retrying next round"
    sleep "$INTERVAL"
  done
else
  check_once
fi

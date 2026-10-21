#!/usr/bin/env bash
#
# SIMULATED. Proves the compactor's downsampling on par before real data is
# old enough: a 2 hour GPU window never reaches the 40 hours a block must span
# before Thanos downsamples it to 5 minutes (pkg/compact/downsample at v0.42.4),
# and par's own uploads only get there after about two days.
#
# Writes five days of a synthetic series, eu1_sim_backfill_gpu_util, ending
# three hours ago, turns it into TSDB blocks with promtool, and uploads them
# to the thanos bucket with the external labels site="sim-backfill" and
# simulated="true". Its own metric name keeps it out of every GPU panel.
#
# promtool 3.14 cuts 2 hour blocks, so the compactor first merges them into
# 8 hour and then 2 day blocks, and only a 2 day block is long enough to
# downsample. Five days always contain one whole 2 day window, whatever the
# alignment. Expect 5 minute blocks about an hour after the upload: the
# compactor skips blocks younger than its 30 minute consistency delay.
# The 1 hour level needs blocks over 10 days and is not shown.
#
# Uses par's API server only to read the bucket credentials and to
# port-forward to Garage. Run `make thanos-capture MODE=bucket` afterwards.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools kubectl promtool thanos python3

use_site par
require_kubeconfig

WORK="$(mktemp -d)"
PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null && wait "$PF_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

log "writing five days of synthetic samples"
python3 - "$WORK/backfill.om" <<'PY'
import math, sys, time
end = int(time.time()) - 3 * 3600
start = end - 5 * 24 * 3600
with open(sys.argv[1], "w") as f:
    f.write("# HELP eu1_sim_backfill_gpu_util SIMULATED. Synthetic GPU utilisation for the downsampling check.\n")
    f.write("# TYPE eu1_sim_backfill_gpu_util gauge\n")
    for gpu in ("0", "1"):
        for t in range(start, end, 60):
            # a daily cycle, so a 5 minute average and the raw data look alike
            v = 50 + 40 * math.sin(2 * math.pi * (t % 86400) / 86400 + int(gpu))
            f.write(f'eu1_sim_backfill_gpu_util{{gpu="{gpu}"}} {v:.2f} {t}\n')
    f.write("# EOF\n")
print(f"{start} to {end}, 2 series, one sample a minute")
PY

log "promtool tsdb create-blocks-from openmetrics"
promtool tsdb create-blocks-from openmetrics "$WORK/backfill.om" "$WORK/blocks" | tail -n 3
log "$(find "$WORK/blocks" -name meta.json | wc -l | tr -d ' ') blocks"

log "port-forwarding to Garage"
kubectl_cp -n checkpoint-store port-forward svc/garage 13900:3900 > "$WORK/pf.log" 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do grep -q 'Forwarding from' "$WORK/pf.log" && break; sleep 1; done
grep -q 'Forwarding from' "$WORK/pf.log" || die "port-forward to Garage failed: $(cat "$WORK/pf.log")"

kubectl_cp -n thanos get secret thanos-objstore -o 'jsonpath={.data.objstore\.yml}' | base64 -d \
  | sed 's#endpoint: .*#endpoint: 127.0.0.1:13900#' > "$WORK/objstore.yml"
chmod 600 "$WORK/objstore.yml"

log "uploading with site=sim-backfill, simulated=true"
thanos tools bucket upload-blocks --path="$WORK/blocks" --objstore.config-file="$WORK/objstore.yml" \
  --label='site="sim-backfill"' --label='simulated="true"' 2>&1 | grep -v -i 'secret' | tail -n 5

log "uploaded. The compactor should show 5 minute blocks for site=sim-backfill in about an hour"

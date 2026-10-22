#!/usr/bin/env bash
#
# Evidence for use case 6, read through par's API server. Changes nothing.
#
#   capture-thanos.sh hub       after a merge: components, stores, tenants,
#                               deduplication of fin-sim's two replicas,
#                               sidecar uploads, blocks in Garage, and
#                               port 30291 closed to this laptop
#   capture-thanos.sh fin       during a window: fin's series seen from par,
#                               DCGM series per GPU, and fin's own TSDB
#                               status (needs FIN_KUBECONFIG)
#   capture-thanos.sh after     after fin-down: the same queries, each series's last value within 3 h
#   capture-thanos.sh par       during W1: the L4's DCGM series per GPU, and
#                               par's own TSDB status
#   capture-thanos.sh bucket    the blocks in Garage, by tenant and resolution
#
# AT=<RFC 3339 or Unix time> evaluates every query at that moment instead of
# now, to read a site as it was: AT=2026-10-22T10:23:00Z MODE=fin shows the
# Finland H200s five minutes after the MIG split, from what Thanos stored.
#
# Each run writes docs/artifacts/platform/thanos-<mode>-<timestamp>.txt.
# Times are this laptop's clock, UTC, plus Prometheus's own sample timestamps.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools kubectl python3 curl

MODE="${1:-}"
case "$MODE" in hub | fin | after | par | bucket) ;; *) die "usage: $0 hub|fin|after|par|bucket" ;; esac

use_site par
require_kubeconfig
CPU_WORKER_IP="${CPU_WORKER_IP:-51.159.176.50}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTFILE="$REPO_ROOT/docs/artifacts/platform/thanos-$MODE-$STAMP.txt"
mkdir -p "$(dirname "$OUTFILE")"
exec > >(perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*m//g' | tee "$OUTFILE") 2>&1
echo "# capture-thanos.sh $MODE, $STAMP, laptop clock, UTC. git $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
AT="${AT:-}"
[ -z "$AT" ] || echo "# every query evaluated at $AT, not now"

# PromQL through Thanos Query, via the API server's service proxy.
# q <title> <query> [dedup true|false]
q() {
  local title="$1" query="$2" dedup="${3:-true}" path
  path="$(python3 -c '
import sys, urllib.parse as u
p = {"query": sys.argv[1], "dedup": sys.argv[2]}
if sys.argv[3]:
    p["time"] = sys.argv[3]
print("/api/v1/namespaces/thanos/services/thanos-query:9090/proxy/api/v1/query?" + u.urlencode(p))' "$query" "$dedup" "$AT")"
  echo
  echo "## $title"
  echo "# $query   (dedup=$dedup)"
  kubectl_cp get --raw "$path" | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r.get("status") != "success":
    print(r); sys.exit(0)
res = r["data"]["result"]
if not res:
    print("(no data)")
for s in sorted(res, key=lambda s: sorted(s["metric"].items())):
    labels = ", ".join(f"{k}=\"{v}\"" for k, v in sorted(s["metric"].items()))
    print("{" + labels + "}", s["value"][1])
for w in r.get("warnings", []) or []:
    print("warning:", w)
'
}

stores() {
  echo
  echo "## Stores Query sees"
  kubectl_cp get --raw "/api/v1/namespaces/thanos/services/thanos-query:9090/proxy/api/v1/stores" | python3 -c '
import json, sys
for kind, stores in sorted(json.load(sys.stdin)["data"].items()):
    for s in stores:
        print(kind, s["name"], "labelSets:", s.get("labelSets"), "minTime:", s.get("minTime"), "maxTime:", s.get("maxTime"), "lastError:", s.get("lastError"))
'
}

# A site's own Prometheus: head series and the top label pairs, read on that site.
# tsdb_status <kubeconfig> <site>
tsdb_status() {
  echo
  echo "## $2's own TSDB status (head series, top label pairs), read on $2"
  kubectl --kubeconfig "$1" get --raw \
    "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/status/tsdb?limit=15" \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
print("headStats:", d.get("headStats"))
for k in ("seriesCountByMetricName", "labelValueCountByLabelName", "seriesCountByLabelValuePair"):
    print()
    print(k + ":")
    for e in d.get(k, []):
        print("  %s: %s" % (e["name"], e["value"]))
'
}

bucket() {
  echo
  echo "## Blocks in the thanos bucket (thanos tools bucket inspect, from the compactor pod)"
  kubectl_cp -n thanos exec thanos-compact-0 -c thanos -- \
    thanos tools bucket inspect --objstore.config-file=/etc/thanos/objstore/objstore.yml --output=tsv 2>/dev/null \
    || echo "(could not inspect the bucket: is thanos-compact-0 running?)"
}

case "$MODE" in
  hub)
    echo
    echo "## Pods"
    kubectl_cp -n thanos get pods -o wide
    kubectl_cp -n fin-sim get pods -o wide 2>/dev/null || echo "(no fin-sim namespace)"
    stores
    q "Series per tenant and site, without deduplication" 'count by (tenant_id, site, prometheus_replica) ({__name__=~".+"})' false
    q "fin-sim, without deduplication: one count per replica" 'count by (prometheus_replica) (up{site="fin-sim"})' false
    q "fin-sim, with deduplication: the replicas merged" 'count(up{site="fin-sim"})' true
    q "Samples Receive accepted per tenant, last 10 minutes" 'sum by (tenant) (increase(prometheus_tsdb_head_samples_appended_total{namespace="thanos", pod=~"thanos-receive-.*"}[10m]))'
    q "Head series per tenant in Receive" 'max by (tenant) (prometheus_tsdb_head_series{namespace="thanos", pod=~"thanos-receive-.*"})'
    q "par sidecar: blocks uploaded" 'max(thanos_shipper_uploads_total)'
    q "par sidecar: failed uploads" 'max(thanos_shipper_upload_failures_total)'
    bucket
    echo
    echo "## Port 30291 from this laptop (must not answer: only fin's /32s are allowed)"
    if curl -sk --max-time 5 -o /dev/null "https://$CPU_WORKER_IP:30291/"; then
      echo "ANSWERED: the port is open to this laptop"
    else
      echo "no answer within 5 s (curl exit $?), as expected"
    fi
    ;;
  fin | after)
    # An instant query only sees a series for 5 minutes after its last sample
    # (Prometheus's lookback). After fin-down, every fin series is older than
    # that, so "after" reads each one's last value within 3 hours instead.
    if [ "$MODE" = after ]; then
      last() { echo "last_over_time($1[3h])"; }
      at="last value within 3 h"
      stamp='max by (site) (max_over_time(timestamp(up)[3h:15s]))'
    else
      last() { echo "$1"; }
      at="now"
      stamp='max by (site) (timestamp(up))'
    fi
    stores
    q "Sites and tenants seen ($at)" "count by (site, tenant_id) ($(last up))"
    q "Last sample per site (Unix seconds)" "$stamp"
    # Counted by GPU, from a field every whole GPU and every MIG instance
    # reports. Counting series read 13 for 2 H200s after fin-down, and
    # counting GPU_UTIL read 1 after the MIG split.
    q "GPUs per site and model ($at)" "count by (site, modelName) (max by (site, modelName, hostname, gpu) ($(last DCGM_FI_DEV_FB_USED)))"
    q "GPU utilisation, whole GPUs ($at)" "max by (site, modelName, hostname, gpu) ($(last DCGM_FI_DEV_GPU_UTIL))"
    q "GPU utilisation, max over the last 3 h" 'max by (site, modelName, hostname, gpu) (max_over_time(DCGM_FI_DEV_GPU_UTIL[3h]))'
    # MIG instances don't report GPU_UTIL: graphics engine active, as a percentage.
    q "MIG instance utilisation, graphics engine active, % ($at)" "100 * max by (site, modelName, hostname, gpu, GPU_I_ID, GPU_I_PROFILE) ($(last 'DCGM_FI_PROF_GR_ENGINE_ACTIVE{GPU_I_ID!=""}'))"
    q "DCGM series per GPU (recording rule)" 'max by (site, modelName, hostname, gpu) (max_over_time(gpu:dcgm_series:count[3h]))'
    q "DCGM series per GPU and MIG instance (recording rule)" 'max by (site, modelName, hostname, gpu, GPU_I_ID, GPU_I_PROFILE) (max_over_time(gpu:dcgm_series_by_instance:count[3h]))'
    if [ "$MODE" = fin ]; then
      # The same, counted from the raw series at one instant, so it also works
      # on data stored before the rule existed (with AT).
      q "DCGM series per GPU and MIG instance, counted directly (now)" 'count by (site, hostname, gpu, GPU_I_ID, GPU_I_PROFILE) ({__name__=~"DCGM_.+", site="fin"})'
    fi
    q "DCGM series per GPU, top metrics on fin" 'topk(15, max by (metric) (max_over_time(gpu:dcgm_series_by_metric:count{site="fin"}[3h])))'
    # Each site's own Prometheus reports its head: one series per site. A
    # count over {__name__=~".+"} would make par's Prometheus, on the 4 vCPU
    # control plane, touch every series it holds.
    q "Head series in each site's Prometheus ($at, not only DCGM)" "max by (site) ($(last 'prometheus_tsdb_head_series{job="kube-prometheus-stack-prometheus", site=~"par|fin"}'))"
    q "fin's remote write: samples sent, failed, retried ($at)" "max by (__name__) ($(last '{__name__=~"prometheus_remote_storage_(samples_total|samples_failed_total|samples_retried_total|highest_timestamp_in_seconds|queue_highest_sent_timestamp_seconds)", site="fin"}'))"
    if [ "$MODE" = fin ]; then
      FIN_KUBECONFIG="${FIN_KUBECONFIG:-$REPO_ROOT/kubeconfig-fin}"
      if [ -f "$FIN_KUBECONFIG" ]; then
        tsdb_status "$FIN_KUBECONFIG" fin
      else
        warn "no fin kubeconfig at $FIN_KUBECONFIG, skipping fin's own TSDB status"
      fi
    fi
    ;;
  par)
    # W1-b: the L4's DCGM cardinality, the same figures W2 takes on fin.
    q "GPUs on par" 'count by (site, modelName, hostname) (DCGM_FI_DEV_GPU_UTIL{site="par"})'
    q "DCGM series per GPU (recording rule, now)" 'max by (site, modelName, hostname, gpu) (gpu:dcgm_series:count{site="par"})'
    q "DCGM series per GPU (recording rule, max over the last 3 h)" 'max by (site, modelName, hostname, gpu) (max_over_time(gpu:dcgm_series:count{site="par"}[3h]))'
    q "DCGM series per GPU, top metrics on par" 'topk(15, max by (metric) (max_over_time(gpu:dcgm_series_by_metric:count{site="par"}[3h])))'
    q "DCGM series per GPU, counted directly (cross-check of the rule)" 'count by (hostname, gpu) ({__name__=~"DCGM_.+", site="par"})'
    q "Head series in par's Prometheus" 'max(prometheus_tsdb_head_series{job="kube-prometheus-stack-prometheus", site="par"})'
    tsdb_status "$KUBECONFIG_PATH" par
    ;;
  bucket)
    bucket
    ;;
esac

echo
echo "# written to ${OUTFILE#"$REPO_ROOT"/}"

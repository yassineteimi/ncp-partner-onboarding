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
#   capture-thanos.sh after     after fin-down: the same queries, with fin gone
#   capture-thanos.sh bucket    the blocks in Garage, by tenant and resolution
#
# Each run writes docs/artifacts/platform/thanos-<mode>-<timestamp>.txt.
# Times are this laptop's clock, UTC, plus Prometheus's own sample timestamps.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools kubectl python3 curl

MODE="${1:-}"
case "$MODE" in hub | fin | after | bucket) ;; *) die "usage: $0 hub|fin|after|bucket" ;; esac

use_site par
require_kubeconfig
CPU_WORKER_IP="${CPU_WORKER_IP:-51.159.176.50}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTFILE="$REPO_ROOT/docs/artifacts/platform/thanos-$MODE-$STAMP.txt"
mkdir -p "$(dirname "$OUTFILE")"
exec > >(perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*m//g' | tee "$OUTFILE") 2>&1
echo "# capture-thanos.sh $MODE, $STAMP, laptop clock, UTC. git $(git -C "$REPO_ROOT" rev-parse --short HEAD)"

# PromQL through Thanos Query, via the API server's service proxy.
# q <title> <query> [dedup true|false]
q() {
  local title="$1" query="$2" dedup="${3:-true}" path
  path="$(python3 -c 'import sys, urllib.parse as u; print("/api/v1/namespaces/thanos/services/thanos-query:9090/proxy/api/v1/query?" + u.urlencode({"query": sys.argv[1], "dedup": sys.argv[2]}))' "$query" "$dedup")"
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
    stores
    q "Sites and tenants seen" 'count by (site, tenant_id) (up)'
    q "Last sample per site (Unix seconds)" 'max by (site) (timestamp(up))'
    q "GPUs per site and model" 'count by (site, modelName) (DCGM_FI_DEV_GPU_UTIL)'
    q "GPU utilisation now" 'max by (site, modelName, Hostname, gpu) (DCGM_FI_DEV_GPU_UTIL)'
    q "GPU utilisation, max over the last 3 h" 'max by (site, modelName, Hostname, gpu) (max_over_time(DCGM_FI_DEV_GPU_UTIL[3h]))'
    q "DCGM series per GPU (recording rule)" 'max by (site, modelName, Hostname, gpu) (max_over_time(gpu:dcgm_series:count[3h]))'
    q "DCGM series per GPU, top metrics on fin" 'topk(15, max by (metric) (max_over_time(gpu:dcgm_series_by_metric:count{site="fin"}[3h])))'
    # Each site's own Prometheus reports its head: one series per site. A
    # count over {__name__=~".+"} would make par's Prometheus, on the 4 vCPU
    # control plane, touch every series it holds.
    q "Head series in each site's Prometheus (not only DCGM)" 'max by (site) (prometheus_tsdb_head_series{job="kube-prometheus-stack-prometheus", site=~"par|fin"})'
    q "fin's remote write: samples sent, failed, retried" 'max by (__name__) ({__name__=~"prometheus_remote_storage_(samples_total|samples_failed_total|samples_retried_total|highest_timestamp_in_seconds|queue_highest_sent_timestamp_seconds)", site="fin"})'
    if [ "$MODE" = fin ]; then
      FIN_KUBECONFIG="${FIN_KUBECONFIG:-$REPO_ROOT/kubeconfig-fin}"
      if [ -f "$FIN_KUBECONFIG" ]; then
        echo
        echo "## fin's own TSDB status (head series, top label pairs), read on fin"
        kubectl --kubeconfig "$FIN_KUBECONFIG" get --raw \
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
      else
        warn "no fin kubeconfig at $FIN_KUBECONFIG, skipping fin's own TSDB status"
      fi
    fi
    ;;
  bucket)
    bucket
    ;;
esac

echo
echo "# written to ${OUTFILE#"$REPO_ROOT"/}"

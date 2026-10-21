#!/usr/bin/env bash
#
# Evidence for use case 7, read through par's API server. Changes nothing.
#
#   - KubeVirt's version and phase, and where its components run
#   - the tenant VM: phase, node, and KubeVirt's own phase timestamps (boot)
#   - what the virt-launcher pod requests next to the guest, against the quota
#   - the page the guest serves, read through the Service (API server proxy):
#     systemd-detect-virt inside the guest says "kvm" under KVM, "qemu" under
#     emulation
#   - every pod that holds a GPU at that moment, to show the VM running next
#     to GPU workloads (W1-a, while par's L4 is up)
#
# Writes docs/artifacts/platform/kubevirt-<timestamp>.txt.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools kubectl python3

use_site par
require_kubeconfig
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTFILE="$REPO_ROOT/docs/artifacts/platform/kubevirt-$STAMP.txt"
mkdir -p "$(dirname "$OUTFILE")"
exec > >(perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*m//g' | tee "$OUTFILE") 2>&1
echo "# capture-kubevirt.sh, $STAMP, laptop clock, UTC. git $(git -C "$REPO_ROOT" rev-parse --short HEAD)"

section() { echo; echo "## $*"; }

section "KubeVirt"
kubectl_cp -n kubevirt get kubevirt kubevirt \
  -o jsonpath='{"phase: "}{.status.phase}{"\nversion: "}{.status.observedKubeVirtVersion}{"\nuseEmulation: "}{.spec.configuration.developerConfiguration.useEmulation}{"\n"}'
kubectl_cp -n kubevirt get pods -o wide

section "Nodes"
kubectl_cp get nodes -L eu1.io/site,eu1.io/pool -o wide

section "The tenant VM"
kubectl_cp -n tenant-vm get vm,vmi -o wide
kubectl_cp -n tenant-vm get vmi web-01 -o json | python3 -c '
import json, sys
from datetime import datetime
v = json.load(sys.stdin)
st = v.get("status", {})
print("node:", st.get("nodeName"), " phase:", st.get("phase"))
ts = st.get("phaseTransitionTimestamps", [])
created = datetime.fromisoformat(v["metadata"]["creationTimestamp"].replace("Z", "+00:00"))
for t in ts:
    at = datetime.fromisoformat(t["phaseTransitionTimestamp"].replace("Z", "+00:00"))
    print(f"  {t[\"phase\"]:<12} {t[\"phaseTransitionTimestamp\"]}  +{(at - created).total_seconds():.0f} s after the VMI was created")
for c in st.get("conditions", []):
    print(f"  condition {c[\"type\"]}={c[\"status\"]} {c.get(\"reason\", \"\")}")
'

section "What the VM costs the cluster: virt-launcher's requests against the quota"
kubectl_cp -n tenant-vm get pods -l app.kubernetes.io/name=web-01 -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    print("pod", p["metadata"]["name"], "on", p["spec"].get("nodeName"))
    for c in p["spec"]["containers"]:
        r = c.get("resources", {})
        print(f"  {c[\"name\"]:<20} requests {r.get(\"requests\", {})}  limits {r.get(\"limits\", {})}")
'
kubectl_cp -n tenant-vm describe resourcequota tenant-vm | sed -n '/Resource/,$p'

section "The guest's own page, through Service tenant-vm/web-01"
kubectl_cp get --raw /api/v1/namespaces/tenant-vm/services/web-01:80/proxy/index.txt \
  || echo "(no answer from the guest yet)"

section "Pods holding a GPU right now, cluster-wide"
kubectl_cp get pods -A -o json | python3 -c '
import json, sys
rows = []
for p in json.load(sys.stdin)["items"]:
    n = 0
    for c in p["spec"].get("containers", []):
        for k, v in (c.get("resources", {}).get("limits", {}) or {}).items():
            if k.startswith("nvidia.com/"):
                n += int(v) if str(v).isdigit() else 0
    if n:
        rows.append((p["metadata"]["namespace"], p["metadata"]["name"], p["spec"].get("nodeName"), p["status"].get("phase"), n))
if not rows:
    print("(none: no GPU workload is running at this moment)")
for r in rows:
    print("%-16s %-48s %-18s %-10s gpus=%d" % r)
'

echo
echo "# written to ${OUTFILE#"$REPO_ROOT"/}"

#!/usr/bin/env bash
#
# SIMULATED GPU fault: write one NVRM Xid line into a node's kernel log.
#
#   scripts/readiness/inject-xid.sh <node> <xid>
#   PRINT_ONLY=1 scripts/readiness/inject-xid.sh <node> <xid>   print what the node would run, touch nothing
#
# The line has the exact shape the driver prints (src/nvidia/src/kernel/gpu/rc/
# kernel_rc.c at 595.91.07), so a detector sees what it would see on a real
# fault. Its message says SIMULATED, so the node's own kernel log is honest
# about where it came from. Nothing happens to the GPU: the driver, the device
# plugin and DCGM learn about XIDs through NVML and never see this line.
#
# Copied from Part 1 (scripts/inject-xid.sh at 9607e50) with one change, the
# [uptime] in front of NVRM. Part 1's detector, node-problem-detector, read
# /dev/kmsg itself. NVSentinel's syslog monitor reads journald instead, and a
# line written to /dev/kmsg from userspace is logged with facility LOG_USER,
# so journald takes its first word, "NVRM:", as the syslog identifier and
# strips it from MESSAGE. The pattern in health-monitors/syslog-health-monitor/
# pkg/patterns/xid.go at v1.28.0 needs "NVRM: Xid" in MESSAGE, so Part 1's line
# never matches. A leading "[seconds]" is not an identifier, so MESSAGE keeps
# the whole line, which is also how NVSentinel's own tests/uat/tests.sh writes
# it. Shown on systemd 255 in docs/artifacts/readiness/fc2-journald-*.txt. A
# real XID is printed by the kernel at LOG_KERN and isn't affected.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

NODE="${1:?usage: scripts/readiness/inject-xid.sh <node> <xid>}"
XID="${2:?usage: scripts/readiness/inject-xid.sh <node> <xid>}"
[[ "$XID" =~ ^[0-9]+$ ]] || die "XID must be a number, got $XID"
TIMELINE="$REPO_ROOT/docs/artifacts/readiness/xid-timeline.txt"

# One kmsg record: priority 3 (err), the uptime in the kernel's own format,
# then the driver's line.
record() {
  local uptime="$1" pci="$2"
  printf '<3>[%s] NVRM: Xid (PCI:%s): %s, pid=0, name=inject-xid.sh, SIMULATED by scripts/readiness/inject-xid.sh, not a real fault\n' \
    "$uptime" "$pci" "$XID"
}

# The script the node runs: the record with the node's uptime, into /dev/kmsg,
# then the node's clock.
remote_write() {
  declare -f record
  printf 'XID=%q\n' "$XID"
  printf 'record "$(awk %q /proc/uptime)" %q > /dev/kmsg\n' '{print $1}' "$PCI"
  echo 'date -u +%Y-%m-%dT%H:%M:%S.%3NZ'
}

if [ "${PRINT_ONLY:-0}" = 1 ]; then
  PCI=0000:01:00
  remote_write
  exit 0
fi

require_tools kubectl ssh
require_kubeconfig
load_env
resolve_ssh_keypair

# The SSH address of a node, from Terraform, which is the only thing that knows it.
if [ "$NODE" = "$(tf_output gpu_node_name)" ]; then
  HOST="$(tf_output gpu_node_public_ip)"
elif kubectl_cp get node "$NODE" -o jsonpath='{.metadata.labels}' | grep -q 'node-role.kubernetes.io/control-plane'; then
  HOST="$(tf_output control_plane_public_ip)"
else
  die "don't know how to reach $NODE"
fi
[ -n "$HOST" ] || die "no address for $NODE in Terraform outputs"

# The GPU's real PCI address if there is one, so the line names the right device
# and NVSentinel can attach the GPU's UUID from its metadata collector.
PCI="$(node_ssh "$HOST" "lspci -D -d 10de: 2>/dev/null | awk 'NR==1{print substr(\$1,1,10)}'" || true)"
PCI="${PCI:-0000:01:00}"

log "SIMULATED: writing XID $XID for PCI $PCI into the kernel log of $NODE"
# The injection time comes from the node's own clock, in the same command as the
# write, so it can be compared with the controllers' timestamps and not with this
# laptop. The uptime is read in that command too.
at="$(remote_write | node_ssh "$HOST" bash -s)"
mkdir -p "$(dirname "$TIMELINE")"
echo "xid_injected=$at node=$NODE xid=$XID simulated=true" | tee -a "$TIMELINE"
node_ssh "$HOST" "journalctl -k -o cat --since -1min | grep 'NVRM: Xid' | tail -1"

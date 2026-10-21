"""Does a simulated XID line reach NVSentinel's syslog monitor?

The monitor reads journald (_TRANSPORT=kernel) and matches MESSAGE against
XIDPattern, copied verbatim from health-monitors/syslog-health-monitor/pkg/
patterns/xid.go at v1.28.0. Go's RE2 and Python's re read this pattern the
same way: no backreferences, no lookarounds.

The fixtures are what journald really stored on Ubuntu 24.04, systemd 255
(docs/artifacts/readiness/fc2-journald-*.txt):
  journal-fc2.jsonl        FC2-A, Part 1's line; FC2-B, the same with [uptime]
  journal-fc2-fixed.jsonl  the record inject-xid.sh writes now
"""

import json
import os
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
SCRIPT = HERE.parent / "inject-xid.sh"

XID_PATTERN = re.compile(
    r"NVRM: Xid \(PCI:([0-9a-fA-F:.]+)(?: GPU-I:\d+)?(?: GPU-CI:\d+)?\): (\d+)"
    r"(?:, pid=(\d+))?(?:, name=([^,]+))?(?:, Ch ([0-9a-fA-F]+))?"
)


def kernel_records(name):
    lines = (HERE / "fixtures" / name).read_text().splitlines()
    return [r for r in map(json.loads, lines) if r["_TRANSPORT"] == "kernel"]


def xid_seen(record):
    match = XID_PATTERN.search(record["MESSAGE"])
    return int(match.group(2)) if match else None


def test_part1_line_loses_nvrm_to_the_identifier():
    a = next(r for r in kernel_records("journal-fc2.jsonl") if "FC2-A" in r["MESSAGE"])
    assert a["SYSLOG_IDENTIFIER"] == "NVRM"
    assert xid_seen(a) is None


def test_uptime_prefix_keeps_the_line():
    b = next(r for r in kernel_records("journal-fc2.jsonl") if "FC2-B" in r["MESSAGE"])
    assert "SYSLOG_IDENTIFIER" not in b or b["SYSLOG_IDENTIFIER"] is None
    assert xid_seen(b) == 79


def test_the_record_the_script_writes_now_is_seen():
    [record] = kernel_records("journal-fc2-fixed.jsonl")
    assert xid_seen(record) == 79
    assert "SIMULATED" in record["MESSAGE"]


def test_the_script_still_writes_that_record():
    env = dict(os.environ, PRINT_ONLY="1")
    out = subprocess.run(["bash", str(SCRIPT), "eu1-par-gpu-01", "79"],
                         env=env, check=True, capture_output=True, text=True).stdout
    # Run what the node would run, with the kernel log swapped for stdout and a
    # fixed uptime, then do what journald does with a leading "<3>".
    node_script = out.replace("> /dev/kmsg", "").replace("/proc/uptime", "/dev/null")
    line = subprocess.run(["bash", "-c", node_script], check=True,
                          capture_output=True, text=True).stdout.splitlines()[0]
    assert line.startswith("<3>[")
    assert xid_seen({"MESSAGE": line[len("<3>"):]}) == 79

"""Phases of the outage, from a recorded log with known answers.

The log is hand-made: the sequence NVSentinel is expected to produce, with
round numbers, not a measurement.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
import timeline  # noqa: E402

T0 = 1_792_000_000.0  # the injection
NODE = dict(kind="node", event="MODIFIED", unschedulable=False, taints=[], ready="True",
            ready_since=None, boot_id="boot-1", gpus="1", state=None, nvsentinel_conditions={})


def node(t, **kw):
    return {**NODE, "t": T0 + t, **kw}


def cond(status):
    return {"SysLogsXIDError": {"status": status, "since": None, "message": "ErrorCode:79"}}


LOG = [
    node(-60),
    {"kind": "pod", "event": "MODIFIED", "t": T0 - 30, "name": "goodput-a", "phase": "Running"},
    node(9.0, nvsentinel_conditions=cond("True")),
    node(9.4, nvsentinel_conditions=cond("True"), unschedulable=True, state="quarantined"),
    {"kind": "pod", "event": "MODIFIED", "t": T0 + 9.6, "name": "goodput-a", "phase": "Running", "deleting": "x"},
    {"kind": "pod", "event": "DELETED", "t": T0 + 12.0, "name": "goodput-a", "phase": "Succeeded"},
    {"kind": "pod", "event": "ADDED", "t": T0 + 13.0, "name": "goodput-b", "phase": "Pending"},
    {"kind": "rebootnode", "event": "ADDED", "t": T0 + 14.0, "name": "reboot-x"},
    node(30, unschedulable=True, ready="Unknown", nvsentinel_conditions=cond("True")),
    node(95, unschedulable=True, ready="True", boot_id="boot-2", gpus="0", nvsentinel_conditions=cond("True")),
    node(260, unschedulable=True, ready="True", boot_id="boot-2", gpus="1", nvsentinel_conditions=cond("True")),
    node(280, unschedulable=False, ready="True", boot_id="boot-2", gpus="1", nvsentinel_conditions=cond("False")),
]


def by_name(rows):
    return {r["phase"]: r["seconds"] for r in rows}


def test_each_phase_ends_where_the_log_says():
    rows = timeline.phases(LOG, T0)
    assert by_name(rows) == {"detection": 9.0, "quarantine": 0.4, "drain": 2.6, "remediation": 2.0,
                             "reboot": 81.0, "driver": 165.0, "return": 20.0}


def test_resume_comes_from_the_goodput_analysis():
    goodput = {"outages": [{"resume_t": T0 + 284.5}]}
    rows = timeline.phases(LOG, T0, goodput)
    assert rows[-1] == {"phase": "resume", "from": timeline.iso(T0 + 280), "to": timeline.iso(T0 + 284.5),
                        "seconds": 4.5}
    assert round(sum(r["seconds"] for r in rows), 1) == 284.5


def test_a_phase_that_never_happens_stops_the_table():
    no_reboot = [l for l in LOG if l["kind"] != "rebootnode"]
    rows = timeline.phases(no_reboot, T0)
    assert rows[-1] == {"phase": "remediation", "from": timeline.iso(T0 + 12.0), "to": None, "seconds": None}


def test_the_same_boot_id_is_not_a_reboot():
    no_new_boot = [{**l, "boot_id": "boot-1"} if l["kind"] == "node" else l for l in LOG]
    rows = timeline.phases(no_new_boot, T0)
    assert rows[-1]["phase"] == "reboot" and rows[-1]["to"] is None


def test_node_fields_keep_what_the_phases_need():
    obj = {
        "metadata": {"name": "n", "labels": {timeline.STATE_LABEL: "quarantined"}},
        "spec": {"unschedulable": True, "taints": [{"key": "node.kubernetes.io/unschedulable"}]},
        "status": {
            "conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": "2026-10-21T18:00:00Z"},
                           {"type": "SysLogsXIDError", "status": "True", "message": "ErrorCode:79 ..."},
                           {"type": "MemoryPressure", "status": "False"}],
            "nodeInfo": {"bootID": "b"},
            "allocatable": {"nvidia.com/gpu": "1"},
        },
    }
    f = timeline.node_fields(obj)
    assert f["unschedulable"] and f["boot_id"] == "b" and f["gpus"] == "1" and f["state"] == "quarantined"
    assert list(f["nvsentinel_conditions"]) == ["SysLogsXIDError"]

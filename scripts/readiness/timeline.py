"""Use case 3's outage timeline: record what NVSentinel does, then cut it into phases.

  python timeline.py record <out.jsonl> --node N [--kubeconfig K]
  python timeline.py phases <recorded.jsonl> --injected ISO8601 [--goodput uc3-goodput.json]

record runs `kubectl get --watch -o json` on the GPU node, the trainer's pods
in tenant-a, the RebootNode objects and the GPU Operator's pods, and writes one
JSON line per change with the laptop's clock (`t`, UTC epoch seconds) next to
the fields that matter. It stops on Ctrl-C.

phases reads that log and prints the phases Part 1's goodput page used, from
the injection to the trainer resuming:

  detection     injection -> NVSentinel's node condition goes True
  quarantine    -> node cordoned
  drain         -> the trainer pod is gone (evicted)
  remediation   -> RebootNode created
  reboot        -> node back Ready on a new boot ID
  driver        -> nvidia.com/gpu allocatable again (the operator rebuilt the driver)
  return        -> node uncordoned
  resume        -> the next attempt starts loading its checkpoint (goodput.json)

Each boundary is the first time the log shows it after the previous one. The
injection time comes from the node's clock (inject-xid.sh), every other one
from this laptop, so the offset between the two (measured by uc3-watch.sh) is
part of the error, and the output says so.
"""

import argparse
import json
import queue
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

CONDITIONS = ("SysLogsXIDError", "GpuAllWatch")
STATE_LABEL = "dgxc.nvidia.com/nvsentinel-state"


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def epoch(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


# ---------- record ----------

def node_fields(obj):
    status = obj.get("status") or {}
    conditions = {c["type"]: c for c in status.get("conditions") or []}
    ready = conditions.get("Ready", {})
    return {
        "unschedulable": bool((obj.get("spec") or {}).get("unschedulable")),
        "taints": sorted(t["key"] for t in (obj.get("spec") or {}).get("taints") or []),
        "ready": ready.get("status"),
        "ready_since": ready.get("lastTransitionTime"),
        "boot_id": (status.get("nodeInfo") or {}).get("bootID"),
        "gpus": (status.get("allocatable") or {}).get("nvidia.com/gpu"),
        "state": (obj["metadata"].get("labels") or {}).get(STATE_LABEL),
        "nvsentinel_conditions": {
            k: {"status": c.get("status"), "since": c.get("lastTransitionTime"), "message": (c.get("message") or "")[:200]}
            for k, c in conditions.items() if k in CONDITIONS or k.startswith(("SysLogs", "Gpu"))
        },
    }


def pod_fields(obj):
    status = obj.get("status") or {}
    return {
        "name": obj["metadata"]["name"],
        "phase": status.get("phase"),
        "node": (obj.get("spec") or {}).get("nodeName"),
        "deleting": obj["metadata"].get("deletionTimestamp"),
        "created": obj["metadata"].get("creationTimestamp"),
        "conditions": {c["type"]: c.get("status") for c in status.get("conditions") or []},
        "ready": all(c.get("ready") for c in status.get("containerStatuses") or []) or None,
    }


def generic_fields(obj):
    return {
        "name": obj["metadata"]["name"],
        "created": obj["metadata"].get("creationTimestamp"),
        "status": obj.get("status"),
    }


def watch(kind, args, kubeconfig, out):
    cmd = ["kubectl", "get", *args, "--watch", "--output-watch-events", "-o", "json"]
    if kubeconfig:
        cmd += ["--kubeconfig", kubeconfig]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    decoder = json.JSONDecoder()
    buf = ""
    for chunk in iter(lambda: proc.stdout.readline(), ""):
        buf += chunk
        while buf.strip():
            try:
                event, end = decoder.raw_decode(buf.lstrip())
            except ValueError:
                break
            buf = buf.lstrip()[end:]
            out.put((time.time(), kind, event))


def record(path, node, kubeconfig):
    events = queue.Queue()
    watches = {
        "node": ["node", node],
        "pod": ["pods", "-n", "tenant-a", "-l", "app.kubernetes.io/name=goodput"],
        "operator": ["pods", "-n", "gpu-operator", "--field-selector", f"spec.nodeName={node}"],
        "rebootnode": ["rebootnodes.janitor.dgxc.nvidia.com"],
    }
    for kind, args in watches.items():
        threading.Thread(target=watch, args=(kind, args, kubeconfig, events), daemon=True).start()
    extract = {"node": node_fields, "pod": pod_fields, "operator": pod_fields, "rebootnode": generic_fields}
    last = {}
    with open(path, "a") as f:
        try:
            while True:
                t, kind, event = events.get()
                obj = event.get("object") or {}
                if not obj.get("metadata"):
                    continue
                fields = extract[kind](obj)
                key = (kind, obj["metadata"]["name"])
                if last.get(key) == fields and event.get("type") != "DELETED":
                    continue
                last[key] = fields
                line = {"t": round(t, 3), "at": iso(t), "kind": kind, "event": event.get("type"), **fields}
                f.write(json.dumps(line) + "\n")
                f.flush()
                print(f"{line['at']} {kind:10} {event.get('type'):8} {json.dumps(fields)[:160]}", flush=True)
        except KeyboardInterrupt:
            pass


# ---------- phases ----------

def first(lines, after, test):
    for line in lines:
        if line["t"] >= after and test(line):
            return line["t"]
    return None


def phases(lines, injected, goodput=None):
    nodes = [l for l in lines if l["kind"] == "node"]
    pods = [l for l in lines if l["kind"] == "pod"]
    reboots = [l for l in lines if l["kind"] == "rebootnode"]
    boot_before = next((l["boot_id"] for l in reversed(nodes) if l["t"] < injected), None)
    trainer = next((l["name"] for l in reversed(pods) if l["t"] < injected and l.get("phase") == "Running"), None)

    steps = [
        ("detection", lambda l: l["kind"] == "node" and any(
            c["status"] == "True" for k, c in l["nvsentinel_conditions"].items() if k in CONDITIONS)),
        ("quarantine", lambda l: l["kind"] == "node" and l["unschedulable"]),
        ("drain", lambda l: l["kind"] == "pod" and l["name"] == trainer and l["event"] == "DELETED"),
        ("remediation", lambda l: l["kind"] == "rebootnode" and l["event"] == "ADDED"),
        ("reboot", lambda l: l["kind"] == "node" and l["ready"] == "True" and l["boot_id"] != boot_before),
        ("driver", lambda l: l["kind"] == "node" and l["boot_id"] != boot_before and str(l["gpus"] or "0") not in ("0", "")),
        ("return", lambda l: l["kind"] == "node" and not l["unschedulable"]),
    ]
    rows = []
    start = injected
    ordered = sorted(nodes + pods + reboots, key=lambda l: l["t"])
    for name, test in steps:
        end = first(ordered, start, test)
        rows.append({"phase": name, "from": iso(start), "to": iso(end) if end else None,
                     "seconds": round(end - start, 1) if end else None})
        if end is None:
            break
        start = end
    if goodput and rows[-1]["to"]:
        resume = next((o["resume_t"] for o in goodput.get("outages") or []), None)
        if resume:
            rows.append({"phase": "resume", "from": iso(start), "to": iso(resume),
                         "seconds": round(resume - start, 1)})
    return rows


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("out")
    r.add_argument("--node", required=True)
    r.add_argument("--kubeconfig")
    ph = sub.add_parser("phases")
    ph.add_argument("log")
    ph.add_argument("--injected", required=True, help="injection time, node clock, ISO 8601")
    ph.add_argument("--goodput", help="uc3-goodput.json, for the resume time")
    a = p.parse_args(argv)

    if a.cmd == "record":
        record(a.out, a.node, a.kubeconfig)
        return 0
    lines = [json.loads(x) for x in open(a.log) if x.strip()]
    goodput = json.load(open(a.goodput)) if a.goodput else None
    rows = phases(lines, epoch(a.injected), goodput)
    total = sum(r["seconds"] or 0 for r in rows)
    print(json.dumps({"injected": a.injected, "phases": rows, "total_s": round(total, 1)}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())

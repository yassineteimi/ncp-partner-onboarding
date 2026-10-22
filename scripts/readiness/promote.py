"""The promotion gate of use case 2: may this node lose its staging taint?

  python promote.py --node N --results results.json --require domain/variant ...
                    [--diag diag.log] [--nccl-log launcher.log]

Reads NVCRE's certification results file (nvcrectl certification run
--results-file; fields from pkg/report/report.go at v0.8.0) and, when given,
the DCGM diagnostic log and the NCCL launcher log. Prints every check and
exits 0 only if all of them pass. It never touches the cluster:
scripts/readiness/nvcre.sh removes the taint on exit 0 and leaves it otherwise.

Exit codes: 0 promote, 1 refuse, 2 the inputs couldn't be read.

Every failed check says whether it points at the hardware or at the tooling,
and the last line gives the cause of a refusal, for the W2 rule: hardware
(a node failure NVCRE detected, a threshold violated, a diagnostic test
failed) cuts the later steps; tooling (the run didn't finish, a launch
failed, the diagnostic never answered) allows a recorded override; NCCL off
NVLink inside the node with a clean diagnostic, or hardware and tooling at
once, is unclear and goes to Yassine.

Refused when any of these holds:
  - result is anything but PASSED (INCOMPLETE means some target node went
    untested; RUNNING means the run isn't over)
  - the node was excluded, failed, or isn't covered by the run
  - a required category is missing or didn't succeed
  - a bandwidth row is provisional, so its threshold verdict isn't final
  - the diagnostic log has no diag_result=PASS line, or has a FAIL
  - DCGM skipped any test, although its overall verdict was PASS (unclear)
  - a GPU's current ECC mode, recorded before the diagnostic, isn't Enabled
    (unclear), or wasn't recorded at all (tooling)
  - the NCCL log shows a channel over the network (via NET/), or no NVLink
    channel at all (via P2P/ or NVLS)

The two DCGM rules came from Finland's H200s: ECC was off, DCGM skipped its
memory test, still said PASS, and this gate trusted it.
"""

import argparse
import json
import re
import sys
from pathlib import Path

GBPS = re.compile(r"([0-9.]+)\s*GB/s")
HARDWARE_REASONS = ("HardwareFailureDetected", "ThresholdViolation")
# Written by the diagnostic's script before dcgmi diag runs, one per GPU.
ECC_LINE = re.compile(r"^ecc_mode gpu=(\S+) current=(\S+)", re.M)


def bus_bandwidth(category):
    """Highest busBW across message sizes, in GB/s, or None."""
    values = [float(m.group(1)) for row in category.get("bandwidth") or []
              if (m := GBPS.search(row.get("busBW", "")))]
    return max(values) if values else None


def finding(passed, text, cause=None):
    """One check: whether it passed and, for a failure, hardware or tooling."""
    return passed, (None if passed else cause), text


def check_results(results, node, required):
    out = []
    details = [d for d in results.get("failedNodeDetails") or [] if d.get("name") == node]
    hardware = [d for d in details if d.get("reason") in HARDWARE_REASONS]

    result = results.get("result")
    out.append(finding(result == "PASSED", f"certification result is {result!r}",
                       "hardware" if hardware else "tooling"))
    excluded = results.get("excludedNodes") or []
    out.append(finding(node not in excluded, f"{node} not excluded" + (
        f" (excluded: {results.get('exclusionReason')})" if node in excluded else ""), "tooling"))
    for d in details:
        cause = "hardware" if d.get("reason") in HARDWARE_REASONS else "tooling"
        message = f": {d['message']}" if d.get("message") else ""
        out.append(finding(False, f"{node} failed, {d.get('reason')}{message}", cause))
    if node in (results.get("failedNodes") or []) and not details:
        out.append(finding(False, f"{node} is among failed nodes, with no detail", "tooling"))
    tested = {n.get("name") for n in results.get("nodeResults") or []}
    if tested:
        out.append(finding(node in tested, f"{node} is in the run's node results", "tooling"))

    categories = {f"{c.get('domain')}/{c.get('variant')}": c for c in results.get("categories") or []}
    for name in required:
        c = categories.get(name)
        if c is None:
            out.append(finding(False, f"{name} missing from the results", "tooling"))
            continue
        bw = bus_bandwidth(c)
        detail = f", max busBW {bw:.2f} GB/s" if bw is not None else ""
        reason = c.get("failureReason") or ""
        cause = "hardware" if any(r in reason for r in ("Threshold", "HardwareFailure")) else "tooling"
        out.append(finding(c.get("status") == "Succeeded",
                           f"{name} {c.get('status')}{detail}" + (f": {reason}" if reason else ""), cause))
        provisional = [r.get("size") for r in c.get("bandwidth") or [] if r.get("provisional")]
        if provisional:
            out.append(finding(False, f"{name} has provisional bandwidth rows {provisional}", "tooling"))
    return out


def skipped_tests(text):
    """(test, GPU, reason) for every result dcgmi diag -j marked Skip.

    Reads the JSON report (DCGM 4.x: test_categories, tests, results); if the
    log holds no parseable report, any "status": "Skip" still counts."""
    start = text.find("{")
    try:
        report, _ = json.JSONDecoder().raw_decode(text[start:]) if start >= 0 else (None, 0)
    except ValueError:
        report = None
    if not isinstance(report, dict) or "DCGM Diagnostic" not in report:
        n = len(re.findall(r'"status"\s*:\s*"Skip"', text))
        return [("a test", "?", "unparsed report")] * n
    skipped = []
    for category in report.get("DCGM Diagnostic", {}).get("test_categories", []):
        for test in category.get("tests", []):
            for result in test.get("results", []):
                if result.get("status") == "Skip":
                    info = " ".join(result.get("info") or []) or "no reason given"
                    skipped.append((test.get("name"), result.get("entity_id"), info))
    return skipped


def check_ecc(text):
    modes = ECC_LINE.findall(text)
    if not modes:
        return [finding(False, "no ECC mode recorded before the diagnostic", "tooling")]
    return [finding(mode == "Enabled", f"ECC {mode} on GPU {gpu}", "unclear") for gpu, mode in modes]


def check_diag(text):
    if re.search(r"^diag_result=FAIL", text, re.M):
        failing = [line.strip() for line in text.splitlines() if re.search(r'"Fail', line)][:3]
        shown = f": {' | '.join(failing)}" if failing else ""
        return [finding(False, f"dcgmi diag reported a failed test{shown}", "hardware")]
    if not re.search(r"^diag_result=PASS", text, re.M):
        last = next((line.strip() for line in reversed(text.splitlines()) if line.strip()), "empty log")
        return [finding(False, f"the diagnostic never gave a verdict: {last[:200]}", "tooling")]
    # DCGM counts a skipped test as passed. A skip means the node wasn't
    # checked, not that it's broken, so it's unclear rather than hardware.
    skipped = [finding(False, f"dcgmi diag skipped {test} on GPU {gpu}: {info[:200]}", "unclear")
               for test, gpu, info in skipped_tests(text)]
    return check_ecc(text) + (skipped or [finding(True, "dcgmi diag passed, no test skipped")])


def check_nccl(text, ran, link_fault):
    """ran: the NCCL categories succeeded, so a missing NVLink line says
    something about the path and not only that the test never started.

    Inside one node, traffic over the network or no NVLink channel is as
    likely a configuration or topology problem (P2P disabled, the VM's
    topology, no fabric manager in the guest) as a broken link, so it is
    unclear, and goes to Yassine, unless the diagnostic also failed
    (link_fault), which makes it hardware."""
    path = "hardware" if link_fault else "unclear"
    net = len(re.findall(r"via NET/", text))
    nvlink = len(re.findall(r"via P2P/|NVLS", text))
    return [finding(bool(nvlink), f"NCCL channels over NVLink: {nvlink} lines", path if ran else "tooling"),
            finding(not net, f"NCCL channels over the network: {net} lines", path)]


def verdict(findings):
    """None to promote, else the cause of the refusal."""
    causes = {cause for passed, cause, _ in findings if not passed}
    if not causes:
        return None
    return causes.pop() if len(causes) == 1 else "unclear"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--node", required=True)
    p.add_argument("--results", required=True, type=Path)
    p.add_argument("--require", nargs="+", required=True, metavar="DOMAIN/VARIANT")
    p.add_argument("--diag", type=Path)
    p.add_argument("--nccl-log", type=Path)
    a = p.parse_args(argv)

    try:
        results = json.loads(a.results.read_text())
        diag = a.diag.read_text() if a.diag else None
        nccl = a.nccl_log.read_text() if a.nccl_log else None
    except (OSError, ValueError) as e:
        print(f"ERROR [tooling] cannot read the inputs: {e}")
        print(f"REFUSE {a.node} cause=tooling")
        return 2

    findings = check_results(results, a.node, a.require)
    if diag is not None:
        findings += check_diag(diag)
    if nccl is not None:
        ran = all(c.get("status") == "Succeeded" for c in results.get("categories") or []
                  if c.get("domain") == "communication")
        link_fault = any(not passed and cause == "hardware" and text.startswith("dcgmi diag")
                         for passed, cause, text in findings)
        findings += check_nccl(nccl, ran, link_fault)
    for passed, cause, text in findings:
        print(f"PASS {text}" if passed else f"FAIL [{cause}] {text}")
    cause = verdict(findings)
    print(f"PROMOTE {a.node}" if cause is None else f"REFUSE {a.node} cause={cause}")
    return 0 if cause is None else 1


if __name__ == "__main__":
    sys.exit(main())

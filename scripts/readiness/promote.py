"""The promotion gate of use case 2: may this node lose its staging taint?

  python promote.py --node N --results results.json --require domain/variant ...
                    [--diag diag.log] [--nccl-log launcher.log]

Reads NVCRE's certification results file (nvcrectl certification run
--results-file; fields from pkg/report/report.go at v0.8.0) and, when given,
the DCGM diagnostic log and the NCCL launcher log. Prints every check and
exits 0 only if all of them pass. It never touches the cluster:
scripts/readiness/nvcre.sh removes the taint on exit 0 and leaves it otherwise.

Exit codes: 0 promote, 1 refuse, 2 the inputs couldn't be read.

Refused when any of these holds:
  - result is anything but PASSED (INCOMPLETE means some target node went
    untested; RUNNING means the run isn't over)
  - the node was excluded, failed, or isn't covered by the run
  - a required category is missing or didn't succeed
  - a bandwidth row is provisional, so its threshold verdict isn't final
  - the diagnostic log has no diag_result=PASS line, or has a FAIL
  - the NCCL log shows a channel over the network (via NET/), or no NVLink
    channel at all (via P2P/ or NVLS)
"""

import argparse
import json
import re
import sys
from pathlib import Path

GBPS = re.compile(r"([0-9.]+)\s*GB/s")


def bus_bandwidth(category):
    """Highest busBW across message sizes, in GB/s, or None."""
    values = [float(m.group(1)) for row in category.get("bandwidth") or []
              if (m := GBPS.search(row.get("busBW", "")))]
    return max(values) if values else None


def check_results(results, node, required):
    out = []
    ok = True

    def verdict(passed, text):
        nonlocal ok
        ok &= passed
        out.append(f"{'PASS' if passed else 'FAIL'} {text}")

    verdict(results.get("result") == "PASSED", f"certification result is {results.get('result')!r}")
    excluded = results.get("excludedNodes") or []
    verdict(node not in excluded,
            f"{node} not excluded" + (f" (excluded: {results.get('exclusionReason')})" if node in excluded else ""))
    failed = set(results.get("failedNodes") or []) | {
        d.get("name") for d in results.get("failedNodeDetails") or []}
    verdict(node not in failed, f"{node} not among failed nodes {sorted(failed - {None}) or '[]'}")
    tested = {n.get("name") for n in results.get("nodeResults") or []}
    if tested:
        verdict(node in tested, f"{node} is in the run's node results")

    categories = {f"{c.get('domain')}/{c.get('variant')}": c for c in results.get("categories") or []}
    for name in required:
        c = categories.get(name)
        if c is None:
            verdict(False, f"{name} missing from the results")
            continue
        bw = bus_bandwidth(c)
        detail = f", max busBW {bw:.2f} GB/s" if bw is not None else ""
        reason = f" ({c.get('failureReason')})" if c.get("failureReason") else ""
        verdict(c.get("status") == "Succeeded", f"{name} {c.get('status')}{detail}{reason}")
        provisional = [r.get("size") for r in c.get("bandwidth") or [] if r.get("provisional")]
        if provisional:
            verdict(False, f"{name} has provisional bandwidth rows {provisional}")
    return ok, out


def check_diag(text):
    if re.search(r"^diag_result=FAIL", text, re.M):
        return False, ["FAIL dcgmi diag reported a failed test"]
    if re.search(r"^diag_result=PASS", text, re.M):
        return True, ["PASS dcgmi diag passed"]
    return False, ["FAIL no diag_result line in the diagnostic log"]


def check_nccl(text):
    net = len(re.findall(r"via NET/", text))
    nvlink = len(re.findall(r"via P2P/|NVLS", text))
    lines = [f"{'PASS' if nvlink else 'FAIL'} NCCL channels over NVLink: {nvlink} lines",
             f"{'PASS' if not net else 'FAIL'} NCCL channels over the network: {net} lines"]
    return bool(nvlink) and not net, lines


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
        print(f"ERROR cannot read the inputs: {e}")
        return 2

    ok, lines = check_results(results, a.node, a.require)
    for given, check in ((diag, check_diag), (nccl, check_nccl)):
        if given is not None:
            passed, more = check(given)
            ok &= passed
            lines += more
    print("\n".join(lines))
    print(f"{'PROMOTE' if ok else 'REFUSE'} {a.node}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

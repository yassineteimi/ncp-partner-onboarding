"""The promotion gate refuses unless everything passed.

The passing report is shaped like the example in NVCRE's docs/api-reference/
validation-results.md at v0.8.0, cut down to one node and our two categories.
Each test breaks one thing and expects a refusal. The bandwidth figures are
made up for the tests; they are not measurements.
"""

import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
import promote  # noqa: E402

NODE = "eu1-fin-gpu-01"
REQUIRED = ["communication/nccl-all-reduce", "communication/nccl-loopback-nvswitch"]

PASSED = {
    "name": "eu1-fin-h200", "platform": "onprem", "gpu": "h200", "totalNodes": 1,
    "categories": [
        {"domain": "communication", "variant": "nccl-all-reduce", "status": "Succeeded",
         "runtime": "4m 2s", "transport": ["P2P"],
         "bandwidth": [{"size": "8 B", "algBW": "0.00 GB/s", "busBW": "0.00 GB/s", "samples": 10},
                       {"size": "16 GB", "algBW": "361.20 GB/s", "busBW": "361.20 GB/s", "samples": 10}]},
        {"domain": "communication", "variant": "nccl-loopback-nvswitch", "status": "Succeeded",
         "bandwidth": [{"size": "16 GB", "algBW": "355.00 GB/s", "busBW": "355.00 GB/s", "samples": 2}]},
    ],
    "failedNodes": [],
    "result": "PASSED",
}
DIAG_PASS = '{"tests": []}\ndcgmi_exit=0\ndiag_result=PASS\n'
NCCL_NVLINK = "NCCL INFO Channel 00/0 : 0[0] -> 1[1] via P2P/CUMEM\nNCCL INFO Channel 01/0 : 1[1] -> 0[0] via P2P/CUMEM\n"


def run(tmp_path, results, diag=DIAG_PASS, nccl=NCCL_NVLINK, node=NODE, capsys=None):
    r = tmp_path / "results.json"
    r.write_text(json.dumps(results))
    args = ["--node", node, "--results", str(r), "--require", *REQUIRED]
    if diag is not None:
        (tmp_path / "diag.log").write_text(diag)
        args += ["--diag", str(tmp_path / "diag.log")]
    if nccl is not None:
        (tmp_path / "nccl.log").write_text(nccl)
        args += ["--nccl-log", str(tmp_path / "nccl.log")]
    return promote.main(args)


def broken(change):
    results = copy.deepcopy(PASSED)
    change(results)
    return results


def test_everything_passed_promotes(tmp_path, capsys):
    assert run(tmp_path, PASSED) == 0
    out = capsys.readouterr().out
    assert "max busBW 361.20 GB/s" in out
    assert out.strip().endswith(f"PROMOTE {NODE}")


def test_incomplete_run_refuses(tmp_path):
    assert run(tmp_path, broken(lambda r: r.update(result="INCOMPLETE"))) == 1


def test_running_run_refuses(tmp_path):
    assert run(tmp_path, broken(lambda r: r.update(result="RUNNING"))) == 1


def test_failed_category_refuses(tmp_path, capsys):
    def fail(r):
        r["categories"][1].update(status="Failed", failureReason="ThresholdViolation")
    assert run(tmp_path, broken(fail)) == 1
    assert "ThresholdViolation" in capsys.readouterr().out


def test_missing_category_refuses(tmp_path):
    assert run(tmp_path, broken(lambda r: r["categories"].pop())) == 1


def test_node_excluded_refuses(tmp_path):
    assert run(tmp_path, broken(lambda r: r.update(excludedNodes=[NODE], exclusionReason="cordoned"))) == 1


def test_node_failed_refuses(tmp_path):
    def fail(r):
        r["failedNodeDetails"] = [{"name": NODE, "reason": "HardwareFailureDetected"}]
    assert run(tmp_path, broken(fail)) == 1


def test_node_absent_from_node_results_refuses(tmp_path):
    def other(r):
        r["nodeResults"] = [{"name": "some-other-node", "group": "g0", "status": "Passed"}]
    assert run(tmp_path, broken(other)) == 1


def test_provisional_bandwidth_refuses(tmp_path):
    assert run(tmp_path, broken(lambda r: r["categories"][0]["bandwidth"][1].update(provisional=True))) == 1


def test_diag_fail_refuses(tmp_path):
    assert run(tmp_path, PASSED, diag="dcgmi_exit=0\ndiag_result=FAIL\n") == 1


def test_diag_without_verdict_refuses(tmp_path):
    assert run(tmp_path, PASSED, diag="connection refused\n") == 1


def test_traffic_over_the_network_refuses(tmp_path):
    assert run(tmp_path, PASSED, nccl=NCCL_NVLINK + "NCCL INFO Channel 02/0 : 0[0] -> 1[1] via NET/Socket/0\n") == 1


def test_no_nvlink_channel_refuses(tmp_path):
    assert run(tmp_path, PASSED, nccl="NCCL INFO comm 0x1 rank 0 nranks 2\n") == 1


def test_par_subset_needs_no_nccl_log(tmp_path):
    single = broken(lambda r: r["categories"].pop())
    r = tmp_path / "results.json"
    r.write_text(json.dumps(single))
    (tmp_path / "diag.log").write_text(DIAG_PASS)
    assert promote.main(["--node", "eu1-par-gpu-01", "--results", str(r),
                         "--require", "communication/nccl-all-reduce",
                         "--diag", str(tmp_path / "diag.log")]) == 0


def test_unreadable_results_is_an_input_error(tmp_path):
    (tmp_path / "results.json").write_text("{not json")
    assert promote.main(["--node", NODE, "--results", str(tmp_path / "results.json"),
                         "--require", *REQUIRED]) == 2


def test_bus_bandwidth_takes_the_highest_row():
    assert promote.bus_bandwidth(PASSED["categories"][0]) == 361.2
    assert promote.bus_bandwidth({"bandwidth": []}) is None

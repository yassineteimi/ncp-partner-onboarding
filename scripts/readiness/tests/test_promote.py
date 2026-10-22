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
FIXTURES = Path(__file__).parent / "fixtures"
ECC_ON = "ecc_mode gpu=0 current=Enabled\necc_mode gpu=1 current=Enabled\n"
DIAG_PASS = ECC_ON + '{"tests": []}\ndcgmi_exit=0\ndiag_result=PASS\n'
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


# The cause on the last line decides what happens next in W2 (cos's run sheet):
# hardware cuts the later steps, tooling allows a recorded override, unclear
# goes to Yassine.

def last_line(capsys):
    return capsys.readouterr().out.strip().splitlines()[-1]


def test_threshold_violation_is_hardware(tmp_path, capsys):
    def slow(r):
        r.update(result="FAILED")
        r["categories"][0].update(status="Failed", failureReason="ThresholdViolation: busBandwidthGBps 41.2")
        r["failedNodeDetails"] = [{"name": NODE, "reason": "ThresholdViolation", "message": "busBW 41.2 < 64"}]
    assert run(tmp_path, broken(slow)) == 1
    out = capsys.readouterr().out
    assert f"FAIL [hardware] {NODE} failed, ThresholdViolation: busBW 41.2 < 64" in out
    assert out.strip().endswith("cause=hardware")


def test_launch_failure_is_tooling(tmp_path, capsys):
    # The image can't start on driver 580: the run fails and nothing reaches NCCL.
    def launch(r):
        r.update(result="FAILED")
        for c in r["categories"]:
            c.update(status="Failed", failureReason="WorkloadFailed: CUDA driver version is insufficient",
                     bandwidth=[])
        r["failedNodeDetails"] = [{"name": NODE, "reason": "WorkloadFailed"}]
    assert run(tmp_path, broken(launch), nccl="mpirun: exit 1\n") == 1
    out = capsys.readouterr().out
    assert "CUDA driver version is insufficient" in out
    assert "FAIL [tooling] NCCL channels over NVLink: 0 lines" in out
    assert out.strip().endswith("cause=tooling")


def test_timeout_is_tooling(tmp_path, capsys):
    assert run(tmp_path, broken(lambda r: r.update(result="RUNNING"))) == 1
    assert last_line(capsys) == f"REFUSE {NODE} cause=tooling"


def test_diag_fault_is_hardware(tmp_path, capsys):
    diag = '{"name": "memory", "status": "Fail", "info": "DBE"}\ndcgmi_exit=226\ndiag_result=FAIL\n'
    assert run(tmp_path, PASSED, diag=diag) == 1
    out = capsys.readouterr().out
    assert '"status": "Fail"' in out
    assert out.strip().endswith("cause=hardware")


def test_diag_that_never_answered_is_tooling(tmp_path, capsys):
    assert run(tmp_path, PASSED, diag="Error: unable to connect to host engine\n") == 1
    out = capsys.readouterr().out
    assert "unable to connect to host engine" in out
    assert out.strip().endswith("cause=tooling")


NET_CHANNEL = "Channel 02/0 : 0[0] -> 1[1] via NET/Socket/0\n"


def test_traffic_over_the_network_with_a_clean_diag_is_unclear(tmp_path, capsys):
    # Inside one node this is as likely P2P disabled, the VM's topology or no
    # fabric manager in the guest as a broken link: Yassine decides.
    assert run(tmp_path, PASSED, nccl=NCCL_NVLINK + NET_CHANNEL) == 1
    assert last_line(capsys) == f"REFUSE {NODE} cause=unclear"


def test_traffic_over_the_network_with_a_failed_diag_is_hardware(tmp_path, capsys):
    diag = '{"name": "nvlink", "status": "Fail"}\ndiag_result=FAIL\n'
    assert run(tmp_path, PASSED, diag=diag, nccl=NCCL_NVLINK + NET_CHANNEL) == 1
    assert last_line(capsys) == f"REFUSE {NODE} cause=hardware"


def test_no_nvlink_after_a_successful_run_is_unclear(tmp_path, capsys):
    assert run(tmp_path, PASSED, nccl="NCCL INFO comm 0x1 rank 0 nranks 2\n") == 1
    assert last_line(capsys) == f"REFUSE {NODE} cause=unclear"


def test_hardware_and_tooling_together_is_unclear(tmp_path, capsys):
    assert run(tmp_path, broken(lambda r: r.update(result="INCOMPLETE")),
               diag="dcgmi_exit=226\ndiag_result=FAIL\n") == 1
    assert last_line(capsys) == f"REFUSE {NODE} cause=unclear"


# A skipped DCGM test, and ECC off. Finland's H200 diagnostic, kept unchanged
# as a fixture: overall PASS, memory test skipped on both GPUs because ECC is
# off. The gate promoted that node; it must refuse it now.

def test_finland_diag_with_ecc_off_refuses(tmp_path, capsys):
    diag = (FIXTURES / "diag-fin-ecc-off.log").read_text()
    assert run(tmp_path, PASSED, diag=diag) == 1
    out = capsys.readouterr().out
    assert "FAIL [unclear] dcgmi diag skipped memory on GPU 0: Skipping test Memory because ECC is not enabled" in out
    assert "FAIL [unclear] dcgmi diag skipped memory on GPU 1" in out
    # That run predates the ECC line, so the gate also says it wasn't recorded.
    assert "FAIL [tooling] no ECC mode recorded before the diagnostic" in out
    assert out.strip().endswith(f"REFUSE {NODE} cause=unclear")


def test_ecc_off_alone_is_unclear(tmp_path, capsys):
    diag = "ecc_mode gpu=0 current=Disabled\necc_mode gpu=1 current=Disabled\n" + (
        FIXTURES / "diag-fin-ecc-off.log").read_text()
    assert run(tmp_path, PASSED, diag=diag) == 1
    out = capsys.readouterr().out
    assert "FAIL [unclear] ECC Disabled on GPU 0" in out
    assert out.strip().endswith(f"REFUSE {NODE} cause=unclear")


def test_skip_with_ecc_on_is_unclear(tmp_path, capsys):
    diag = ECC_ON + (FIXTURES / "diag-fin-ecc-off.log").read_text()
    assert run(tmp_path, PASSED, diag=diag) == 1
    out = capsys.readouterr().out
    assert "PASS ECC Enabled on GPU 1" in out
    assert out.strip().endswith(f"REFUSE {NODE} cause=unclear")


def test_missing_ecc_line_is_tooling(tmp_path, capsys):
    assert run(tmp_path, PASSED, diag='{"tests": []}\ndcgmi_exit=0\ndiag_result=PASS\n') == 1
    assert last_line(capsys) == f"REFUSE {NODE} cause=tooling"


def test_paris_diag_with_nothing_skipped_promotes(tmp_path, capsys):
    # Paris's L4 diagnostic, unchanged, ran software, memory and pcie with
    # nothing skipped. Its ECC line is added here: that run predates it.
    single = broken(lambda r: r["categories"].pop())
    r = tmp_path / "results.json"
    r.write_text(json.dumps(single))
    diag = tmp_path / "diag.log"
    diag.write_text("ecc_mode gpu=0 current=Enabled\n" + (FIXTURES / "diag-par-ecc-on.log").read_text())
    assert promote.main(["--node", "eu1-par-gpu-01", "--results", str(r),
                         "--require", "communication/nccl-all-reduce", "--diag", str(diag)]) == 0
    assert "PASS dcgmi diag passed, no test skipped" in capsys.readouterr().out


def test_skip_counts_without_a_parseable_report():
    text = 'garbage { "status" : "Skip" } and "status": "Skip"\ndiag_result=PASS\n'
    assert len(promote.skipped_tests(text)) == 2


def test_unreadable_inputs_say_tooling(tmp_path, capsys):
    (tmp_path / "results.json").write_text("{not json")
    assert promote.main(["--node", NODE, "--results", str(tmp_path / "results.json"),
                         "--require", *REQUIRED]) == 2
    assert last_line(capsys) == f"REFUSE {NODE} cause=tooling"

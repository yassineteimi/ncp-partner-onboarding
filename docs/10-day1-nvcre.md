# Day 1: no workloads until the node is certified

!!! abstract "The use case"
    A new GPU node joins Nordhaven's training pool with a staging taint, so nothing but
    its own tests can run on it. NVIDIA's Cluster Readiness Engine (NVCRE) certifies it, a
    DCGM diagnostic checks the hardware, and a small gate removes the taint only if both
    passed. Part 1 had burn-in scripts and a runbook; this makes the check a gate in front
    of tenants.

!!! success "Ran on the Paris L4 (21 October 2026) and the Finland 2× H200 node (22 October)"
    The H200 node was certified at 351 GB/s all-reduce bus bandwidth over NVLink and
    opened to tenants 19 min 39 s after it was Ready, image pull included. One gap showed
    up that the gate didn't catch at the time: ECC is off on the provider's H200s, so the
    DCGM diagnostic skipped its memory test and still passed. The gate now refuses that
    case. [Results](#results).

=== "In short"

    **The problem.** A new GPU server can arrive broken: a faulty GPU, a slow link between
    GPUs, a bad driver. If customers land on it first, they find the problem for you.

    **The idea.** Every new server is guilty until proven innocent. It joins the cluster
    with a "do not enter" sign (a Kubernetes *taint*, `eu1.io/staging`), tests run on it,
    and the sign comes off only if everything passes. That's the *gate*.

    ```mermaid
    flowchart LR
      join["H200 node joins<br/>taint eu1.io/staging=pending:NoSchedule"] --> cert["NVCRE certification<br/>nccl-all-reduce<br/>nccl-loopback-nvswitch"]
      join --> diag["ECC mode, then dcgmi diag -r 2<br/>as an NVCRE WorkloadRun"]
      cert --> gate["promote.py<br/>every check passed?"]
      diag --> gate
      gate -->|yes| open["taint removed<br/>tenants can schedule"]
      gate -->|no| keep["taint kept<br/>cause: hardware, tooling or unclear"]
    ```

    ## Making NVCRE work on this hardware

    NVCRE is built for NVIDIA's standard large servers. Mine are smaller and different, so I
    changed six things:

    | NVCRE assumes | My reality | What I set |
    |---|---|---|
    | An H200 server has 8 GPUs | Mine is a 2-GPU slice of one | `gpusPerNode: 2` (1 on the L4) |
    | No speed limit: "passed" only means "it ran" | I need proof of NVLink | A 64 GB/s floor |
    | `nccl-loopback` is the NVLink test | That variant switches the GPU-to-GPU path off | `nccl-loopback-nvswitch`, which keeps it on |
    | Its hardware test is DCGM level 4 | About 90 minutes, on a server billed at $11.66 an hour | My own level 2 test, a few minutes |
    | Its controller runs away from GPU nodes | The docs say so, nothing enforces it | A rule that keeps it off GPU nodes |
    | Its test pods can enter any node | My node carries the "do not enter" sign | `taintSelectors`, so only test pods get in |

    NVCRE also relies on two things underneath: Kubeflow Trainer, because it launches each
    test as a training job (a *TrainJob*), and the DCGM service the GPU Operator runs on
    every GPU node, which performs the hardware diagnostic.

    **Why a PyTorch image.** The speed test needs NCCL (NVIDIA's library for GPUs exchanging
    data), CUDA, MPI to launch it across GPUs, and NVIDIA's test program
    `all_reduce_perf_mpi`. NVIDIA's PyTorch container ships all of them, tested together.
    It's also what real training jobs use, so the test exercises the same communication
    stack customers will.

    **Driver compatibility.** The image (`pytorch:26.01`) is built for driver 590, and the
    Finland server runs driver 580. It ran anyway: CUDA 13 programs can run on an older
    13.x driver, within limits, and the image also carries its own compatibility libraries.
    The main test used those; the smaller one used the server's driver directly. I kept
    `pytorch:25.11`, built for 580, as a backup. It wasn't needed.

    ## What I test, and how

    | Test | Plain English | Tool and category |
    |---|---|---|
    | Can the GPUs exchange data fast? | Training splits work across GPUs, which combine their results after every step (*all-reduce*). A slow exchange means slow training | NVCRE, `communication/nccl-all-reduce` |
    | Are they on the fast road? | **NVLink** is a private bridge, about 450 GB/s each way. **PCIe** is the shared main road, about 64 GB/s each way | NVCRE, `communication/nccl-loopback-nvswitch`; pass only above 64 GB/s, which only NVLink reaches |
    | Is the hardware healthy? | Each GPU checks its software, its memory and its PCIe link | `dcgmi diag -r 2` (DCGM level 2), run as an NVCRE *WorkloadRun* |
    | Is memory protection on? | **ECC** catches and fixes memory errors. With it off, the memory test can't run | DCGM field 300 (current ECC mode), read just before the diagnostic |

    **Why the diagnostic runs as a WorkloadRun.** A small pod lands on the staged node and
    asks the node's DCGM service to run the diagnostic. DCGM does the work; the pod is only
    the messenger, so it needs no special privileges, and it reserves both GPUs so nothing
    else runs on them meanwhile. I use a WorkloadRun because NVCRE's built-in DCGM test is
    fixed at level 4, about 90 minutes, and a WorkloadRun is NVCRE's way to run my own test
    instead. The whole certification stays in NVCRE, with the same entry pass and the same
    records, rather than me logging into the server.

    **NVCRE and the gate.** NVCRE runs the tests and reports; it never touches the node. My
    small script, `promote.py`, reads every result and removes the sign only if everything
    passed. When it refuses, it says why:

    - **Hardware:** the node stays out.
    - **Tooling:** the test itself broke; a person may override, and the override is recorded.
    - **Unclear:** a person decides. ECC off falls here.

    ## What happened on the H200

    - The GPUs exchanged data at **351 GB/s**: NVLink proven.
    - The diagnostic passed but **skipped its memory test**, because ECC was off at the provider.
    - The gate let the node in anyway. That was a gap; it now refuses a skipped test and checks ECC first.
    - **19 min 39 s** from server ready to open for customers. Part 1's burn-in took 3 hours and ended with a person running a checklist.

    **Why I didn't turn ECC on.** ECC only switches on after a GPU reset or a reboot, and on a
    rented virtual server the GPUs might not come back. It's also the provider's setting:
    the fix belongs in the handover spec ("deliver with ECC on"), and my gate's job is to
    catch it, not to patch the node quietly. So the gate refuses the node as "unclear" and
    I ask the provider.

    ## In one sentence

    No node takes customer work until it proves its GPUs talk at NVLink speed and pass
    NVIDIA's diagnostic, enforced by an automatic gate that says why it refuses. I adapted
    NVCRE to a 2-GPU server, and the H200 run exposed a blind spot that I then closed.

=== "Run evidence"

    ## The gate

    The diagram is in the first tab, "In short".

    The taint goes on at join, through the node's kubeadm `JoinConfiguration`, so there's no
    moment when the node is schedulable before it's checked. The GPU Operator's operands and
    NFD tolerate it, since the node is useless until they run. NVCRE injects the same
    toleration into its own workload pods through `taintSelectors`, and its run only targets
    nodes that still carry the taint. NVCRE itself never taints, cordons or labels a node
    (its README says so), so promotion is mine: `promote.py` reads NVCRE's results file, the
    diagnostic log and the raw NCCL log, and says yes only when everything passed.

    When it says no, it also says why, because what happens next depends on it. A hardware
    failure means no tenant goes on that node. A tooling failure (the run didn't finish, an
    image couldn't start) allows a manual override, recorded and labelled
    `eu1.io/certification=overridden`. Anything in between, for example NCCL leaving NVLink
    inside one node while the diagnostic is clean, or a diagnostic test that was skipped,
    goes to a person to decide.

    ## What NVCRE needed on this hardware

    Read in the source and docs at v0.8.0, and checked by rendering the runs offline with
    `nvcrectl`:

    | NVCRE default | On Nordhaven's nodes | Set to |
    |---|---|---|
    | An H200 node has 8 GPUs | The Finland instance, `2H200.141S.88V`, is a two-GPU slice of an HGX board; the run finds no node able to supply 8 and fails | `gpusPerNode: 2` |
    | The L4 isn't in the catalog | It falls back to 4 GPUs per node, with a warning | `gpusPerNode: 1` |
    | No thresholds | PASSED only means the test ran | A bus bandwidth floor in Finland (below) |
    | Only DCGM category: level 4 | Hardcoded `--run 4`, about 90 minutes on healthy hardware | `dcgmi diag -r 2` beside the certification |
    | Controller "needs a node without GPUs" | The docs say so, the chart doesn't enforce it | A required node affinity on `nvidia.com/gpu.present DoesNotExist` |
    | `nccl-loopback` | Disables P2P and shared memory, so it tests the network path, not NVLink | `nccl-loopback-nvswitch`, the variant that keeps P2P on |

    ## The threshold, and where it comes from

    No published figure gives the all-reduce bus bandwidth of two H200s in one node, and I
    won't invent one. What I can say from NVIDIA's H200 page is that PCIe Gen5 carries 128
    GB/s in total, 64 GB/s each way, and NVLink 900 GB/s, about 450 each way. So the floor
    is 64 GB/s: above it, the traffic can only have crossed NVLink. It proves the path, not
    the performance, and I report the measured figure against 450.

    The NCCL log is kept raw, with `NCCL_DEBUG=INFO`, so the transport each channel used is
    on record too.

    ## The image and the driver

    NVCRE runs its NCCL tests in `nvcr.io/nvidia/pytorch:26.01-py3`, built for driver
    590.48.01 (CUDA 13.1.1). The Finland provider's image ships driver 580.178.04. I kept
    `pytorch:25.11-py3`, built for 580, as a fallback, after checking its layers for the two
    binaries the test calls: `/usr/local/bin/all_reduce_perf_mpi`, and `mpirun` through
    `/usr/local/mpi`, a link to HPC-X. It wasn't needed ([below](#what-the-certification-measured)).
    Both images are pinned by digest.

    ## Results

    ### The H200 node, from Ready to open

    On 22 October the Finland GPU node joined already carrying
    `eu1.io/staging=pending:NoSchedule`. Times are UTC.

    | Time | What happened |
    |---|---|
    | 09:54:10 | Node Ready, tainted; the GPU Operator and NFD start on it |
    | 09:55:44 | 2 GPUs allocatable |
    | 09:56:33 to 10:02:07 | NVCRE's image (9.1 GB) pulled ahead of the run, 3 min 7 s once its turn came |
    | 10:02:42 | A separate acceptance test passed (cuda-vectoradd, `nvidia-smi`), on the same taint toleration |
    | 10:03:07 to 10:12:08 | NVCRE certification, both categories, one after the other |
    | 10:12:41 to 10:12:54 | `dcgmi diag -r 2` on both GPUs, as an NVCRE `WorkloadRun` |
    | 10:13:49 | The gate passed all 7 checks and removed the taint |

    19 minutes 39 seconds from Ready to open, more than a quarter of it pulling images.
    Part 1's burn-in took three hours on one L4 and ended with a person running a checklist.

    ### What the certification measured

    ```{ .sh .terminal }
    $ make nvcre-certify SITE=fin
    ...
    │  communication/nccl-all-reduce                                 │
    ├────────────────────────────────────────────────────────────────┤
    │  Status:    Succeeded                                          │
    │  Runtime:   4m 31s                                             │
    ...
    │  Transport: Socket                                             │
    │  Bandwidth:                                                    │
    │    Size       AlgBW        BusBW        Samples                │
    │    16 GB      351.45 GB/s  351.45 GB/s  10                     │
    ...
    │  communication/nccl-loopback-nvswitch                          │
    ...
    │    16 GB      351.87 GB/s  351.87 GB/s  10                     │
    ...
    │  Categories:   2/2 passed                                      │
    │  Failed Nodes: none                                            │
    │  Result:       PASSED                                          │
    ```

    Full output: [nvcre-fin-20261022T100307Z-report.txt](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/nvcre-fin-20261022T100307Z-report.txt).

    | Category | Runtime | Bus bandwidth (16 GB messages) | Against the 64 GB/s floor | Against NVLink's ~450 GB/s each way |
    |---|---|---|---|---|
    | `communication/nccl-all-reduce` | 4 min 31 s | 351.45 GB/s | 5.5× | 78% |
    | `communication/nccl-loopback-nvswitch` | 4 min 27 s | 351.87 GB/s | 5.5× | 78% |

    The summary's `Transport: Socket` is wrong for this run. "Socket" is the name of NCCL's
    network plugin for traffic between nodes, which a run inside one node never uses
    ([finding](findings.md#nvsentinel-nvcre-and-aicr)). The raw NCCL log says how the bytes
    really travelled: NCCL 2.29.2 built a graph of type `NVL/PIX`, and each run connected 48
    channel paths over P2P, `via P2P/CUMEM` in the two-process all-reduce and
    `via P2P/direct pointer` in the single-process loopback, with none over the network. The
    gate reads those lines, not the summary.

    ```{ .sh .terminal }
    $ grep -E "type NVL/PIX|via P2P" nvcre-fin-20261022T100307Z-nccl.log
    ...
    2026-10-22T10:03:44.627546120Z eu1-fin-h200-communicatio-c154b-job-workload-node-0-0:584:584 [1] NCCL INFO Channel 00/0 : 1[1] -> 0[0] via P2P/CUMEM
    2026-10-22T10:03:44.627668953Z eu1-fin-h200-communicatio-c154b-job-workload-node-0-0:583:583 [0] NCCL INFO Channel 00/0 : 0[0] -> 1[1] via P2P/CUMEM
    ...
    2026-10-22T10:07:42.577449869Z eu1-fin-h200-communicatio-a82b3-job-workload-node-0-0:1:75 [0] NCCL INFO Pattern 1, crossNic 0, nChannels 12, bw 60.000000/60.000000, type NVL/PIX, sameChannels 0
    ...
    2026-10-22T10:07:42.817807006Z eu1-fin-h200-communicatio-a82b3-job-workload-node-0-0:1:83 [0] NCCL INFO Channel 00/0 : 0[0] -> 1[1] via P2P/direct pointer
    2026-10-22T10:07:42.818307424Z eu1-fin-h200-communicatio-a82b3-job-workload-node-0-0:1:82 [1] NCCL INFO Channel 00/0 : 1[1] -> 0[0] via P2P/direct pointer
    ```

    Full output: [nvcre-fin-20261022T100307Z-nccl.log](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/nvcre-fin-20261022T100307Z-nccl.log).

    The diagnostic's own PCIe test, on the same GPUs, measured 53 to 57 GB/s each way, so the
    floor sat where it should: just above what PCIe delivers, far below what NVLink did.

    The image question resolved itself, though not the same way for both runs. The MPI
    all-reduce reported `cudaDriverVersion 13010`: it ran through the image's CUDA forward
    compatibility libraries. The single-process loopback reported `13000`, the host driver's
    own CUDA 13.0, and ran through CUDA's minor version compatibility. Either way the 25.11
    fallback stayed unused.

    ### The diagnostic, and the gap in it

    `dcgmi diag -r 2` passed overall in 13 seconds: the software and PCIe tests passed on
    both GPUs, and the memory test was skipped on both:

    ```{ .sh .terminal }
    $ dcgmi diag --host nvidia-dcgm.gpu-operator.svc:5555 -r 2 -j
    ...
    						"name" : "memory",
    						"results" : 
    						[
    							{
    								"entity_group" : "GPU",
    								"entity_group_id" : 1,
    								"entity_id" : 0,
    								"info" : 
    								[
    									"Skipping test Memory because ECC is not enabled on GPU 0 Enable ECC memory by running \"nvidia-smi -i <gpuId> -e 1\" to enable. This may require a GPU reset or reboot to take effect."
    								],
    								"status" : "Skip"
    ...
    dcgmi_exit=0
    diag_result=PASS
    ```

    Full output: [diag-fin-20261022T101241Z.log](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/diag-fin-20261022T101241Z.log).

    The provider's 2× H200 instance runs with ECC off. Turning it on takes
    `nvidia-smi -e 1` and a GPU reset, which I don't do on a node that's billing by the
    hour ([finding](findings.md#verda)). DCGM counts a skip as a pass, and so did my gate:

    ```{ .sh .terminal }
    $ make nvcre-promote SITE=fin
    taints before:
    eu1.io/staging=pending:NoSchedule
    PASS certification result is 'PASSED'
    PASS eu1-fin-gpu-01 not excluded
    PASS communication/nccl-all-reduce Succeeded, max busBW 351.45 GB/s
    PASS communication/nccl-loopback-nvswitch Succeeded, max busBW 351.87 GB/s
    PASS dcgmi diag passed
    PASS NCCL channels over NVLink: 104 lines
    PASS NCCL channels over the network: 0 lines
    PROMOTE eu1-fin-gpu-01
    node/eu1-fin-gpu-01 untainted
    taints after:
    ```

    Full output: [promote-fin-20261022T101348Z.txt](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/promote-fin-20261022T101348Z.txt).
    (The gate's "104 lines" counts matches, not channels: the 96 P2P channel paths of the
    two runs, plus 8 mentions of NVLS in the four lines saying NVLS multicast is available.)

    So the node opened with no memory check. That was the rule as I wrote it, and it was
    wrong for a partner. The gate now refuses with cause "unclear" when DCGM skips any test,
    and the diagnostic first records each GPU's current ECC mode, so a GPU with ECC off is
    refused even before a test gets skipped ([ADR 0004](adr/0004-readiness-gate.md)). Fed the
    same files from 22 October, the gate refuses the node:

    ```{ .sh .terminal }
    $ python scripts/readiness/promote.py --node eu1-fin-gpu-01 --results nvcre-fin-20261022T100307Z.json --require communication/nccl-all-reduce communication/nccl-loopback-nvswitch --diag diag-fin-20261022T101241Z.log --nccl-log nvcre-fin-20261022T100307Z-nccl.log
    PASS certification result is 'PASSED'
    PASS eu1-fin-gpu-01 not excluded
    PASS communication/nccl-all-reduce Succeeded, max busBW 351.45 GB/s
    PASS communication/nccl-loopback-nvswitch Succeeded, max busBW 351.87 GB/s
    FAIL [tooling] no ECC mode recorded before the diagnostic
    FAIL [unclear] dcgmi diag skipped memory on GPU 0: Skipping test Memory because ECC is not enabled on GPU 0 Enable ECC memory by running "nvidia-smi -i <gpuId> -e 1" to enable. This may require a GPU reset or reboot to take effect.
    FAIL [unclear] dcgmi diag skipped memory on GPU 1: Skipping test Memory because ECC is not enabled on GPU 1 Enable ECC memory by running "nvidia-smi -i <gpuId> -e 1" to enable. This may require a GPU reset or reboot to take effect.
    PASS NCCL channels over NVLink: 104 lines
    PASS NCCL channels over the network: 0 lines
    REFUSE eu1-fin-gpu-01 cause=unclear
    ```

    Full output: [promote-fin-recheck-20261022T212142Z.txt](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/promote-fin-recheck-20261022T212142Z.txt).
    The "no ECC mode recorded" line is there because the ECC read was added after this run.
    That read, `dcgmi dmon` on DCGM's current-ECC field against the same host engine, hasn't
    run on a GPU yet; if it prints nothing, the gate refuses.

    ### The L4 test of the same gate

    On 21 October the same gate ran on the Paris L4 with `gpusPerNode: 1`: staged at
    17:23:23 UTC, certified in 1 min 57 s, diagnostic passed in 11 s (software, memory and
    PCIe, with ECC on), promoted at 17:25:54. The bus bandwidth was 0, as it has to be with
    one rank, so this proved the plumbing (the taint, the injected toleration, the results
    file, the log capture, the diagnostic as a `WorkloadRun`, the gate) and nothing about
    the L4 ([report](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/nvcre-par-20261021T172328Z-report.txt),
    [gate](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/promote-par-20261021T172554Z.txt)).

    ## What level 2 didn't check

    Level 2 isn't NVCRE's level 4: no targeted power or targeted stress (20 minutes each), no
    nvbandwidth, and on the H200 no memory test either. Level 3 would add the longer stress
    tests; I haven't run it, and its memory test would only run with ECC on.

    ## What was simulated

    Nothing on this page. The node, the GPUs, the NVLink traffic and the diagnostic are all
    real; the only thing staged by hand is the taint on the Paris L4, which joins the cluster
    without one ([what is simulated](simulated.md), for the whole project).

    ## What one node can't show

    Inter-node fabric: there's one node, so no InfiniBand, RoCE or cross-node NVLink. NVSwitch
    at rack scale, which NVCRE's multi-node categories exist for. And the training categories,
    which need at least 4 GPUs (`nemotron5-8b`) or 32 (`nemotron5-56b`).

# What is simulated

Every injected fault, simulated GPU and synthetic metric in this project is listed here,
and labelled again where it appears. If something isn't on this list, it ran on real
hardware: one L4 in Paris on 21 October and a 2× H200 node in Finland on 22 October.

| What | Where it appears | Why it's simulated | Use case | Ran |
|---|---|---|---|---|
| XID 79 written into the L4's kernel log as an `NVRM:` line prefixed with the node's `[uptime]` (`scripts/readiness/inject-xid.sh`) | The Day 2 page and its evidence | A healthy GPU can't be made to fall off the bus on request. The injection point is Part 1's, plus the prefix that keeps journald from stripping `NVRM:` | 3 | 21 Oct, on the L4 ([timeline](artifacts/readiness/uc3-timeline.txt)) |
| XID 79 injected into DCGM's field cache (`dcgmi test --inject -f 230`) | The Day 2 page, the DCGM path | Exercises NVSentinel's DCGM health watch without a real fault | 3 | 21 Oct, on the L4 ([timeline](artifacts/readiness/uc3-r5-dcgm-timeline-20261021T172645Z.txt)) |
| A non-fatal XID 13 kernel log line, as a smoke test | The Day 2 page | Checks detection without triggering a reboot | 3 | 21 Oct, on the L4 ([output](artifacts/readiness/uc3-xid13-smoke-20261021T170027Z.txt)) |
| XID 95 into a fake DCGM 4.2.0 backed by NVML injection, with no GPU at all, in KIND on a laptop; the reboot there is KIND's provider, also faked | NVSentinel's stages, tested before any GPU was rented | NVSentinel's own demo method, used to check each stage without paying for a GPU | 3 | 21 Oct, laptop only |
| NCCL bus bandwidth on the single L4, which is always 0 for one rank | The Day 1 page, the L4 certification | It proves the gate's plumbing on Paris, not the GPU's bandwidth; the H200 run measured the real thing | 2 | 21 Oct, on the L4 ([report](artifacts/readiness/nvcre-par-20261021T172328Z-report.txt)) |
| Two KWOK nodes on Paris, `eu1-par-sim-gpu-01` and `-02` (label `eu1.io/simulated=true`), each with 4 simulated H200s from run-ai/fake-gpu-operator 0.2.1. No VM, no kubelet, no GPU: pods bound there show Running but run no container | KAI Scheduler on Paris: queues, gang scheduling, reclaim | Fair share and gang scheduling need more GPUs than one L4. What's real is KAI's queue, gang, reclaim and bind decisions | 4 | 21 Oct ([demo](artifacts/scheduling/sim-demo-par-20261021T112733Z.txt)) |
| A fault marker file, `/var/run/eu1-simulated-fault`, that `make slurm-test` creates in one slurmd container and removes after | The Slurm prolog health check on Paris | It triggers the prolog's failure path on demand. The drain, the held job and their recovery are real Slurm behaviour | 5 | 21 Oct ([slurm-test](artifacts/scheduling/slurm-par-20261021T121647Z.txt)) |
| A second Prometheus on Paris posing as the Finland site, with `site="fin-sim"` and `simulated="true"` on every series | Thanos on Paris, before the Finland site existed | It runs the whole Finland-to-Paris metrics path, mutual TLS included, without renting anything | 6 | 21 Oct ([hub capture](artifacts/platform/thanos-hub-20261021T114455Z.txt)) |
| Synthetic blocks backfilled into the Thanos bucket, labelled `site="sim-backfill"` and `simulated="true"` | Thanos compactor, downsampling | Downsampling needs blocks spanning days, far more than a GPU run produces | 6 | 21 Oct ([bucket](artifacts/platform/thanos-bucket-20261021T114314Z.txt)) |

The VM tenant of use case 7 isn't on this list: Paris's CPU worker exposes `/dev/kvm`
(AMD SVM, [node facts](artifacts/par/cpu-worker-facts.txt)), so KubeVirt runs it on KVM
with no software emulation.

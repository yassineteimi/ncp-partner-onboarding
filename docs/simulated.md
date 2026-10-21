# What is simulated

Every injected fault, simulated GPU or emulated VM in this project is listed here, and labelled again where it appears. If something isn't on this list, it ran on real hardware.

| What | Where it appears | Why it's simulated | Use case | Status |
|---|---|---|---|---|
| XID 79 written into the L4's kernel log as an `NVRM:` line prefixed with the node's `[uptime]` (`scripts/readiness/inject-xid.sh`) | W1, the use case 3 page, its evidence | A healthy GPU can't be made to fall off the bus on request; the injection point is Part 1's, plus the prefix that keeps journald from stripping `NVRM:` | 3 | planned |
| XID 79 injected into DCGM's field cache (`dcgmi test --inject -f 230`) | W1 step R5, or the fallback inside R2 | Exercises NVSentinel's DCGM health watch path without a real fault | 3 | planned |
| A non-fatal XID 13 kernel log line, as a smoke test | W1 step R1 | Checks detection without triggering a reboot | 3 | planned |
| XID 95 into a fake DCGM 4.2.0 backed by NVML injection, with no GPU at all, in KIND on a laptop; the reboot there is KIND's provider, also faked | The KIND rehearsal of NVSentinel's stages | NVSentinel's own demo method, used to rehearse each stage for free | 3 | ran 21 Oct (rehearsal only) |
| NCCL bus bandwidth on the single L4, which is always 0 for one rank | W1 step R4, the use case 2 page | It proves the gate's plumbing on par, not the GPU; said so wherever it appears | 2 | planned |
| Two KWOK nodes on par, `eu1-par-sim-gpu-01` and `-02` (label `eu1.io/simulated=true`), each with 4 simulated H200s from run-ai/fake-gpu-operator 0.2.1. No VM, no kubelet, no GPU: pods bound there show Running but run no container | KAI Scheduler demo on par: queues, gang scheduling, reclaim | Fair share and gang scheduling need more GPUs than one L4; what is real is KAI's queue, gang, reclaim and bind decisions | 4 | planned |
| A fault marker file, `/var/run/eu1-simulated-fault`, that `make slurm-test` creates in one slurmd container and removes after | Slurm prolog health check on par | It triggers the prolog's failure path on demand; the drain, the held job and their recovery are real Slurm behaviour | 5 | planned |
| A second Prometheus on par posing as fin, with `site="fin-sim"` and `simulated="true"` on every series | Thanos on par, before the H200 window | It runs the whole fin-to-par metrics path, mTLS included, for free before a real fin site exists | 6 | planned |
| Synthetic blocks backfilled into the Thanos bucket, labelled `site="sim-backfill"` and `simulated="true"` | Thanos compactor, downsampling check | Downsampling needs blocks that span far more time than a two-hour window produces | 6 | planned |

The VM tenant of use case 7 is not on this list: the par CPU worker exposes `/dev/kvm` (AMD SVM, [node facts](artifacts/par/cpu-worker-facts.txt)), so KubeVirt runs it on KVM, with no software emulation.

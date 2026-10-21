# Use case 4: sharing scarce GPUs between tenants

EU1 rents out GPUs that never cover demand, so it has to answer three questions for every tenant: how much is guaranteed, what can be borrowed when others are idle, and what happens to a distributed job that only partly fits. In Part 1 the answer was a ResourceQuota on a time-sliced L4, which capped each tenant and nothing more.

Here the answer is [KAI Scheduler](https://github.com/kai-scheduler/KAI-Scheduler) v0.18.6 on both sites, with MIG on fin's H200s. [ADR 0006](adr/0006-batch-scheduling.md) says why KAI and not Kueue or Volcano, and [ADR 0008](adr/0008-gpu-sharing.md) says which tenants get MIG, time slicing or whole GPUs.

!!! note "Status, Wednesday 21 October"
    Built and checked without a cluster, not run yet. The par demo runs in today's CPU worker window, and the fin steps run in W2 on Thursday. Every result below is marked **planned** until its capture is linked.

## What's built

**The same KAI on both sites.** One Application per site carries the chart and that site's queues (`gitops/apps/{par,fin}/scheduling/kai-scheduler.yaml`). Two teams, `team-a` and `team-b`, each sit under one parent queue `eu1` with half the GPUs as quota and no limit:

| Queue | par (simulated) | fin (real) | Meaning |
|---|---|---|---|
| `eu1` | 8 GPUs | 2 GPUs | the pool |
| `team-a` | quota 4 | quota 1 | guaranteed; more can be borrowed while `team-b` is idle |
| `team-b` | quota 4 | quota 1 | the same |

Only GPUs count against these quotas, with CPU and memory left unlimited; otherwise every pod would sit over quota on CPU, and KAI could always take it back. A workload joins with `schedulerName: kai-scheduler` and the label `kai.scheduler/queue`. A Job becomes a gang with one annotation, `kai.scheduler/batch-min-member`, and KAI's pod grouper creates the PodGroup from it.

**par: simulated GPUs.** Two [KWOK](https://kwok.sigs.k8s.io/) nodes, `eu1-par-sim-gpu-01` and `-02`, with four simulated H200s each from [run-ai/fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator) 0.2.1. **SIMULATED:** there is no VM behind them, and a pod bound there shows Running without starting a container. KAI's decisions are real: which pod goes where, whose pods it takes back, and which gang it refuses. The [simulated page](simulated.md) lists them.

Running the fake operator on par took two changes from its quick start. par already runs the real GPU Operator, which strips the fake operator's `nvidia.com/gpu.deploy.*` labels from any real node without an NVIDIA PCI device (`controllers/nodelabeling_controller.go` at v26.7.2), so only the fake operator's KWOK path is installed: there, its device plugin writes `nvidia.com/gpu` straight into the KWOK node's status, and the labels don't matter. And neither KWOK nor the fake operator lets you set a nodeSelector, so both are vendored (`scripts/scheduling/render-sim-gpu.sh`) and patched onto the CPU worker, with every image pinned by digest.

**fin: real GPUs and MIG.** KAI runs on fin's CPU node. The GPU Operator overlay enables the MIG manager with one layout of my own, `h200-split`: GPU0 becomes two `3g.71gb` instances, GPU1 stays whole. Nothing changes until the node is labelled `nvidia.com/mig.config=h200-split`, which cos does in W2 step 5.

## What it shows

### On par, with simulated GPUs (planned)

`make sched-sim-demo`, in three steps:

1. `team-a` asks for 8 single-GPU pods while `team-b` is idle. All 8 bind: 4 in quota, 4 borrowed.
2. `team-b` submits a gang of 4. KAI reclaims `team-a`'s 4 borrowed GPUs, never its 4 in quota, and binds `team-b`'s 4 pods together.
3. With `team-a` gone and 4 GPUs free, `team-b` asks for a gang of 6. None of the 6 binds, and the 4 free GPUs stay free. A scheduler without gangs would bind 4 and leave them waiting for 2 that never come.

The capture will have bind times from the API server, the queues' allocated GPUs at each step, and KAI's events.

### On fin, with two H200s (planned, W2)

**Step 4, the gang.** Two pods in `team-a`, one GPU each, bound together, running an all-reduce between them with NCCL (`workloads/scheduling/allreduce/`). `team-a`'s quota is 1, so the second GPU is borrowed from `team-b`. NVCRE measures all-reduce inside a single pod that sees both GPUs, in use case 2. My run measures it between two pods, the way a tenant actually receives a two-pod gang, and `NCCL_DEBUG=INFO` says which transport NCCL picked. I expect NVLink inside one pod and a network transport between pods, which would mean a two-pod gang leaves NVLink unused unless the pods are set up to share it. That expectation gets checked, not assumed. Then a gang of 3 on the node's 2 GPUs must stay Pending with no pod bound.

**Step 5, MIG.** After cos labels the node, `make sched-mig` waits for the MIG manager to report `success` (10 minute time box, never a reboot), then starts three pods through the queues: `team-a` and `team-b` on one `3g.71gb` instance each, and a whole-GPU pod for `team-a` on GPU1. Each pod prints the MIG UUID it was given and the memory CUDA sees, which on a `3g.71gb` instance should read about 71 GB, not 141.

If the NVCRE gate refuses the node for a tooling reason, cos overrides it by hand (label `eu1.io/certification=overridden`) and steps 4 and 5 still run. This page will then say they ran on an uncertified node. If it refuses for a hardware reason, both steps are cut.

## Run it

| Target | What it does | Needs |
|---|---|---|
| `make sched-check` | Free checks: renders, digests, CR schemas, workloads; `DRY_RUN=server` adds a dry run on par | nothing |
| `make sched-sim-demo` | The par demo above | par's CPU worker |
| `make sched-gang SITE=par` | The two-pod gang with gloo on the CPU worker: tests the gang and the script, not bandwidth | par's CPU worker |
| `make sched-mig-check` | fin's MIG config through mig-parted v0.15.1's own loader | par's CPU worker |
| `make sched-prepull` | W2: pulls the gang image onto the H200 node while NVCRE runs | fin |
| `make sched-gang SITE=fin` | W2 step 4 | fin, after promotion |
| `make sched-mig` | W2 step 5 | fin, cos's label |

## What one site or two GPUs can't show

- **Gangs across nodes.** fin has one GPU node, so the gang is two pods on one machine. Placement across a rack, and topology-aware scheduling, need more than one node.
- **Real containers on par's queues.** The KWOK pods bind and run nothing. The gang with real containers runs on par's CPU worker with gloo, and on fin with GPUs.
- **Fault containment between MIG instances.** No fault is injected on fin; the isolation comes from NVIDIA's MIG documentation, not a capture.
- **Fairness over time.** KAI's time-aware fairness needs its Prometheus integration, which is off. The demo shows shares at one moment, not over a week.
- **Scale.** Two tenants and at most eight simulated GPUs, not hundreds of nodes.

## Evidence

- [Free checks, 21 October](artifacts/scheduling/free-checks-20261021T065628Z.txt): renders, every image by digest, 22 custom resources against their CRDs, server-side dry run on par.
- [allreduce.py on two gloo ranks](artifacts/scheduling/allreduce-gloo-laptop-20261020T232031Z.txt), on the laptop.
- Planned: the par demo, the gloo gang and the MIG config check (Wednesday's window); W2 steps 4 and 5 (Thursday).

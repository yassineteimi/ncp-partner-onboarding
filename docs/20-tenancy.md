# Use case 4: sharing scarce GPUs between tenants

EU1 rents out GPUs that never cover demand, so it has to answer three questions for every tenant: how much is guaranteed, what can be borrowed when others are idle, and what happens to a distributed job that only partly fits. In Part 1 the answer was a ResourceQuota on a time-sliced L4, which capped each tenant and nothing more.

Here the answer is [KAI Scheduler](https://github.com/kai-scheduler/KAI-Scheduler) v0.18.6 on both sites, with MIG on fin's H200s. [ADR 0006](adr/0006-batch-scheduling.md) says why KAI and not Kueue or Volcano, and [ADR 0008](adr/0008-gpu-sharing.md) says which tenants get MIG, time slicing or whole GPUs.

!!! note "Status, Wednesday 21 October"
    The par demo, the gloo gang and the MIG config check ran on par on 21 October, and all passed. The fin steps run in W2 on Thursday and stay marked **planned** until their captures are linked.

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

One side effect showed up once they joined: Prometheus found a kubelet on each KWOK node, couldn't scrape it, and fired `TargetDown` and `KubeletInstanceUnreachable` ([capture](artifacts/scheduling/kwok-targets-par-20261021T113535Z.txt)). ws-platform now drops `eu1-par-sim-gpu-.*` from the kubelet ServiceMonitor on par, and both alerts cleared.

**fin: real GPUs and MIG.** KAI runs on fin's CPU node. The GPU Operator overlay enables the MIG manager with one layout of my own, `h200-split`: GPU0 becomes two `3g.71gb` instances, GPU1 stays whole. Nothing changes until the node is labelled `nvidia.com/mig.config=h200-split`, which cos does in W2 step 5.

## What it shows

### On par, with simulated GPUs (run 21 October)

`make sched-sim-demo` ran in three steps, all passing ([capture](artifacts/scheduling/sim-demo-par-20261021T112733Z.txt)). Times are the API server's, in UTC.

1. **Borrowing.** `team-a` asked for 8 single-GPU pods while `team-b` was idle. All 8 bound within 5 seconds, and the `team-a` queue showed 8 GPUs allocated against a quota of 4.
2. **Reclaim.** `team-b` submitted a gang of 4 at 11:27:43. At 11:27:46 KAI evicted 4 of `team-a`'s pods, and at 11:27:48 it bound all 4 of `team-b`'s pods in the same second. `team-a` kept its other 4 pods running, and both queues ended at 4 GPUs each: what was borrowed went back, and nothing in quota was touched. KAI's event text says "preempted by workload team-b/…"; the pods it picked belonged to a queue running over its quota.
3. **All or nothing.** With `team-a` gone, 4 GPUs were free, and `team-b` asked for a gang of 6. After 90 seconds none of the 6 had bound and the 4 free GPUs were still free. KAI said why on the PodGroup: "Resources were found for 4 pods while 6 are required for gang scheduling." A scheduler without gangs would have bound 4 pods to wait for 2 that never come.

### On par, a gang with real containers (run 21 October)

`make sched-gang SITE=par` runs the same two-pod Job as W2 step 4, with gloo instead of NCCL, on the CPU worker. KAI bound both pods at 11:30:06, in the same second, and the all-reduce completed ([capture](artifacts/scheduling/gang-par-20261021T113004Z.txt)). It peaked at 2.41 GB/s, a number about one VM's memory and pod network, not about GPUs. The useful number for W2 is the image pull: 1 minute 35 seconds for the 4.26 GB trainer image on par, which is why fin pre-pulls it while NVCRE runs.

### On fin, with two H200s (planned, W2)

**Step 4, the gang.** Two pods in `team-a`, one GPU each, bound together, running an all-reduce between them with NCCL (`workloads/scheduling/allreduce/`). `team-a`'s quota is 1, so the second GPU is borrowed from `team-b`. NVCRE measures all-reduce inside a single pod that sees both GPUs, in use case 2. My run measures it between two pods, the way a tenant actually receives a two-pod gang, and `NCCL_DEBUG=INFO` says which transport NCCL picked. I expect NVLink inside one pod and a network transport between pods, which would mean a two-pod gang leaves NVLink unused unless the pods are set up to share it. That expectation gets checked, not assumed. Then a gang of 3 on the node's 2 GPUs must stay Pending with no pod bound.

**Step 5, MIG.** After cos labels the node, `make sched-mig` waits for the MIG manager to report `success` (10 minute time box, never a reboot), then starts three pods through the queues: `team-a` and `team-b` on one `3g.71gb` instance each, and a whole-GPU pod for `team-a` on GPU1. Each pod prints the MIG UUID it was given and the memory CUDA sees, which on a `3g.71gb` instance should read about 71 GB, not 141.

The layout itself is already checked. `make sched-mig-check` ran fin's rendered config through mig-parted v0.15.1's own loader on par: `h200-split` and `all-disabled` are both valid, and a name that isn't in the file is refused ([capture](artifacts/scheduling/mig-config-par-20261021T113350Z.txt)). That proves the file and the profile syntax, not that an H200 offers `3g.71gb`; W2 step 1 lists the node's profiles for that.

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
- [The par demo](artifacts/scheduling/sim-demo-par-20261021T112733Z.txt): borrowing, reclaim and a gang of 6 refused, on simulated GPUs.
- [The two-pod gloo gang on par](artifacts/scheduling/gang-par-20261021T113004Z.txt), with [both ranks' logs](artifacts/scheduling/gang-par-20261021T113004Z.txt.logs).
- [fin's MIG config through mig-parted's loader](artifacts/scheduling/mig-config-par-20261021T113350Z.txt).
- [The KWOK nodes as down scrape targets](artifacts/scheduling/kwok-targets-par-20261021T113535Z.txt), before ws-platform's fix.
- Planned: W2 steps 4 and 5 on fin (Thursday).

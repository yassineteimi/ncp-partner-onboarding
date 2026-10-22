# Use case 4: sharing scarce GPUs between tenants

Nordhaven rents out GPUs that never cover demand, so it has to answer three questions for every tenant: how much is guaranteed, what can be borrowed when others are idle, and what happens to a distributed job that only partly fits. In Part 1 the answer was a ResourceQuota on a time-sliced L4, which capped each tenant and nothing more.

Here the answer is [KAI Scheduler](https://github.com/kai-scheduler/KAI-Scheduler) v0.18.6 on both sites, with MIG on the Finland H200s. [ADR 0006](adr/0006-batch-scheduling.md) says why KAI and not Kueue or Volcano, and [ADR 0008](adr/0008-gpu-sharing.md) says which tenants get MIG, time slicing or whole GPUs.

!!! note "What ran"
    On simulated GPUs at the Paris site, on 21 October: borrowing, reclaim and a refused gang, plus a two-pod gang with real containers on the CPU worker. On the Finland H200 node, after it passed certification, on 22 October: the two-pod gang with NCCL, a refused gang of 3, and MIG with two tenants on one H200. One check failed there: KAI won't place a whole-GPU pod next to MIG slices on the same node, which changed [ADR 0008](adr/0008-gpu-sharing.md).

## What's built

**The same KAI on both sites.** One Application per site carries the chart and that site's queues (`gitops/apps/{par,fin}/scheduling/kai-scheduler.yaml`). Two teams, `team-a` and `team-b`, sit under one parent queue with half the GPUs each as quota and no limit:

| Queue | Paris (simulated) | Finland (real) | Meaning |
|---|---|---|---|
| `eu1` | 8 GPUs | 2 GPUs | the pool |
| `team-a` | quota 4 | quota 1 | guaranteed; more can be borrowed while `team-b` is idle |
| `team-b` | quota 4 | quota 1 | the same |

Only GPUs count against these quotas, with CPU and memory left unlimited; otherwise every pod would sit over quota on CPU, and KAI could always take it back. A workload joins with `schedulerName: kai-scheduler` and the label `kai.scheduler/queue`. A Job becomes a gang with one annotation, `kai.scheduler/batch-min-member`, and KAI's pod grouper creates the PodGroup from it.

**Paris: simulated GPUs.** Two [KWOK](https://kwok.sigs.k8s.io/) nodes, `eu1-par-sim-gpu-01` and `-02`, carry four simulated H200s each from [run-ai/fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator) 0.2.1. **SIMULATED:** no VM sits behind them, and a pod bound there shows Running without starting a container. KAI's decisions are real: which pod goes where, whose pods it takes back, and which gang it refuses. The [simulated page](simulated.md) lists them.

Running the fake operator at the Paris site took two changes from its quick start. Paris already runs the real GPU Operator, which strips the fake operator's `nvidia.com/gpu.deploy.*` labels from any real node without an NVIDIA PCI device (`controllers/nodelabeling_controller.go` at v26.7.2), so only the fake operator's KWOK path is installed: there, its device plugin writes `nvidia.com/gpu` straight into the KWOK node's status, and the labels don't matter. And neither KWOK nor the fake operator lets you set a nodeSelector, so both are vendored (`scripts/scheduling/render-sim-gpu.sh`) and patched onto the CPU worker, with every image pinned by digest.

One side effect showed up once they joined. Prometheus found a kubelet on each KWOK node, couldn't scrape it, and fired `TargetDown` and `KubeletInstanceUnreachable` ([capture](artifacts/scheduling/kwok-targets-par-20261021T113535Z.txt)). The Paris kubelet ServiceMonitor now drops `eu1-par-sim-gpu-.*`, and both alerts cleared.

**Finland: real GPUs and MIG.** KAI runs on the Finland CPU node. The GPU Operator overlay enables the MIG manager with a layout of my own, `h200-split`: GPU0 becomes two `3g.71gb` instances, and GPU1 stays whole. Nothing changes until the node carries the label `nvidia.com/mig.config=h200-split`. A second layout, `rtxpro-split`, does the same on 2x RTX PRO 6000 (two `2g.48gb` instances), for the case where the provider has no H200 free. The H200 run didn't need it.

## What it shows

### Paris, simulated GPUs: borrowing, reclaim, all or nothing (21 October)

`make sched-sim-demo` runs three steps, and all passed. Times are UTC.

```{ .sh .terminal }
$ make sched-sim-demo
...
## 1. team-a bursts to 8 GPUs while team-b is idle   [11:27:36Z]
after 5s: 8 team-a pods bound
...
PASS: team-a pods bound, 4 of them over quota (8)
...
## 2. team-b submits a gang of 4; KAI reclaims team-a's borrowed GPUs   [11:27:43Z]
after 5s: team-b's 4 gang pods bound
...
PASS: team-b gang pods bound (4)
PASS: team-a pods still Running (its quota) (4)
...
## 3. team-a done; team-b asks for a gang of 6 with 4 GPUs free   [11:28:02Z]
...
PASS: gang of 6: pods bound (0)
PASS: gang of 6: pods Pending (6)
...
all checks passed
```

[Full capture](artifacts/scheduling/sim-demo-par-20261021T112733Z.txt)

1. **Borrowing.** `team-a` asked for 8 single-GPU pods while `team-b` was idle. All 8 bound within 5 seconds, and the `team-a` queue showed 8 GPUs allocated against a quota of 4.
2. **Reclaim.** `team-b` submitted a gang of 4 at 11:27:43. At 11:27:46 KAI evicted 4 of `team-a`'s pods, and at 11:27:48 it bound all 4 of `team-b`'s pods in the same second. `team-a` kept its other 4 pods, and both queues ended at 4 GPUs each: what was borrowed went back, and nothing in quota was touched. KAI's event says "preempted by workload team-b/…"; the pods it picked belonged to a queue running over its quota.
3. **All or nothing.** With `team-a` gone, 4 GPUs were free, and `team-b` asked for a gang of 6. After 90 seconds none of the 6 had bound, and the 4 free GPUs were still free. KAI's reason on the PodGroup: "Resources were found for 4 pods while 6 are required for gang scheduling." A scheduler without gangs would have bound 4 pods to wait for 2 that never come.

### Paris, a gang with real containers (21 October)

`make sched-gang SITE=par` runs the same two-pod Job as on the H200s, with gloo instead of NCCL, on the CPU worker. KAI bound both pods at 11:30:06, in the same second, and the all-reduce completed ([capture](artifacts/scheduling/gang-par-20261021T113004Z.txt)). Its 2.41 GB/s peak says something about one VM's memory and pod network, not about GPUs. The number that mattered later is the image pull: 1 minute 35 seconds for the 4.26 GB trainer image, which is why the Finland node pulls it in advance, as soon as it joins.

### Finland, two H200s: the gang (22 October)

The H200 node joined at 09:54 UTC, passed certification, and was opened to tenants at 10:13:49. The trainer image was already on it: the pull took 2 minutes 22 seconds, right after the node joined and before certification started.

```{ .sh .terminal }
$ make sched-gang SITE=fin
...
after 5s: both gang pods bound
...
allreduce-gang-0-62gpk  eu1-fin-gpu-01  scheduled 2026-10-22T10:14:27Z  started 2026-10-22T10:14:27Z
allreduce-gang-1-gc7lh  eu1-fin-gpu-01  scheduled 2026-10-22T10:14:27Z  started 2026-10-22T10:14:27Z
...
rank 0/2 host allreduce-gang-0 backend nccl device NVIDIA H200 torch 2.11.0+cu128 nccl 2.28.9 CUDA_VISIBLE_DEVICES=None
...
   536870912 B    240174.1 us  algbw     2.24 GB/s  busbw     2.24 GB/s
  1073741824 B    479571.9 us  algbw     2.24 GB/s  busbw     2.24 GB/s
## NCCL transport   [10:15:03Z]
   1 allreduce-gang-1:1:1 [0] NCCL INFO Using network Socket
...
   1 allreduce-gang-1:1:1 [0] NCCL INFO comm 0xc0a7c00 rank 1 nRanks 2 nNodes 2 localRanks 1 localRank 0 MNNVL 0
...
   1 allreduce-gang-1:1:1 [0] NCCL INFO Channel 00/0 : 1[0] -> 0[0] [send] via NET/Socket/0
...
## Gang of 3 on 2 GPUs: none may bind   [10:15:03Z]
...
allreduce-gang-3-0-8rgk9   0/1     Pending   0          60s   <none>   <none>   <none>           <none>
allreduce-gang-3-1-5tjck   0/1     Pending   0          60s   <none>   <none>   <none>           <none>
allreduce-gang-3-2-g66mj   0/1     Pending   0          60s   <none>   <none>   <none>           <none>
```

[Full capture](artifacts/scheduling/gang-fin-20261022T101423Z.txt), [NCCL logs of both ranks](artifacts/scheduling/gang-fin-20261022T101423Z.txt.logs)

Two pods in `team-a`, one GPU each, run an all-reduce between them with NCCL (`workloads/scheduling/allreduce/`). KAI scheduled both at 10:14:27, one second after the Job was created. `team-a`'s quota is 1, so its second GPU was borrowed from idle `team-b`.

The all-reduce between the two pods peaked at **2.24 GB/s** of bus bandwidth. Certification measured **351 GB/s** on the same two GPUs, inside one pod that sees both, about 157 times more, with every channel over NVLink:

```{ .sh .terminal }
$ grep -m2 "via P2P" docs/artifacts/readiness/nvcre-fin-20261022T100307Z-nccl.log
2026-10-22T10:07:42.817807006Z eu1-fin-h200-communicatio-a82b3-job-workload-node-0-0:1:83 [0] NCCL INFO Channel 00/0 : 0[0] -> 1[1] via P2P/direct pointer
2026-10-22T10:07:42.818307424Z eu1-fin-h200-communicatio-a82b3-job-workload-node-0-0:1:82 [1] NCCL INFO Channel 00/0 : 1[1] -> 0[0] via P2P/direct pointer
```

[NVCRE's report](artifacts/readiness/nvcre-fin-20261022T100307Z-report.txt), [its NCCL log](artifacts/readiness/nvcre-fin-20261022T100307Z-nccl.log), [use case 2](10-day1-nvcre.md)

`NCCL_DEBUG=INFO` says why. Each pod reports `nNodes 2 localRanks 1`, then `Using network Socket`, and every channel runs `via NET/Socket/0` over `eth0`, the pod network. NCCL treats two pods on one machine as two machines, and NVLink sits unused between them. I expected that, and now it's measured. A tenant whose two-pod gang lands on one node gets a fraction of the interconnect they pay for. The safe fix on a shared platform is to run such a job as one pod holding both GPUs. Opening NVLink between separate pods means giving them more of the host than a multi-tenant platform should hand out by default, and I didn't test it.

Then a gang of 3 on the node's 2 GPUs: after 60 seconds none of the 3 pods had bound. KAI's reason on the PodGroup: "Resources were found for 2 pods while 3 are required for gang scheduling."

### Finland, two H200s: MIG (22 October)

The layout was checked first without a GPU: `make sched-mig-check` ran the rendered config through mig-parted v0.15.1's own loader on the Paris CPU worker, and `all-disabled`, `h200-split` and `rtxpro-split` are all valid ([capture](artifacts/scheduling/mig-config-par-20261022T095114Z.txt)). On the node, the label went on at 10:16:44:

```{ .sh .terminal }
$ make sched-mig
...
10:16:51Z +1s mig.config.state=pending
10:17:23Z +33s mig.config.state=success
...
after 44s: nvidia.com/mig-3g.71gb: 2 allocatable
...
timeout after 300s: team-a/whole-a running
...
### team-a/mig-a: {"nvidia.com/mig-3g.71gb":"1"}
GPU 0: NVIDIA H200 (UUID: GPU-4d345e6c-2a90-57e7-e5c7-3ffdb67e061d)
  MIG 3g.71gb     Device  0: (UUID: MIG-82b6aa84-3e05-59bd-a396-690e13953fd3)
cuda device: NVIDIA H200 MIG 3g.71gb total GiB: 69.8
### team-b/mig-b: {"nvidia.com/mig-3g.71gb":"1"}
GPU 0: NVIDIA H200 (UUID: GPU-4d345e6c-2a90-57e7-e5c7-3ffdb67e061d)
  MIG 3g.71gb     Device  0: (UUID: MIG-f8bb95eb-0760-582a-9634-f1f65e797a9f)
cuda device: NVIDIA H200 MIG 3g.71gb total GiB: 69.8
```

[Full capture](artifacts/scheduling/mig-fin-20261022T101643Z.txt)

The MIG manager went to `pending` within a second and to `success` 33 seconds later, with no reboot. 44 seconds after that, the device plugin advertised two `3g.71gb` instances and `nvidia.com/gpu: 1`. `team-a`'s and `team-b`'s pods each asked for one instance and got one. Both ran on the same physical H200, on two different MIG devices, and CUDA in each saw 69.8 GiB, not the H200's 141 GB. That's two tenants on one GPU, each with its own memory, compute and fault domain: what Part 1's time slicing on the L4 couldn't give.

**The whole-GPU pod didn't run.** `team-a`'s third pod asked for `nvidia.com/gpu: 1`, meant for GPU1, and stayed Pending for 5 minutes although the node advertised that GPU. I resubmitted it alone, with no MIG pod running and `team-a` well within quota, and KAI refused it again:

```{ .sh .terminal }
$ kubectl -n team-a get podgroups.scheduling.run.ai pg-whole-a-388d847f-caba-4ba1-99a2-7d15c518d67a -o jsonpath='{.status}'
{"resourcesStatus":{"requested":{"nvidia.com/gpu":"1"}},"schedulingConditions":[{"lastTransitionTime":"2026-10-22T10:24:38Z","message":"PodSchedulingErrors: Resources were not found for pod team-a/whole-a due to: no nodes with enough resources were found: 1 node(s) didn't have enough resources: GPUs. \n1 non MIG jobs cant run on a node with MigStrategy='mixed'..","nodePool":"default","reason":"Unschedulable","reasons":[{"message":"Resources were not found for pod team-a/whole-a due to: no nodes with enough resources were found: 1 node(s) didn't have enough resources: GPUs. \n1 non MIG jobs cant run on a node with MigStrategy='mixed'.","reason":"PodSchedulingErrors"}],"status":"True","transitionID":"1","type":"UnschedulableOnNodePool"}]}
```

[Full capture](artifacts/scheduling/mig-whole-gpu-fin-20261022T102435Z.txt)

That's a rule in KAI v0.18.6 (`pkg/scheduler/api/node_info/node_info.go`): on a MIG-enabled node labelled `nvidia.com/mig.strategy=mixed`, any task that isn't a MIG request gets a fit error. The GPU Operator's mixed strategy exists to offer whole GPUs and MIG slices side by side on one node. KAI doesn't schedule that way. So with KAI, MIG and whole GPUs split per node, not per GPU. [ADR 0008](adr/0008-gpu-sharing.md) says so, and it's in [the findings](findings.md).

## Run it

| Target | What it does | Needs |
|---|---|---|
| `make sched-check` | Checks without a GPU: renders, digests, custom resources against their CRDs, workloads; `DRY_RUN=server` adds a dry run on the Paris site | nothing |
| `make sched-sim-demo` | The simulated-GPU demo above | the Paris CPU worker |
| `make sched-gang SITE=par` | The two-pod gang with gloo on the CPU worker: tests the gang and the script, not bandwidth | the Paris CPU worker |
| `make sched-mig-check` | The Finland MIG config through mig-parted v0.15.1's own loader | the Paris CPU worker |
| `make sched-prepull` | Pulls the gang's image onto the H200 node as soon as it joins | the Finland GPU node |
| `make sched-gang SITE=fin` | The two-pod gang with NCCL on the H200s | the Finland GPU node, after certification |
| `make sched-mig` | MIG `h200-split`, then a tenant per slice; `MIG_CONFIG=rtxpro-split` for the RTX PRO 6000 layout | the Finland GPU node, labelled for the layout |

## What one site or two GPUs can't show

- **Gangs across nodes.** The Finland site has one GPU node, so the gang is two pods on one machine. Placement across a rack, and topology-aware scheduling, need more than one node.
- **Real containers on the simulated queues.** The KWOK pods bind and run nothing. The gang with real containers runs on the Paris CPU worker with gloo, and on the H200s with NCCL.
- **Fault containment between MIG instances.** No fault was injected on the H200s; the isolation comes from NVIDIA's MIG documentation, not a capture.
- **Fairness over time.** KAI's time-aware fairness needs its Prometheus integration, which is off. The demo shows shares at one moment, not over a week.
- **Scale.** Two tenants and at most eight simulated GPUs, not hundreds of nodes.

## Evidence

- [Checks without a GPU, 21 October](artifacts/scheduling/free-checks-20261021T065628Z.txt): renders, every image by digest, 22 custom resources against their CRDs, a server-side dry run at the Paris site.
- [allreduce.py on two gloo ranks](artifacts/scheduling/allreduce-gloo-laptop-20261020T232031Z.txt), on a laptop.
- [The simulated-GPU demo](artifacts/scheduling/sim-demo-par-20261021T112733Z.txt): borrowing, reclaim and a gang of 6 refused.
- [The two-pod gloo gang at the Paris site](artifacts/scheduling/gang-par-20261021T113004Z.txt), with [both ranks' logs](artifacts/scheduling/gang-par-20261021T113004Z.txt.logs).
- [The KWOK nodes as down scrape targets](artifacts/scheduling/kwok-targets-par-20261021T113535Z.txt), before the ServiceMonitor change.
- MIG config through mig-parted's loader: [21 October](artifacts/scheduling/mig-config-par-20261021T113350Z.txt), and [22 October](artifacts/scheduling/mig-config-par-20261022T095114Z.txt) with all three layouts.
- [The two-pod gang on the H200s](artifacts/scheduling/gang-fin-20261022T101423Z.txt), with [the NCCL logs](artifacts/scheduling/gang-fin-20261022T101423Z.txt.logs): 2.24 GB/s over `NET/Socket` between pods, and the gang of 3 refused.
- [The in-pod all-reduce from certification](artifacts/readiness/nvcre-fin-20261022T100307Z-report.txt), 351 GB/s over NVLink ([NCCL log](artifacts/readiness/nvcre-fin-20261022T100307Z-nccl.log)).
- [MIG on the H200 node](artifacts/scheduling/mig-fin-20261022T101643Z.txt): `h200-split` in 33 seconds, two tenants on two `3g.71gb` slices of one H200.
- [The whole-GPU pod KAI refused next to MIG](artifacts/scheduling/mig-whole-gpu-fin-20261022T102435Z.txt), with KAI's reason.

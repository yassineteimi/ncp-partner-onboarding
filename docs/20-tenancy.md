# Tenancy: sharing scarce GPUs with KAI and MIG

=== "In short"

    ### The problem

    GPUs never cover demand, so a partner must answer three questions for every customer
    team (*tenant*):

    1. **How much is guaranteed?** A quota no one can take away.
    2. **What can be borrowed?** Idle GPUs of another team, given back when it needs them.
    3. **What about a job that needs several GPUs at once?** A distributed training job is
       useless with half its GPUs: it should start whole or not at all (*gang scheduling*).

    Part 1 only had a fixed cap per team on a shared L4.

    ### What I used

    - **KAI Scheduler** (NVIDIA, v0.18.6), on both sites: per-team queues with a guaranteed
      quota, borrowing, take-back (*reclaim*) and gangs.
    - **MIG** (Multi-Instance GPU) on the H200: cuts one GPU into isolated slices, each with
      its own memory and compute, so two tenants can share one GPU without seeing each other.

    | Queue | Paris (simulated GPUs) | Finland (real H200s) |
    |---|---|---|
    | team-a | quota 4 | quota 1 |
    | team-b | quota 4 | quota 1 |

    ### What happened

    | Test | Where | Result |
    |---|---|---|
    | Borrowing | Paris, simulated | team-a used 8 GPUs on a quota of 4 while team-b was idle |
    | Reclaim | Paris, simulated | team-b asked for 4: KAI took back exactly team-a's 4 borrowed GPUs in 5 s, nothing in quota touched |
    | All or nothing | Paris and Finland | A gang of 6 on 4 free GPUs, and of 3 on 2 real H200s: no pod started, no GPU wasted |
    | Gang on real GPUs | Finland | 2 pods, 1 H200 each, both started in the same second |
    | MIG | Finland | One H200 cut into 2 slices in 33 s, no reboot; two tenants, one slice each, about 70 GB each |

    ### Two lessons

    - **Two pods on one server don't use NVLink by default.** Between the two gang pods,
      data moved at 2.24 GB/s over the pod network, against 351 GB/s inside one pod holding
      both GPUs. A tenant's 2-GPU job should run as one pod.
    - **KAI won't mix MIG slices and whole GPUs on one server.** A pod asking for the
      second, whole H200 was refused. So a partner splits servers: MIG servers and
      whole-GPU servers ([ADR 0008](adr/0008-gpu-sharing.md)).

    ### What was simulated

    Paris's 8 GPUs are fake (two KWOK nodes running no containers). KAI's decisions about
    them are real. Everything in Finland ran on the real H200s.

    ### In one sentence

    KAI gave each team a guaranteed share, lent idle GPUs and took them back exactly, never
    started half a job, and MIG let two tenants share one H200 safely; the run also showed
    two limits a partner has to design around.

=== "Run evidence"

    ### Setup

    - KAI v0.18.6, one Application per site with that site's queues
      (`gitops/apps/{par,fin}/scheduling/kai-scheduler.yaml`). Only GPUs count against
      quotas. A workload opts in with `schedulerName: kai-scheduler` and the label
      `kai.scheduler/queue`; one annotation, `kai.scheduler/batch-min-member`, makes a Job a gang.
    - **Paris, SIMULATED:** two KWOK nodes with four fake H200s each from
      run-ai/fake-gpu-operator 0.2.1. Only its KWOK path is installed, because the real GPU
      Operator strips the fake labels from real nodes; KWOK and the fake operator are
      vendored and pinned to the CPU worker ([what is simulated](simulated.md)).
    - **Finland:** MIG manager with my layout `h200-split` (GPU0 as two `3g.71gb`, GPU1
      whole), applied when the node gets `nvidia.com/mig.config=h200-split`. A fallback
      `rtxpro-split` exists for 2x RTX PRO 6000; unused. Layouts checked first with
      mig-parted v0.15.1's own loader ([capture](artifacts/scheduling/mig-config-par-20261022T095114Z.txt)).

    ### Paris, simulated GPUs, 21 October

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

    [Full capture](artifacts/scheduling/sim-demo-par-20261021T112733Z.txt). Reclaim: KAI
    evicted 4 team-a pods at 11:27:46 and bound team-b's 4 at 11:27:48. The gang of 6:
    "Resources were found for 4 pods while 6 are required for gang scheduling."

    A two-pod gang with real containers (gloo, on the CPU worker) bound both pods in the
    same second ([capture](artifacts/scheduling/gang-par-20261021T113004Z.txt)). Its image
    pull, 1 min 35 s for 4.26 GB, is why the Finland node pre-pulls on join.

    ### Finland H200, the gang, 22 October

    ```{ .sh .terminal }
    $ make sched-gang SITE=fin
    ...
    allreduce-gang-0-62gpk  eu1-fin-gpu-01  scheduled 2026-10-22T10:14:27Z  started 2026-10-22T10:14:27Z
    allreduce-gang-1-gc7lh  eu1-fin-gpu-01  scheduled 2026-10-22T10:14:27Z  started 2026-10-22T10:14:27Z
    ...
      1073741824 B    479571.9 us  algbw     2.24 GB/s  busbw     2.24 GB/s
    ## NCCL transport   [10:15:03Z]
       1 allreduce-gang-1:1:1 [0] NCCL INFO Using network Socket
    ...
       1 allreduce-gang-1:1:1 [0] NCCL INFO comm 0xc0a7c00 rank 1 nRanks 2 nNodes 2 localRanks 1 localRank 0 MNNVL 0
    ...
    ## Gang of 3 on 2 GPUs: none may bind   [10:15:03Z]
    ...
    allreduce-gang-3-0-8rgk9   0/1     Pending   0          60s   <none>   <none>   <none>           <none>
    ```

    [Full capture](artifacts/scheduling/gang-fin-20261022T101423Z.txt), [NCCL logs](artifacts/scheduling/gang-fin-20261022T101423Z.txt.logs).

    - Both pods scheduled at 10:14:27, 1 s after the Job; team-a borrowed its second GPU from idle team-b.
    - **2.24 GB/s between the pods** vs **351 GB/s** in one pod during certification
      ([report](artifacts/readiness/nvcre-fin-20261022T100307Z-report.txt)): about 157×.
      NCCL sees `nNodes 2 localRanks 1` and sends every channel `via NET/Socket/0` over the
      pod network. Opening NVLink between separate pods needs more host access than a
      multi-tenant platform should grant by default; not tested.
    - Gang of 3 on 2 GPUs: none bound after 60 s.

    ### Finland H200, MIG, 22 October

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

    [Full capture](artifacts/scheduling/mig-fin-20261022T101643Z.txt). Two tenants on one
    physical H200, two MIG devices, 69.8 GiB each.

    ### The whole-GPU pod KAI refused

    team-a's pod asking `nvidia.com/gpu: 1` (GPU1, whole) stayed Pending, and again when
    resubmitted alone within quota:

    ```{ .sh .terminal }
    $ kubectl -n team-a get podgroups.scheduling.run.ai pg-whole-a-388d847f-caba-4ba1-99a2-7d15c518d67a -o jsonpath='{.status}'
    {"resourcesStatus":{"requested":{"nvidia.com/gpu":"1"}},"schedulingConditions":[{"lastTransitionTime":"2026-10-22T10:24:38Z","message":"PodSchedulingErrors: Resources were not found for pod team-a/whole-a due to: no nodes with enough resources were found: 1 node(s) didn't have enough resources: GPUs. \n1 non MIG jobs cant run on a node with MigStrategy='mixed'..","nodePool":"default","reason":"Unschedulable","reasons":[{"message":"Resources were not found for pod team-a/whole-a due to: no nodes with enough resources were found: 1 node(s) didn't have enough resources: GPUs. \n1 non MIG jobs cant run on a node with MigStrategy='mixed'.","reason":"PodSchedulingErrors"}],"status":"True","transitionID":"1","type":"UnschedulableOnNodePool"}]}
    ```

    [Full capture](artifacts/scheduling/mig-whole-gpu-fin-20261022T102435Z.txt). A rule in
    KAI v0.18.6 (`pkg/scheduler/api/node_info/node_info.go`): on a node with
    `nvidia.com/mig.strategy=mixed`, a non-MIG task gets a fit error, although the GPU
    Operator still advertises the whole GPU ([finding](findings.md)).

    ### Issue met

    Prometheus fired `TargetDown` and `KubeletInstanceUnreachable` for the KWOK nodes' fake
    kubelets; the Paris kubelet ServiceMonitor now drops `eu1-par-sim-gpu-.*`
    ([capture](artifacts/scheduling/kwok-targets-par-20261021T113535Z.txt)).

    ### Limits

    - One GPU node: no gangs across nodes, no topology-aware placement.
    - No fault injected between MIG slices; their isolation is from NVIDIA's documentation.
    - KAI's fairness over time needs its Prometheus integration, which is off.
    - Two tenants and 8 simulated GPUs, not hundreds of nodes.

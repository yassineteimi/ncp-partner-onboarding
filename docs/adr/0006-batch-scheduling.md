# ADR 0006: Batch scheduling for many tenants, KAI Scheduler over Kueue and Volcano

Status: proposed
Date: 2026-10-21. Owner: ws-scheduling. Use case: 4.

## Context

EU1 sells scarce GPUs to several tenants at once. Each tenant wants a guaranteed share, the right to borrow what others leave idle, and its distributed jobs started whole or not at all, since half a training job holds GPUs and does nothing. In Part 1, two tenants shared one L4 through time slicing with a plain ResourceQuota: the quota capped each tenant, but nothing lent idle GPUs, took them back, or placed a job as a unit.

The constraint that decides most of this is the GPU stack EU1 already runs: the NVIDIA GPU Operator, whose device plugin advertises `nvidia.com/gpu` and, on fin, MIG slices. Whatever schedules tenants has to work with that device plugin rather than replace it.

## Options considered

| Option | What it is | For EU1 | Against, for EU1 |
|---|---|---|---|
| A. KAI Scheduler v0.18.6 | A second scheduler (from Run:ai, now a CNCF Sandbox project) for pods that set `schedulerName: kai-scheduler`, with hierarchical queues and its own pod grouper | Quota, over-quota borrowing by weight, and reclaim of borrowed GPUs are queue fields (`scheduling.run.ai/v2` Queue). The pod grouper turns a Job, JobSet or PyTorchJob into a gang without a hand-written PodGroup (`kai.scheduler/batch-min-member`). It reads MIG resources by name (`pkg/scheduler/api/common_info/resources/mig.go`) and can share a GPU in fractions. NVIDIA's AICR v1.1.0 ships it in its base recipe | Two schedulers in one cluster. Its webhooks fail closed, though only for KAI's own pods and Queues (`matchConditions` in `pkg/operator/operands/admission/resources.go`). The operator builds its images from a tag, so they can't be pinned by digest. Tags v0.20.0 and v0.20.1 were published, then retracted |
| B. Kueue v0.20.2 | A quota and admission layer from Kubernetes SIG Scheduling in front of the default kube-scheduler: ClusterQueues, cohorts, borrowing, fair sharing, preemption | kube-scheduler stays the only scheduler. It has the widest set of integrations, MultiKueue for several clusters, and topology-aware scheduling | It admits quota, then kube-scheduler places pods one by one. All-or-nothing is timeout-based: pods that bound wait until `waitForPodsReady` gives up and requeues the job, holding their GPUs meanwhile. It can't share a GPU; a fraction has to come from somewhere else |
| C. Volcano v1.16.0 | A batch scheduler built on kube-batch, CNCF incubating, with its own Job, PodGroup and Queue | Gangs, queues, reclaim and network-topology placement (HyperNode) all in one scheduler. Spark, Kubeflow and LeaderWorkerSet integrate with it | Also a second scheduler. Its GPU sharing goes through its own vGPU device plugin (`docs/user-guide/how_to_use_volcano_vgpu.md`), which would sit beside or replace the GPU Operator's. NVIDIA's reference stack doesn't carry it |

## Decision

KAI Scheduler, pinned at v0.18.6.

Two reasons decided it. KAI does the three things EU1 needs in one place: queue shares with borrowing and reclaim, gangs placed as a unit by the scheduler itself (not admitted, then placed pod by pod), and MIG and fractions counted against queues. All of that runs on top of the GPU Operator's device plugin, untouched. And it is what AICR, NVIDIA's own known-good stack, installs, so EU1's choice matches what an NVIDIA architect expects to find.

On the version: v0.18 is KAI's active long-term-support line (SUPPORT.md: September 2026 to September 2027). Upstream validates v0.16 to v0.18 on Kubernetes v1.36.1. AICR v1.1.0 resolves v0.16.9, the previous LTS line, now in maintenance. v0.16.12 already exists on that line, so AICR is three patches behind. AICR is a reference only in this project (ADR 0003), and KAI isn't part of fin's base, so EU1 runs the newer line and records the difference.

What would change the answer:

- **A partner that already runs Kueue** for CPU batch, or needs MultiKueue across clusters, should keep Kueue for admission and accept timeout-based gangs, or evaluate it in front of KAI. That combination isn't tested here.
- **A partner whose tenants are mostly Spark or big data jobs**: Volcano's integrations there are older and deeper.
- **Tenants that never share a GPU and never run multi-pod jobs**: kube-scheduler and a ResourceQuota, as in Part 1, are enough. A second scheduler would only add something to operate.

## Consequences

- Tenants get shares, borrowing and reclaim from queue fields instead of a ticket to an operator. A workload joins KAI with one label and one `schedulerName`. Pods that don't ask for KAI are untouched.
- EU1 now operates a second scheduler: the operator, scheduler, binder, admission, pod grouper and queue controller, about 1.5 vCPU requested on par's CPU worker. KAI's own pods and Queue writes stop when the worker is off; other lanes' pods don't.
- ArgoCD needs a health check for KAI's Config and SchedulingShard. cos added it to `argocd-cm` from KAI's GitOps doc at v0.18.6.
- Operand images run by tag (`v0.18.6`), not by digest. That's an exception to rule 7, kept because the operator has no digest field.
- **What this PoC can't show:**
  - par's queues run on simulated GPUs: two KWOK nodes, where pods bind but no container runs (`docs/simulated.md`)
  - a gang across nodes: fin has one node with two GPUs, so its gang is two pods on one machine
  - fairness over time: KAI's time-aware fairness needs its Prometheus integration, which is off
  - behaviour at hundreds of nodes and thousands of queued pods

## Evidence

- Free checks: [renders, digests, dry run on par](../artifacts/scheduling/free-checks-20261020T232008Z.txt); KAI's chart generates no secret at render time, and every KAI pod lands on the site's pool.
- Source at v0.18.6: `SUPPORT.md`, `docs/queues/README.md`, `docs/batch/README.md`, `docs/gitops/README.md`, `pkg/scheduler/api/common_info/resources/mig.go`, `pkg/operator/operands/admission/resources.go`. AICR v1.1.0: `docs/user/component-version-matrix.md`, `recipes/overlays/base.yaml`. Kueue's README at v0.20.2 ("All-or-nothing with ready Pods"). Volcano's README and `docs/user-guide/how_to_use_volcano_vgpu.md` at v1.16.0.
- Planned, not run yet:
  - par, simulated: burst, reclaim, and a gang of 6 that binds nothing with 4 GPUs free (`make sched-sim-demo`, Wednesday's worker window)
  - fin, real H200s: the two-pod gang with NCCL between the pods, and a gang of 3 that stays Pending on 2 GPUs (W2 step 4)

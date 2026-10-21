# ADR 0008: GPU sharing per tenant class, MIG for small tenants and whole GPUs for training

Status: proposed
Date: 2026-10-21. Owner: ws-scheduling. Use case: 4.

## Context

Not every EU1 tenant needs a whole GPU. A notebook, a small fine-tune or a low-traffic inference endpoint uses a fraction of an H200's 141 GB and 132 SMs. Selling a whole GPU to each of them wastes capacity, while packing them onto one GPU means one tenant's crash, memory leak or noisy kernel can reach the others.

Part 1 packed two tenants onto one L4 with time slicing (`ts-4`, four replicas). The capture shows three pods from two tenants all reporting the same GPU UUID, with each tenant's ResourceQuota refusing a third pod. Time slicing has no isolation: tenants share the GPU's memory and its fault domain. Part 1 stated that an XID from one tenant drains everyone on the node, and its remediation controller drains the node on an XID. The XID 79 injection on that L4 is captured (19:48:35Z, with the tenants running since 19:40:55Z). The tenant pods themselves being evicted is not; it follows from the drain, but no artifact shows it.

The L4 has no MIG. fin's H200s do.

## Options considered

| Option | What it is | For EU1 | Against, for EU1 |
|---|---|---|---|
| A. Whole GPUs | One tenant per GPU, `nvidia.com/gpu: 1` | Full isolation, nothing to configure, what training jobs want anyway | Wastes most of an H200 on a small tenant; on a 2-GPU node, two small tenants exhaust it |
| B. Time slicing | The device plugin advertises N replicas of each GPU; the GPU switches between processes | Works on any GPU, the L4 included. One ConfigMap. Proven in Part 1 | No memory limit and one fault domain: one tenant can take all the memory, and a fault drains everyone. Replicas are counted, not sized, so a "quarter GPU" guarantees nothing |
| C. MPS | The device plugin runs an MPS daemon; clients share the GPU concurrently with per-client memory and thread limits | Real concurrency and a memory cap per client. Works without MIG | All clients sit behind one MPS server and share its fault domain, so a fatal error in one client affects the others. Better for one tenant's many processes than for several paying tenants |
| D. MIG | The GPU splits in hardware into instances, each with its own SMs, memory slice and L2 | Each tenant gets dedicated memory and compute, with fault containment per instance. The device plugin advertises each profile as its own resource (`nvidia.com/mig-3g.71gb`), and KAI counts it against the tenant's queue | Only on MIG-capable GPUs, so not on par's L4. The layout is fixed per node: changing it means stopping every GPU client on that GPU, which mig-manager does by pausing the operands. A GPU-wide fault (the GPU falling off the bus, XID 79) still takes every instance |
| E. KAI fractions | KAI places pods asking for `gpu-fraction` on a shared GPU and reserves the rest | Fine-grained, no hardware support needed | `NonMemoryEnforced`, KAI's default mode: a placement promise, not isolation. The same fault domain as time slicing |

## Decision

Sharing depends on the tenant class and the hardware, not one setting for the whole fleet:

- **Training tenants get whole GPUs**, as a gang through KAI (ADR 0006). On fin that's GPU1 after step 5, or both GPUs before it.
- **Small tenants on MIG-capable GPUs get MIG instances.** On fin, the `h200-split` layout makes GPU0 into two `3g.71gb` instances, one per tenant, each with about 71 GB of its own. MIG is the only option here where a tenant's memory and faults stay inside what it pays for, and isolation between paying tenants is the property EU1 sells.
- **par's L4 pool stays time-sliced only for a single tenant's own pods** (dev and CI), never between two paying tenants. Without MIG on the L4, the honest offer to a second tenant is a whole L4.

What would change the answer:

- **MIG-capable GPUs in the inference pool:** par's small tenants would move to MIG too, and time slicing would disappear from the tenant offer.
- **A tenant with many processes and one trust domain** (one team's inference fleet): MPS on its own GPUs beats MIG on utilization, because there are no fixed slice sizes.
- **Demand that changes hour by hour:** fixed MIG layouts strand capacity. Then layouts per node pool, set at node creation, or dynamic resource allocation once it's ready for MIG in this stack, are worth the work. This PoC doesn't test either.

## Consequences

- Two tenants on one H200, each with its own memory, SMs and fault containment, scheduled through the same KAI queues as whole-GPU jobs.
- MIG is a node property EU1 operates: the layout lives in the GPU Operator overlay (`gitops/values/scheduling/gpu-operator-fin.yaml`), named after what it does (Part 1 rule 6), and a node label selects it. Changing it pauses that node's GPU clients, so layout changes are maintenance, not self-service.
- `WITH_REBOOT` stays false: if a mode change fails, the node reports `failed` instead of rebooting itself mid-window.
- **What this PoC can't show:**
  - fault containment between MIG instances: no fault is injected on fin, so the isolation comes from NVIDIA's MIG documentation, not a capture
  - MIG on par: the L4 doesn't support it
  - more than one layout, or a layout change under load: W2 applies `h200-split` once
  - MPS: not deployed

## Evidence

- Part 1 (nvidia-gpu-fleet-poc): `docs/artifacts/session-d-tenancy.txt` and `session-d-tenancy-verdict.txt` (three pods, two tenants, one L4 UUID, the quota refusal), `session-d-timeline.txt` (`xid_injected=2026-09-30T19:48:35.363Z ... xid=79 simulated=true`), `docs/04-goodput-and-burn-in.md` ("Time slicing has no isolation").
- Free check of the MIG config: the GPU Operator v26.7.2 render for fin has `mig.strategy=mixed`, the `mig-parted-eu1` ConfigMap and `WITH_REBOOT=false` ([free checks](../artifacts/scheduling/free-checks-20261020T232008Z.txt)).
- Source: mig-parted v0.15.1, `pkg/mig/reconfigure/reconfigure.go` (state labels, the reboot fallback) and `cmd/nvidia-mig-parted/util/device.go` (`nvidia-smi -r` on a pending mode change); KAI v0.18.6, `pkg/scheduler/api/common_info/resources/mig.go`; H200 141GB profiles from NVIDIA's MIG user guide.
- Planned, not run yet:
  - `make sched-mig-check`: the config through mig-parted's own loader, on par's CPU worker (Wednesday)
  - W2 step 5 on fin: MIG applied, two tenants each seeing about 71 GB on their own instance, one whole-GPU pod beside them (`make sched-mig`)

# ADR 0007: HPC tenants on the same platform, Slurm through Slinky

Status: proposed
Date: 2026-10-21. Owner: ws-scheduling. Use case: 5.

## Context

One of EU1's first customers is a research group that has used Slurm for years. Its scripts call `sbatch`, `srun` and `squeue`, and its people won't rewrite them as Kubernetes Jobs to rent GPUs. EU1 doesn't want a second fleet for them either: the same nodes, the same GPU Operator, the same monitoring and the same health story as its Kubernetes tenants.

What narrows the choice is what EU1 already runs. par is upstream Kubernetes 1.36 with flannel, local-path volumes (ReadWriteOnce only), cert-manager and the GPU Operator. fin's driver is 580, the branch Verda's image ships, which Yassine decided to keep (ADR 0002).

## Options considered

| Option | What it is | For EU1 | Against, for EU1 |
|---|---|---|---|
| A. Slinky 1.2.3 | SchedMD's slurm-operator: Slurm's controller, login nodes and slurmd run as pods described by `Controller`, `LoginSet` and `NodeSet` objects | Stock Slurm 26.05 from the people who make Slurm. It runs on what par already has: flannel, local-path, cert-manager for its webhook. Kubernetes and Slurm see each other: cordoning a node drains its Slurm node, and Slurm states show up as pod conditions (`docs/concepts/nodeset-controller.md`). AICR v1.1.0 lists Slurm through Slinky as a platform, and NVSentinel has a slinky-drainer | slurmd runs in a pod, so jobs share the pod's limits and the node with Kubernetes workloads. Accounting needs a MariaDB. Its chart makes its auth keys with `lookup` and `randAscii`, which ArgoCD can't render stably (a finding; worked around with a bootstrap Job) |
| B. Soperator 4.1.14 (Nebius) | An operator that builds a Slurm cluster from one `SlurmCluster` object, with a shared root filesystem (the "jail") and health checks | Complete for GPU training: the training stack and health checks come with it, and the shared root keeps nodes identical | The jail needs a shared filesystem ("at least one shared filesystem is necessary", README at 4.1.14), and par has only ReadWriteOnce local-path. At 4.1.14 it supports Slurm 25.11.3 and CUDA 12.9, a Slurm release behind Slinky's 26.05, and one partition per cluster. The tag disagrees with itself on CPU nodes: the README allows a CPU-only cluster, `docs/limitations.md` says GPUs are required. Its main branch already moves to CUDA newer than 13.0, which fin's 580 driver can't run |
| C. A separate Slurm cluster | Slurm installed on its own VMs or bare metal, outside Kubernetes | What the research group already knows, with no container layer between Slurm and the hardware | A second fleet, provisioned, monitored and repaired another way. GPUs given to it are lost to Kubernetes tenants until someone moves them by hand |
| D. No Slurm | Ask the group to submit Kubernetes Jobs through KAI's queues | One scheduler path, nothing new to run | It asks the customer to change, which is the thing EU1 is trying to avoid |

## Decision

Slinky.

Two things decided it. It's stock Slurm 26.05 from SchedMD, running on exactly the pieces par already has. Soperator 4.1.14 needs a shared filesystem par doesn't have, and its own documents disagree on whether par's CPU-only worker can host it. Its next release also raises the CUDA floor above what fin's 580 driver runs. And Slinky's two-way link between Kubernetes and Slurm is what lets EU1 keep one operations story: cordon a node for maintenance and Slurm drains it; a Slurm drain shows up on the pod where the platform's tools already look.

What would change the answer:

- **A partner with fast shared storage and a current driver everywhere**, running large GPU training: Soperator's jail and active checks save real work at that scale, and its rising CUDA floor stops mattering.
- **An HPC group that needs bare-metal performance and never shares nodes**: a separate Slurm cluster, accepting the second fleet.
- **A group willing to move to Kubernetes Jobs**: KAI alone (ADR 0006).

## Consequences

- The research group keeps `sbatch` and `srun`, logging into a login pod. EU1 runs one more operator, a controller with a 2 GB volume, a REST API and the slurmd pods, all on par's CPU worker.
- Slurm's auth keys are created once in the cluster by a bootstrap Job, never in Git, never rotated by a sync.
- A prolog health check runs before every job: a node that fails it is drained and the job held, the Slurm side of the readiness gate in use case 2.
- No accounting yet: `sacct` and fair share over time need slurmdbd and a MariaDB, which this PoC doesn't run.
- **What this PoC can't show:**
  - two Slurm nodes on one VM (`oversubscribeNode`, which Slinky marks as not for production), standing in for two machines
  - GPUs in Slurm: par's Slurm is CPU-only, and Slurm on fin's H200s is W2 step 7, only if time remains
  - shared storage: with no ReadWriteMany volume, a job's output stays on the node that ran it
  - performance next to a bare-metal Slurm

## Evidence

- Free checks: [renders, digests, CR schemas, dry run on par](../artifacts/scheduling/free-checks-20261021T065628Z.txt). Every Slinky pod lands on the CPU pool, the chart renders no generated Secret, and the webhook CA comes from cert-manager.
- Source at the pinned versions: Slinky slurm-operator 1.2.3 `README.md` (compatibility matrix) and `docs/concepts/nodeset-controller.md`; `api/v1beta1/well_known.go` (the pod-cordon annotation); slurm chart 1.2.3 `templates/secrets/slurmkey.yaml`. Soperator at 4.1.14 (tagged 20 October): `README.md` ("Shared root filesystem", "Limitations", installation step 1) and `docs/limitations.md` ("GPUs are required", "Single-partition clusters"). Soperator's README on main, read 21 October, for the next requirements (CUDA newer than 13.0, Slurm `26.05.4-nebius-1`, Kubernetes 1.35 or newer); not released at the time of writing. AICR v1.1.0 README and `docs/user/component-catalog.md` (slinky-drainer).
- Planned, not run yet: `make slurm-test` in Wednesday's CPU worker window. It runs `srun -N2` and `sbatch` from the login pod, has the prolog drain a node on a simulated fault and recover it, then drains the other node from Kubernetes through the NodeSet pod-cordon annotation.

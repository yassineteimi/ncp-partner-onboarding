# ADR 0007: HPC tenants on the same platform, Slurm through Slinky

Status: accepted
Scope: Slurm for HPC tenants, on the Paris CPU pool (use case 5); GPUs in Slurm designed, not built.

## Context

One of Nordhaven's first customers is a research group that has used Slurm for years. Its scripts call `sbatch`, `srun` and `squeue`, and its people won't rewrite them as Kubernetes Jobs to rent GPUs. Nordhaven doesn't want a second fleet for them either: the same nodes, the same GPU Operator, the same monitoring and the same health story as its Kubernetes tenants.

What narrows the choice is what Nordhaven already runs. The Paris site is upstream Kubernetes 1.36 with flannel, local-path volumes (ReadWriteOnce only), cert-manager and the GPU Operator. The Finland site's driver is 580, the branch Verda's image ships, kept as it is (ADR 0002).

## Options considered

| Option | What it is | For Nordhaven | Against, for Nordhaven |
|---|---|---|---|
| A. Slinky 1.2.3 | SchedMD's slurm-operator: Slurm's controller, login nodes and slurmd run as pods described by `Controller`, `LoginSet` and `NodeSet` objects | Stock Slurm 26.05 from the people who make Slurm. It runs on what the Paris site already has: flannel, local-path, cert-manager for its webhook. Kubernetes and Slurm see each other: cordoning a node drains its Slurm node, and Slurm states show up as pod conditions (`docs/concepts/nodeset-controller.md`). AICR v1.1.0 lists Slurm through Slinky as a platform, and NVSentinel has a slinky-drainer | slurmd runs in a pod, so jobs share the pod's limits and the node with Kubernetes workloads. Accounting needs a MariaDB. Its chart makes its auth keys with `lookup` and `randAscii`, which ArgoCD can't render stably (a finding; worked around with a bootstrap Job) |
| B. Soperator 4.1.14 (Nebius) | An operator that builds a Slurm cluster from one `SlurmCluster` object, with a shared root filesystem (the "jail") and health checks | Complete for GPU training: the training stack and health checks come with it, and the shared root keeps nodes identical | The jail needs a shared filesystem ("at least one shared filesystem is necessary", README at 4.1.14), and the Paris site has only ReadWriteOnce local-path. At 4.1.14 it supports Slurm 25.11.3 and CUDA 12.9, a Slurm release behind Slinky's 26.05, and one partition per cluster. The tag disagrees with itself on CPU nodes: the README allows a CPU-only cluster, `docs/limitations.md` says GPUs are required. Its main branch already moves to CUDA newer than 13.0, which the Finland site's 580 driver runs only through minor-version compatibility or an image's forward-compatibility libraries, each with its limits |
| C. A separate Slurm cluster | Slurm installed on its own VMs or bare metal, outside Kubernetes | What the research group already knows, with no container layer between Slurm and the hardware | A second fleet, provisioned, monitored and repaired another way. GPUs given to it are lost to Kubernetes tenants until someone moves them by hand |
| D. No Slurm | Ask the group to submit Kubernetes Jobs through KAI's queues | One scheduler path, nothing new to run | It asks the customer to change, which is the thing Nordhaven is trying to avoid |

## Decision

Slinky.

Two things decided it. It's stock Slurm 26.05 from SchedMD, running on exactly the pieces the Paris site already has. Soperator 4.1.14 needs a shared filesystem Paris doesn't have, and its own documents disagree on whether the Paris CPU-only worker can host it. Its next release also raises the CUDA floor above what the Finland 580 driver runs natively. And Slinky's two-way link between Kubernetes and Slurm is what lets Nordhaven keep one operations story: cordon a node for maintenance and Slurm drains it; a Slurm drain shows up on the pod where the platform's tools already look.

What would change the answer:

- **A partner with fast shared storage and a current driver everywhere**, running large GPU training: Soperator's jail and active checks save real work at that scale, and its rising CUDA floor stops mattering.
- **An HPC group that needs bare-metal performance and never shares nodes**: a separate Slurm cluster, accepting the second fleet.
- **A group willing to move to Kubernetes Jobs**: KAI alone (ADR 0006).

## Consequences

- The research group keeps `sbatch` and `srun`, logging into a login pod. Nordhaven runs one more operator, a controller with a 2 GB volume, a REST API and the slurmd pods, all on the Paris CPU worker.
- Slurm's auth keys are created once in the cluster by a bootstrap Job, never in Git, never rotated by a sync.
- A prolog health check runs before every job: a node that fails it is drained and the job held, the Slurm side of the readiness gate in use case 2.
- No accounting: `sacct` and fair share over time need slurmdbd and a MariaDB, which this PoC doesn't run.
- GPUs in Slurm would take whole nodes out of KAI's pool, never single GPUs: slurmd's pod holds every GPU on its node through the device plugin, and both schedulers sit behind the same certification gate. The design, including GRES for the H200s and their MIG slices, a DCGM check in the prolog and the CUDA ceiling of the Finland 580 driver, is on [the use case 5 page](../21-hpc-slinky.md); it isn't built or run. The pinned slurmd image can't see MIG at all (no `gpu_nvml` plugin).
- The slurmd NodeSet uses the `OnDelete` update strategy. Under the default, `RollingUpdate`, Slinky 1.2.3 releases a drain requested through the pod-cordon annotation within the same reconcile (Slinky's upstream pull request 271, and a finding). The cost: a new slurmd image reaches a node only when its pod is deleted, so upgrades are a deliberate drain-and-delete per node.
- ArgoCD's Healthy says little about this app. Slinky's Controller has no status and the NodeSet's is empty, so ArgoCD reports them healthy as soon as they're applied, and the pods belong to the operator, not the Application. On 21 October slinky read Healthy while slurmctld sat Pending on an unbound volume. Whether Slurm works is what `make slurm-test` answers.
- **What this PoC can't show:**
  - two Slurm nodes on one VM (`oversubscribeNode`, which Slinky marks as not for production), standing in for two machines
  - GPUs in Slurm: the Paris Slurm is CPU-only, and Slurm on the Finland H200s isn't built
  - shared storage: with no ReadWriteMany volume, a job's output stays on the node that ran it
  - performance next to a bare-metal Slurm

## Evidence

- Checks without a GPU: [renders, digests, CR schemas, a dry run at the Paris site](../artifacts/scheduling/free-checks-20261021T065628Z.txt). Every Slinky pod lands on the CPU pool, the chart renders no generated Secret, and the webhook CA comes from cert-manager.
- Source at the pinned versions: Slinky slurm-operator 1.2.3 `README.md` (compatibility matrix) and `docs/concepts/nodeset-controller.md`; `api/v1beta1/well_known.go` (the pod-cordon annotation); slurm chart 1.2.3 `templates/secrets/slurmkey.yaml`. Soperator at 4.1.14 (tagged 20 October): `README.md` ("Shared root filesystem", "Limitations", the first installation step) and `docs/limitations.md` ("GPUs are required", "Single-partition clusters"). Soperator's README on main, read 21 October, for the next requirements (CUDA newer than 13.0, Slurm `26.05.4-nebius-1`, Kubernetes 1.35 or newer); not released at the time of writing. AICR v1.1.0 README and `docs/user/component-catalog.md` (slinky-drainer).
- `make slurm-test` at the Paris site, 21 October. [First run](../artifacts/scheduling/slurm-par-20261021T115447Z.txt): `srun -N2`, `sbatch` and the prolog drain passed; the pod-cordon drain didn't hold, which led to the `OnDelete` change above. [Second run](../artifacts/scheduling/slurm-par-20261021T121647Z.txt), after it: all four checks pass, and the annotation drains the Slurm node within 6 seconds, with the operator's reason in `sinfo -R` and `SlurmNodeStateDrain=True` on the pod. Cordoning a whole Kubernetes node drives the same code path, but the test doesn't do it, because the Paris CPU worker is shared with other workloads.
- [The use case 5 page](../21-hpc-slinky.md) walks through both runs and the four problems the first sync turned up.
- Slinky 1.2.3 source behind the first failure: `internal/controller/nodeset/nodeset_sync.go` (`syncCordon`, then `syncPodUncordon` from `doPodProcessing`), and Slinky's upstream pull request 271.

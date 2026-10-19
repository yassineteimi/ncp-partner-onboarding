# EU1: from hardware handover to first workloads

Part 2 of my GPU fleet work. A fictional European GPU cloud partner, EU1, takes two pools of rented hardware on two providers to its first production workloads, using NVIDIA's open stack and one Git repository. [The story](story.md) explains what EU1 needs and why there are two sites.

| # | Use case | NVIDIA piece | Site | Status |
|---|---|---|---|---|
| 1 | Day 0: known-good stack per hardware class | AICR | fin | planned |
| 2 | Day 1: prove readiness before promotion | NVCRE | fin, single-GPU subset on par | planned |
| 3 | Day 2: fault to return to service, before and after Part 1 | NVSentinel | par | planned |
| 4 | Tenancy, fair share, gang scheduling, GPU sharing | KAI Scheduler, MIG | par (simulated GPUs), fin | planned |
| 5 | HPC tenant on the same platform | Slurm through Slinky | par | planned |
| 6 | Observability across sites | Thanos | par hub, fin spoke | planned |
| 7 | VM tenant next to containers | KubeVirt | par | planned |

- [What is simulated](simulated.md): every injected fault, simulated GPU and emulated VM, in one list.
- [Decisions](adr/README.md): one record per real choice, with the alternatives.
- [Findings](findings.md): what didn't behave as documented.

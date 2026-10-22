# Decision records

One page per real choice, each with at least two genuine alternatives and the reason
this one won for Nordhaven. Written for an NVIDIA Cloud Partner architect who wants to
know why, not what.

| ADR | Decision | Scope | Status |
|---|---|---|---|
| [0001](0001-two-sites-two-providers.md) | Two sites on two providers, one repository (vs one site, vs one stretched cluster) | Both sites, bootstrap and GitOps | accepted |
| [0002](0002-driver-ownership.md) | Who owns the GPU driver: the GPU Operator or the provider image | Driver lifecycle, both sites | accepted |
| [0003](0003-known-good-stack.md) | Known-good stack: AICR recipes vs hand-pinned values (and what AICR doesn't cover: L4, kubeadm) | Day 0, both GPU pools | accepted |
| [0004](0004-readiness-gate.md) | Readiness gate: NVCRE certification and a staging taint vs Part 1's burn-in scripts | Day 1, every new GPU node | accepted |
| [0005](0005-fault-remediation.md) | Fault remediation: NVSentinel vs Part 1's controller vs node-problem-detector with a generic remediator | Day 2, GPU nodes | accepted |
| [0006](0006-batch-scheduling.md) | Batch scheduling for many tenants: KAI vs Kueue vs Volcano | Tenancy, both sites | accepted |
| [0007](0007-hpc-tenants-slurm.md) | HPC tenants: Slurm on Kubernetes (Slinky) vs a separate Slurm cluster | HPC tenants, Paris CPU pool | accepted |
| [0008](0008-gpu-sharing.md) | GPU sharing per tenant class: MIG vs time slicing vs whole GPUs | GPU sharing, both GPU pools | accepted |
| [0009](0009-metrics-across-sites.md) | Metrics across sites: Thanos Receive for Finland, a sidecar for Paris (vs Mimir, VictoriaMetrics) | Observability, both sites | accepted |
| [0010](0010-vm-tenants.md) | VM tenants: KubeVirt on the same cluster vs a separate IaaS; KVM vs emulation | VM tenants, Paris CPU pool | accepted |

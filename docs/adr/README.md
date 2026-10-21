# Decision records

One page per real choice, with at least two genuine alternatives. Written for an NVIDIA Cloud Partner architect who wants to know why, not what.

| ADR | Decision | Owner | Status |
|---|---|---|---|
| 0001 | Two sites on two providers for one partner | cos | proposed |
| 0002 | Who owns the GPU driver: the GPU Operator or the provider image | cos | proposed |
| 0003 | Known-good stack: AICR recipes vs hand-pinned values (and what AICR doesn't cover: L4, kubeadm) | ws-readiness | proposed |
| 0004 | Readiness gate: NVCRE certification and a staging taint vs Part 1's burn-in scripts | ws-readiness | proposed |
| 0005 | Fault remediation: NVSentinel vs Part 1's controller vs node-problem-detector with a generic remediator | ws-readiness | proposed |
| 0006 | Batch scheduling for many tenants: KAI vs Kueue vs Volcano | ws-scheduling | proposed |
| 0007 | HPC tenants: Slurm on Kubernetes (Slinky) vs a separate Slurm cluster | ws-scheduling | proposed |
| 0008 | GPU sharing per tenant class: MIG vs time slicing vs whole GPUs | ws-scheduling | proposed |
| [0009](0009-metrics-across-sites.md) | Metrics across sites: Thanos Receive for fin, a sidecar for par (vs Mimir, VictoriaMetrics) | ws-platform | proposed |
| [0010](0010-vm-tenants.md) | VM tenants: KubeVirt on the same cluster vs a separate IaaS; KVM vs emulation | ws-platform | proposed |

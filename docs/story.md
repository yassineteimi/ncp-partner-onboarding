# The story

EU1 is a fictional European GPU cloud partner. It has just taken delivery of two pools of hardware, in two places, from two providers:

- **par**, in Paris on Scaleway: an L4 pool for inference and development, beside a persistent control plane.
- **fin**, in Finland on Verda: an H200 pool for training, with NVLink between the GPUs. It exists only while I rent it.

Before its first tenant arrives, EU1 needs what any new NVIDIA Cloud Partner needs:

1. **Day 0.** A known-good software stack for each hardware class, pinned rather than remembered.
2. **Day 1.** Proof that a node is ready before it takes work, and a gate that keeps it out until then.
3. **Day 2.** Faults found, the node drained, repaired and returned to service without waiting for a person.
4. **Tenancy.** Scarce GPUs shared fairly between teams, jobs that start whole or not at all, and a slice of a GPU where a whole one is too much.
5. **HPC.** A Slurm team on the same platform, without a second cluster.
6. **One view.** Metrics from both sites in one place, including a site that has already been torn down.
7. **VMs.** A tenant who can't move to containers yet.

I build each of these with NVIDIA's open tooling: AICR, NVCRE, NVSentinel, KAI Scheduler with MIG, Slurm through Slinky, then Thanos and KubeVirt. Both sites run upstream Kubernetes 1.36 through kubeadm, from the same bootstrap scripts and the same Git repository through ArgoCD. What changes between them is the provider underneath, and with it who installs the GPU driver.

[Part 1](https://github.com/yassineteimi/nvidia-gpu-fleet-poc) did Day 2 by hand on one L4. Here, NVSentinel replaces the remediation controller I wrote, on the same GPU with the same injected fault, and I compare the two timelines.

!!! note "Status on 19 October 2026: planned"
    Nothing on this page has run yet. Each use case gets its own page, with its evidence, once it has.

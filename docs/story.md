# The story

Nordhaven is a fictional European GPU cloud partner, a newcomer in the NVIDIA Cloud
Partner program, and it has just taken delivery of two pools of hardware in two places
from two providers:

- **Paris**, on Scaleway: an NVIDIA L4 pool for inference and development, next to a
  control plane that stays up.
- **Finland**, on Verda: a training pool of 2× H200 SXM5 nodes with NVLink between the
  GPUs. At $11.66 an hour per node, it exists only while it's being used.

Its first tenants arrive soon. One is a research group that lives in Slurm, one runs
distributed PyTorch, and one ships a VM image it can't containerise yet. Before any of
them get a GPU, Nordhaven has to answer the questions every new partner faces:

1. **Day 0.** Which versions of the GPU stack go together on each hardware class,
   written down and pinned rather than remembered?
2. **Day 1.** How do we prove a node is ready before a tenant lands on it, and keep it
   out until then?
3. **Day 2.** When a GPU fails, how fast does it leave service, and how does it come
   back without waiting for a person?
4. **Tenancy.** How do teams share GPUs that never cover demand: guarantees, borrowing,
   jobs that start whole or not at all, and slices of a GPU where a whole one is too much?
5. **HPC.** Can the Slurm group run on the same platform instead of a second cluster?
6. **One view.** Can operators see every GPU of both sites in one place, including a
   site that's already been deleted?
7. **VMs.** Can a VM tenant run next to the containers, under the same quotas?

I answer each one with NVIDIA's open tooling where it exists: AICR for Day 0, NVCRE for
Day 1, NVSentinel for Day 2, KAI Scheduler with MIG for tenancy, then Slurm through
Slinky, Thanos and KubeVirt for the rest. Both sites run upstream Kubernetes 1.36
through kubeadm, from the same bootstrap scripts and the same repository through
ArgoCD. What changes between them is the provider underneath, and with it who installs
the GPU driver.

[Part 1](https://github.com/yassineteimi/nvidia-gpu-fleet-poc) did Day 2 by hand on one
L4. Here NVSentinel replaces the remediation controller I wrote, on the same GPU model
with the same injected fault, and the [Day 2 page](10-day2-nvsentinel.md) compares the
two timelines. Day 0 does the same for versions: Part 1's hand-pinned stack against
AICR's locked recipe.

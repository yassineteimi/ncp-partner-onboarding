# ADR 0010: VM tenants, KubeVirt on the same cluster, with KVM

Status: proposed
Date: 2026-10-20. Owner: ws-platform. Use case: 7.

## Context

Some of EU1's tenants can't move to containers yet: they ship a whole operating system image, or a licensed appliance, or software that expects to own a kernel. EU1 still wants to sell them capacity from the same fleet and run that fleet with the same people and tools as the container tenants.

There are two decisions here. Where those VMs run, and, for this PoC, whether they run on hardware virtualisation or on software emulation. The second one I could settle with a free check: par's CPU worker, a Scaleway POP2-8C-32G, exposes `/dev/kvm` with AMD SVM ([node facts](../artifacts/par/cpu-worker-facts.txt)).

## Options considered

Where the VMs run:

| Option | What it is | For EU1 | Against, for EU1 |
|---|---|---|---|
| A. KubeVirt on the same clusters | VMs as Kubernetes objects, each one a QEMU/KVM process inside a `virt-launcher` pod | One scheduler, one quota system, one GitOps flow and one monitoring stack for both kinds of tenant. Spare CPU capacity goes to whichever kind needs it. The GPU Operator already knows how to prepare a node for VM passthrough or vGPU | Kubernetes now carries tenants' operating systems, so a cluster upgrade can restart their VMs unless live migration works. Some VM features (snapshots, disk import) need extra components, CDI first. Operators have to understand both worlds |
| B. A separate IaaS for VM tenants | OpenStack, or the provider's own VMs, on a separate pool of hosts | The usual model for VM tenants, with mature VM features. A Kubernetes upgrade can't touch a VM | Two control planes, two quota systems and two on-call rotations. Capacity is split ahead of time and can't flow between the pools. GPUs would be split the same way, which is the most expensive place to waste capacity |

How this PoC runs them:

| Option | For | Against |
|---|---|---|
| KVM (`useEmulation: false`) | What production would use. The guest sees real hardware virtualisation | Needs `/dev/kvm` on the node: bare metal, or a cloud VM with nested virtualisation exposed |
| Emulation (`useEmulation: true`) | Runs anywhere, including KIND on a laptop | QEMU's software CPU is many times slower. Fine for testing manifests; it says nothing about real VM performance |

## Decision

**KubeVirt on the same clusters, with KVM.**

For EU1, the deciding argument is the GPUs. A VM tenant who later wants a GPU gets one from the same pool as everyone else, through the GPU Operator's sandbox mode, rather than from a pool sized months in advance for VM tenants only. Running one control plane is the second argument: the quota, the GitOps flow and the dashboards I already built for container tenants cover the VM tenant with no second system.

KVM is a free choice here, because the CPU worker has it. I didn't need emulation, so nothing in use case 7 is simulated.

What would change the answer:

- **A partner whose VM business is large and runs on its own** (many VM-only tenants, VM features like snapshots and live migration of every VM during every upgrade): a mature IaaS next to Kubernetes, and KubeVirt only for the occasional VM inside a container tenant's cluster.
- **GPU passthrough to VMs.** It needs bare metal, IOMMU on in the firmware and on the kernel command line (`amd_iommu=on` / `intel_iommu=on`), and a node that runs either containers, passthrough VMs or vGPU VMs, never a mix (GPU Operator 26.7 docs, "GPU Operator with KubeVirt"). A PCI-passthrough GPU can't be live-migrated (KubeVirt user guide, "Live migration"). vGPU can be, behind the `VGPULiveMigration` gate, which is Alpha since KubeVirt v1.9.0. A partner planning GPU VMs plans node pools by workload type. That doesn't change the decision; it changes how the fleet is labelled.

## Consequences

- One more operator on each cluster that has VM tenants. Here it runs on the CPU worker. The release manifest pins virt-operator to control-plane nodes, so a patch moves it, and the KubeVirt resource places virt-api and virt-controller.
- A VM's cost counts against its tenant's ResourceQuota through its `virt-launcher` pod, which requests the guest's memory plus an overhead. The first boot will measure that overhead, and the use case 7 page will report it (planned).
- With one CPU worker there's nowhere to live-migrate to, so the VM sets `evictionStrategy: None` and stops when the worker is drained. A real VM pool needs at least two nodes, and RWX storage or migratable disks, before it can promise anything across maintenance.
- **What this PoC can't show:**
  - GPU passthrough, which needs a bare-metal GPU node; both GPU types rented here are cloud VMs
  - live migration, with one worker
  - disk import and snapshots, because CDI isn't installed

## Evidence

- `/dev/kvm` and AMD SVM on the CPU worker: [cpu-worker-facts.txt](../artifacts/par/cpu-worker-facts.txt), captured 2026-10-20 by `scripts/par/cpu-up.sh`.
- KubeVirt 1.9 supports Kubernetes 1.34 to 1.36 (kubevirt/sig-release, `releases/k8s-support-matrix.md`).
- Placement: `pkg/virt-operator/resource/placement/placement.go` and `pkg/virt-operator/resource/generate/components/deployments.go` at KubeVirt v1.9.1.
- GPU Operator v26.7.2 chart values (`sandboxWorkloads`, `vfioManager`, `sandboxDevicePlugin`) and its 26.7 KubeVirt page. KubeVirt's live migration guide and the `VGPULiveMigration` gate in `pkg/virt-config/featuregate/active.go` at v1.9.1.
- Planned: the first boot on the CPU worker (`make kubevirt-capture`): boot time from KubeVirt's phase timestamps, the guest's own `systemd-detect-virt`, the launcher overhead against the quota, and the VM running next to the L4's GPU pods during W1.

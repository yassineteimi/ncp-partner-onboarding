# ADR 0010: VM tenants, KubeVirt on the same cluster, with KVM

Status: accepted
Scope: VM tenants, Paris CPU pool (use case 7). Decided after the first VM boot, 21 October 2026.

## Context

Some of Nordhaven's tenants can't move to containers yet: they ship a whole operating system image, or a licensed appliance, or software that expects to own a kernel. Nordhaven still wants to sell them capacity from the same fleet and run that fleet with the same people and tools as the container tenants.

There are two decisions here. Where those VMs run, and, for this PoC, whether they run on hardware virtualisation or on software emulation. The second one I could settle without renting anything: the Paris CPU worker, a Scaleway POP2-8C-32G, exposes `/dev/kvm` with AMD SVM ([node facts](../artifacts/par/cpu-worker-facts.txt)).

## Options considered

Where the VMs run:

| Option | What it is | For Nordhaven | Against, for Nordhaven |
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

For Nordhaven, the deciding argument is the GPUs. A VM tenant who later wants a GPU gets one from the same pool as everyone else, through the GPU Operator's sandbox mode, rather than from a pool sized months in advance for VM tenants only. Running one control plane is the second argument: the quota, the GitOps flow and the dashboards I already built for container tenants cover the VM tenant with no second system.

KVM costs nothing extra here, because the CPU worker has it. I didn't need emulation, so nothing in use case 7 is simulated.

The first boot on 21 October bore it out: the VM was Running 25 seconds after it was created, the guest reported `kvm` and booted in 20.2 seconds, and it kept running on the CPU worker while a training job used the L4 on another node ([use case 7 page](../30-vm-tenants.md)).

What would change the answer:

- **A partner whose VM business is large and runs on its own** (many VM-only tenants, VM features like snapshots and live migration of every VM during every upgrade): a mature IaaS next to Kubernetes, and KubeVirt only for the occasional VM inside a container tenant's cluster.
- **GPU passthrough to VMs.** It needs bare metal, IOMMU on in the firmware and on the kernel command line (`amd_iommu=on` / `intel_iommu=on`), and a node that runs either containers, passthrough VMs or vGPU VMs, never a mix (GPU Operator 26.7 docs, "GPU Operator with KubeVirt"). A PCI-passthrough GPU can't be live-migrated (KubeVirt user guide, "Live migration"). vGPU can be, behind the `VGPULiveMigration` gate, which is Alpha since KubeVirt v1.9.0. A partner planning GPU VMs plans node pools by workload type. That doesn't change the decision; it changes how the fleet is labelled.

## Consequences

- One more operator on each cluster that has VM tenants. Here it runs on the CPU worker. The release manifest pins virt-operator to control-plane nodes, so a patch moves it, and the KubeVirt resource places virt-api and virt-controller.
- Every KubeVirt image is pinned by digest, and a bump has to update all of them. The release manifest names images by tag only. A digest on virt-operator's own image doesn't reach the components it deploys: it builds each one as `<registry>/<name>:<KUBEVIRT_VERSION>`, unless that component's `*_IMAGE` env var gives a full reference. So `pin-images.yaml` sets thirteen digests: the operator, virt-api, virt-controller, virt-handler, virt-launcher, the export proxy and server, the synchronization controller, libguestfs, pr-helper, sidecar-shim, and the two virt-template components. The virt-template components follow their own releases, at v0.2.3 for KubeVirt v1.9.1, from a manifest the operator embeds. They deploy by default, because their `Template` gate is Beta and Beta gates are on unless disabled. A first version of this ADR said the gate was off and left them unpinned; the first deployment in Paris showed them running from their tags. `make kubevirt-check` fails on any reference left on a bare tag, but it can only check the env vars it knows about. A KubeVirt bump has to diff the operator's `*_IMAGE` constants in `pkg/virt-operator/util/config.go`, and then look at what actually runs (`make kubevirt-capture` lists every pod's image).
- A VM's cost counts against its tenant's ResourceQuota through its `virt-launcher` pod, which requests the guest's memory plus an overhead. For a 2 GiB guest the quota counted 1005m CPU and 2349 Mi of memory, about 15% more than the guest's memory. Tenants have to size quotas for that.
- With one CPU worker there's nowhere to live-migrate to, so the VM sets `evictionStrategy: None` and stops when the worker is drained. A real VM pool needs at least two nodes, and RWX storage or migratable disks, before it can promise anything across maintenance.
- **What this PoC can't show:**
  - GPU passthrough, which needs a bare-metal GPU node; both GPU types rented here are cloud VMs
  - live migration, with one worker
  - disk import and snapshots, because CDI isn't installed

## Evidence

- `/dev/kvm` and AMD SVM on the CPU worker: [cpu-worker-facts.txt](../artifacts/par/cpu-worker-facts.txt), captured 2026-10-20 by `scripts/par/cpu-up.sh`.
- KubeVirt 1.9 supports Kubernetes 1.34 to 1.36 (kubevirt/sig-release, `releases/k8s-support-matrix.md`).
- Placement: `pkg/virt-operator/resource/placement/placement.go` and `pkg/virt-operator/resource/generate/components/deployments.go` at KubeVirt v1.9.1.
- Image references: `getConfig` and `getTag` in `pkg/virt-operator/util/config.go`, and the `*_IMAGE` fallbacks in `components/deployments.go` and `components/daemonsets.go`, at v1.9.1. Digests come from quay.io's registry API for tag v1.9.1 (2026-10-20) and v0.2.3 (virt-template, 2026-10-21), checked against its tag API. The virt-template override is `getOverrideImageForDeployment` in `components/virttemplate.go`, the `Template` gate's Beta state is in `pkg/virt-config/featuregate/active.go`, and Beta gates are on by default in `IsEnabled` in `feature-gates.go`, all at v1.9.1.
- GPU Operator v26.7.2 chart values (`sandboxWorkloads`, `vfioManager`, `sandboxDevicePlugin`) and its 26.7 KubeVirt page. KubeVirt's live migration guide and the `VGPULiveMigration` gate in `pkg/virt-config/featuregate/active.go` at v1.9.1.
- The first boot in Paris, 21 October ([capture](../artifacts/platform/kubevirt-20261021T103649Z.txt)): Running 25 s after creation, the guest's own `systemd-detect-virt` says `kvm`, boot 20.2 s, and the launcher's requests against the quota.
- After the virt-template components were pinned ([capture](../artifacts/platform/kubevirt-20261021T114554Z.txt)): every KubeVirt pod runs by digest.
- The VM next to a GPU job ([capture](../artifacts/platform/kubevirt-20261021T170151Z.txt)): `web-01` Running on the CPU worker while `tenant-a`'s training pod held the L4.

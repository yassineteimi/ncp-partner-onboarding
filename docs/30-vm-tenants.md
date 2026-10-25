# VM tenants next to the GPU pods, with KubeVirt

=== "In short"

    ### The problem

    Some customers can't move to containers yet: they ship a whole operating system, a
    licensed appliance, or software that expects its own kernel. A partner wants to sell
    them capacity from the same fleet, run by the same people and tools, instead of
    running a second platform for VMs.

    ### What I used

    **KubeVirt** runs a virtual machine as a Kubernetes object: Argo CD deploys it, a
    tenant quota limits it, the same scheduler places it. The VM uses the server's
    hardware virtualisation (KVM), not slow software emulation
    ([ADR 0010](adr/0010-vm-tenants.md) explains why not a separate IaaS).

    ### What happened (Paris CPU worker, 21 October)

    | Check | Result |
    |---|---|
    | VM created to running | 25 s; the guest booted in 20.2 s and reports `kvm` itself |
    | Beside a GPU job | The VM ran while a training job used the L4 on another node, both placed by the same scheduler and quotas |
    | Control plane outage | The API server was down about 2 minutes; the VM never stopped |
    | Real cost of a 2 GiB VM | About 2.3 GiB counted against the tenant's quota, roughly 15% overhead |

    ### What I had to change

    - The operator demands a control-plane node; I moved it to the worker.
    - Argo CD can't tell when KubeVirt is ready, so a hook waits before creating the VM.
    - Pinning the operator's image doesn't pin the 13 components it deploys; each one is
      pinned explicitly.

    ### In one sentence

    A VM tenant ran on KVM under the same quotas, scheduler and GitOps as the GPU tenants,
    survived a control-plane outage, and cost about 15% more memory than its guest sees.

=== "Run evidence"

    ```mermaid
    flowchart LR
      argo["ArgoCD Application kubevirt<br/>wave 10"] --> op["virt-operator<br/>1 replica, CPU worker"]
      op --> cr["KubeVirt resource<br/>useEmulation: false"]
      cr --> api["virt-api, virt-controller,<br/>export proxy, virt-template"]
      cr --> handler["virt-handler<br/>DaemonSet, CPU worker only"]
      wait["Sync hook Job<br/>waits for Available"] --> tenant["tenant-vm: quota,<br/>VM web-01, Service"]
      handler --> launcher["virt-launcher pod<br/>QEMU/KVM, the guest"]
      tenant --> launcher
    ```

    ### Setup

    - KubeVirt v1.9.1 on `eu1-par-cpu-01` (POP2-8C-32G, `/dev/kvm` with AMD SVM,
      [node facts](artifacts/par/cpu-worker-facts.txt)); nothing on the control plane.
    - Changes, read in KubeVirt's source at v1.9.1:

    | Default | Problem | Change |
    |---|---|---|
    | virt-operator requires a control-plane node (`components/deployments.go`) | No override | Kustomize patch: CPU worker, 1 replica |
    | Argo CD v3.5.3 has no health check for the KubeVirt resource | The VM would be applied before its CRD exists | Sync hook Job waits for `Available` |
    | Components' images built from the version tag | A digest on the operator pins nothing else | 13 `*_IMAGE` variables by digest ([`pin-images.yaml`](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/gitops/manifests/platform/kubevirt/pin-images.yaml)); the 2 virt-template ones were missed at first ([finding](findings.md)) |

    ### First boot, 21 October (UTC)

    ```{ .sh .terminal }
    $ make kubevirt-capture
    # capture-kubevirt.sh, 20261021T103649Z, laptop clock, UTC. git 28f386b

    ## KubeVirt
    phase: Deployed
    version: v1.9.1
    useEmulation: false
    ...
      Scheduled    2026-10-21T10:31:31Z  +23 s after the VMI was created
      Running      2026-10-21T10:31:33Z  +25 s after the VMI was created
    ...
    ## The guest's own page, through Service tenant-vm/web-01
    hostname: web-01
    hypervisor seen by the guest: kvm
    kernel: 6.8.0-147-generic
    cpu: AMD EPYC-Milan Processor
    vcpus: 1
    memory: 1903 MiB
    boot: Startup finished in 6.302s (kernel) + 13.928s (userspace) = 20.231s 
    ...
    ```

    [Full capture](artifacts/platform/kubevirt-20261021T103649Z.txt).

    **Quota cost of a 2 GiB VM:** `compute` container 1 CPU, 2316 Mi; console-log sidecar
    5m, 35 M; counted by the `tenant-vm` quota: 1005m and 2349 Mi.

    **Resilience:** pinning the virt-template images rolled the operator, and from about
    12:05 to 12:10 UTC the control plane's disk saturated (API server down about 2 minutes,
    KubeVirt controllers crash-looping). The VM instance created at 10:31 never stopped.

    ### Next to a GPU training job, 17:01:51 UTC

    ```{ .sh .terminal }
    $ make kubevirt-capture
    ...
    ## The tenant VM
    NAME                                AGE     STATUS    READY
    virtualmachine.kubevirt.io/web-01   6h30m   Running   True
    ...
    ## Pods holding a GPU right now, cluster-wide
    tenant-a         goodput-xq462                                    eu1-par-gpu-01     Running    gpus=1
    ```

    [Full capture](artifacts/platform/kubevirt-20261021T170151Z.txt). The L4's reboot that
    followed (the NVSentinel test) didn't touch the VM, which runs on another node.

    ### Limits

    - No live migration with one worker: `web-01` uses `evictionStrategy: None`.
    - No GPU passthrough to a VM: it needs bare metal with IOMMU; both GPU types here are cloud VMs.
    - No disk import or snapshots (CDI not installed); the VM boots from a pinned container disk.
    - Nothing simulated.

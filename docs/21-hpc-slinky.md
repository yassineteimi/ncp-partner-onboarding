# Use case 5: a Slurm group on the same platform

One of EU1's first customers is a research group that has used Slurm for years. Its people submit with `sbatch` and `srun` and won't rewrite their scripts as Kubernetes Jobs. EU1 doesn't want a second fleet for them. So Slurm runs inside par's Kubernetes cluster through [Slinky](https://github.com/SlinkyProject/slurm-operator), SchedMD's own operator, on the same CPU worker, monitoring and health story as every other tenant. [ADR 0007](adr/0007-hpc-tenants-slurm.md) says why Slinky and not Soperator or a separate Slurm cluster.

!!! note "Status, Thursday 22 October"
    Running on par since 21 October. `make slurm-test` passes all four of its steps. Slurm with GPUs on fin isn't built in this PoC; its design is in [its own section](#slurm-with-gpus-on-fin-designed-not-run), marked planned.

## What's built

One Application, `slinky` (`gitops/apps/par/scheduling/slinky.yaml`), with four sources: the slurm-operator chart 1.2.3, the slurm chart 1.2.3, the values in `gitops/values/scheduling/`, and a small bootstrap manifest. Everything runs in the `slurm` namespace on par's CPU worker (`eu1.io/pool: cpu`), with Slurm 26.05:

| Part | What it is | Notes |
|---|---|---|
| `slurm-operator` and its webhook | Reconcile Slinky's `Controller`, `NodeSet`, `LoginSet` and `RestApi` objects | One replica each, leader election off (see below). The webhook's certificate comes from cert-manager |
| `slurm-controller-0` | slurmctld, the Slurm scheduler | Its save state sits on a 2 GiB `local-path` volume, on the worker's disk, so it survives a power-off |
| `slurm-worker-cpu-0`, `-1` | slurmd, as Slurm nodes `cpu-0` and `cpu-1` in partition `cpu` | Both on the one VM (`oversubscribeNode`), standing in for two machines |
| `slurm-login-hpc` | The login pod where users run `sbatch`, `srun` and `squeue` | ClusterIP only |
| `slurm-restapi` | slurmrestd | The operator talks to Slurm through it |

No accounting: `sacct` and fair share over time need slurmdbd and a MariaDB, which this PoC doesn't run.

**Keys made in the cluster, not in Git.** Slurm needs a shared auth key and a JWT key. The slurm chart can create them, but with `randAscii` and `lookup` on immutable Secrets, which ArgoCD renders differently on every sync (a [finding](findings.md)). So the chart's own key creation is off, and a Job in sync wave -1, `slurm-keys-bootstrap`, creates `slurm-auth-slurm` and `slurm-auth-jwt` once, only if they're missing, as immutable Secrets. On par it completed at 11:37:32 UTC on 21 October. No key exists in Git or on a laptop, and a sync never rotates one. The namespace's other Secrets are `slurm-login-hpc-ssh-host-keys`, the two webhook CAs from cert-manager, and `slurm-sssd-conf`.

**A health check before every job.** A prolog, `00-node-health.sh` in `gitops/values/scheduling/slurm.yaml`, runs on the Slurm node before each job. It fails if `/tmp` isn't writable, if less than 256 MiB of memory is available, or if the marker file `/var/run/eu1-simulated-fault` exists. **SIMULATED:** the marker is the fault the test creates on purpose ([simulated page](simulated.md)); the other two checks are real. When the prolog fails, Slurm drains the node and holds the job. It's the Slurm side of use case 2's readiness gate.

**How users get in.** The test runs commands in the login pod with `kubectl exec`. No identity provider is wired in yet (`slurm-sssd-conf` is empty), so nobody can ssh in. Giving the research group real logins means pointing sssd at their directory and exposing the login Service.

## What it shows

`make slurm-test` on par, 21 October ([capture](artifacts/scheduling/slurm-par-20261021T121647Z.txt)). Times are UTC.

1. **The cluster from both sides.** The pods and Slinky objects from Kubernetes, then `sinfo`: partition `cpu` with `cpu-0` and `cpu-1` idle, 8 CPUs and about 31 GiB each, both on the same VM.
2. **A user's jobs.** `srun -N2 -l hostname` ran across both nodes. An `sbatch` job finished `COMPLETED` in 7 seconds.
3. **The prolog drains a sick node.** The test created the simulated fault marker in `cpu-0` at 12:16:58 and sent a job there. At 12:16:59 Slurm drained `cpu-0` with reason "Prolog error" and held the job (`launch_failed_requeued_held`). The test then removed the marker, resumed the node and released the job, which completed on `cpu-0` with `Restarts=1`. From the release to `COMPLETED` took 160 seconds.
4. **Kubernetes drains a Slurm node.** The test annotated pod `slurm-worker-cpu-1` with `nodeset.slinky.slurm.net/pod-cordon=true`. Within 6 seconds Slurm showed `cpu-1` drained, with the reason "slurm-operator: Pod (slurm/slurm-worker-cpu-1) was cordoned", and the pod carried the condition `SlurmNodeStateDrain=True`. Removing the annotation brought `cpu-1` back to idle within 6 seconds.

Step 4 annotates one pod rather than cordoning the CPU worker, because the other lanes share that worker. Cordoning a Kubernetes node goes down the same path in the operator (`syncCordon` in `internal/controller/nodeset/nodeset_sync.go` at 1.2.3), but this test doesn't show it.

One gap in step 3: the drain shows in `sinfo` but not yet as a condition on the pod. The operator writes pod conditions when it reconciles, and the test reads them within a second of the drain.

## What went wrong first

The first sync and the first test run turned up four problems. Each one is now fixed in Git, and they're worth knowing before installing Slinky anywhere else.

- **slurmctld stayed Pending.** par has no default StorageClass, and the slurm chart's `controller.persistence.storageClassName` defaults to null, meaning "use the default". The claim never bound. PR #16 names `local-path`. A StatefulSet's claim template can't change in place, so the old StatefulSet and its Pending claim had to be deleted for the operator to recreate them. Delete the StatefulSet first, then the claim. In the other order, the old StatefulSet recreates the claim without a class before it goes away, which is what happened on par.
- **ArgoCD said Healthy throughout.** Slinky's `Controller` has no status and the NodeSet's is empty, so ArgoCD calls them healthy as soon as they're applied, and the slurmctld pod belongs to the operator, not to the Application. Healthy on `slinky` means the objects exist. Whether Slurm works is what `make slurm-test` answers.
- **The pod-cordon drain undid itself.** [First run](artifacts/scheduling/slurm-par-20261021T115447Z.txt): steps 1 to 3 passed, step 4 didn't. Under the NodeSet's default `RollingUpdate` strategy, Slinky 1.2.3 drains the Slurm node for an annotated pod, then in the same reconcile removes the annotation from every pod it keeps and undrains the node. The operator logged "Uncordon Pod slurm-worker-cpu-1" one second after the annotation. Upstream PR #271 (open) describes the same bug. PR #19 sets the NodeSet to `OnDelete`, under which the cordon holds. The cost: a new slurmd image reaches a node only when its pod is deleted, so an upgrade is a drain and a delete per node.
- **The operator kept restarting.** It and its webhook exited with "leader election lost" four times in their first 22 minutes, each time a lease renewal took longer than 5 seconds. The cause wasn't Slinky: Grafana on par's control plane was page-faulting its own binary under a 384 Mi memory limit, and the reads starved etcd on the same disk. cos raised the limit (89feaf8). PR #19 also turned leader election off for both. That's a PoC choice: with one replica there's nothing to elect against. A production install running two replicas keeps it on.

## Slurm with GPUs on fin: designed, not run

!!! warning "Planned: designed, not built or run"
    Slurm on fin's H200s was W2 step 7. Yassine cut it on 22 October, because nothing for it was built and it would have run untested on the H200s. This section is the design, read from the source at the pinned versions: Slinky slurm-operator and slurm chart 1.2.3, Slurm 26.05.5 (the version inside the pinned slurmd image), GPU Operator v26.7.2, KAI v0.18.6. Nothing in it has run.

### The NodeSet and GRES for 2x H200

fin would get its own `slinky` Application, like its own KAI: the operator, slurmctld, the login pod and slurmrestd on fin's CPU node, with slurmctld's state on fin's `local-path`, and the keys made by the same bootstrap Job as on par. The new piece is one GPU NodeSet, `h200`. These values render with slurm chart 1.2.3 into what I'd expect (checked with `helm template` only):

```yaml
nodesets:
  h200:
    enabled: true
    replicas: 1                      # one slurmd pod per GPU node
    slurmd:
      env:
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: compute,utility
      resources:
        limits:
          nvidia.com/gpu: 2          # every GPU on the node
    extraConfMap:
      Gres: ["gpu:2"]                # becomes slurmd -Z --conf "Gres=gpu:2"
    updateStrategy:
      type: OnDelete                 # as on par, so a pod-cordon drain holds
    podSpec:
      nodeSelector:
        eu1.io/pool: gpu-slurm
      tolerations:
        - key: eu1.io/slurm
          operator: Exists
          effect: NoSchedule
controller:
  extraConfMap:
    GresTypes: [gpu]                 # into slurm.conf
configFiles:
  gres.conf: |
    AutoDetect=nvidia
  cgroup.conf: |
    CgroupPlugin=cgroup/v2
    IgnoreSystemd=yes
    ConstrainDevices=yes             # a job sees only the GPUs Slurm gave it
```

Three facts from the source decide this shape:

- **The GPUs reach slurmd through the device plugin.** The slurmd pod asks for `nvidia.com/gpu: 2`, and the NVIDIA container runtime injects the driver's libraries and device files. The slurm chart assumes exactly that: its own DCGM integration switches on for any NodeSet with an `nvidia.com/gpu` limit (`templates/vendor/nvidia/dcgm/_helpers.tpl`). Inside the pod, Slurm hands GPUs to jobs and `ConstrainDevices` fences each job to its own.
- **Slinky's slurmd is a dynamic node.** The operator starts it as `slurmd -Z` with the NodeSet's `extraConf` as `--conf` (`internal/builder/workerbuilder/worker_app.go`). So the node's `Gres=` goes on the NodeSet, not on a `NodeName=` line, and `gres.conf` reaches slurmd configless from slurmctld.
- **The pinned slurmd image can see whole GPUs, not MIG.** Its layers carry `gpu_nvidia.so`, `gpu_generic.so` and `gpu_nrt.so` under `/usr/lib/x86_64-linux-gnu/slurm/`, but no `gpu_nvml.so`. Slurm's Debian packaging at 26.05.5 has no NVML build dependency. `AutoDetect=nvidia` needs no library, "but doesn't detect MIGs or NVlinks" (`gres.conf(5)` at 26.05.5), and that's enough for two whole H200s.

**MIG under Slurm** needs `AutoDetect=nvml` ("To configure MIGs in Slurm, specify AutoDetect=nvml", `doc/html/gres.shtml` at 26.05.5), so a slurmd image rebuilt with NVML. With `h200-split` applied, the NodeSet would then ask for `nvidia.com/mig-3g.71gb: 2` and `nvidia.com/gpu: 1` and declare something like `Gres=gpu:h200:1,gpu:3g.71gb:2`. Slurm wants each type to be a substring of the "MIG Profile" string slurmd logs at `debug2` (its own example is `nvidia_a100_3g.20gb`), so the exact names get read on the node, not guessed. Slurm doesn't partition MIG itself; the GPU Operator's MIG manager would, from the same node label as in use case 4. And Slurm keeps no `gpumem` or `gpuutil` accounting for MIG devices, because NVML has none. Unlike KAI, Slurm would use the whole GPU next to the slices, since slurmd's pod isn't scheduled by KAI.

### A GPU check in the prolog

The prolog on par, `00-node-health.sh`, checks `/tmp`, free memory and the simulated fault marker. On a GPU node, a second script would run after it:

```bash
# 10-gpu-health.sh: DCGM's quickest diagnostic on this job's GPUs, before the job starts.
[ -n "${SLURM_JOB_GPUS:-}" ] || exit 0          # not a GPU job
dcgmi diag -r 1 --host nvidia-dcgm.gpu-operator.svc:5555 -i "$DCGM_IDS" \
  || { echo "eu1 GPU health: dcgmi diag -r 1 failed" >&2; exit 1; }
```

A failure drains the node and holds the job, as the simulated fault did on par. The pieces come from fin's existing stack: our base values run the GPU Operator's standalone DCGM (`dcgm.enabled: true`), and at v26.7.2 the operator puts it behind Service `nvidia-dcgm`, port 5555, with `internalTrafficPolicy: Local` (`assets/state-dcgm/0500_service.yaml`). So a prolog on a node always talks to that node's own hostengine. Two things stay open. `dcgmi` isn't in the slurmd image, so it comes with the NVML rebuild. And `$DCGM_IDS` has to map Slurm's GPU indices to DCGM's by UUID, because nothing guarantees the two number the GPUs the same way.

Level 1 is the cheapest check DCGM has, which suits a run before every job. The deeper `dcgmi diag -r 2` that NVCRE runs in the gate stays where it is, before promotion. Slurm's `HealthCheckProgram` could run something in between on an interval, while the node idles. Node-level faults need no new code at all: NVSentinel already cordons a node on a GPU fault (use case 3), and a cordoned Kubernetes node makes Slinky drain its Slurm node, with the reason "Node (…) was cordoned" (`syncCordon` in `internal/controller/nodeset/nodeset_sync.go`). That path skips pod uncordoning, so it holds under any update strategy.

### How KAI and Slurm split fin

By whole node, never by GPU:

- **A node belongs to one of them.** Slurm's GPU nodes carry `eu1.io/pool: gpu-slurm` and the taint `eu1.io/slurm=true:NoSchedule`. KAI's tenants select `eu1.io/pool: gpu` and tolerate neither. That's the pattern Slinky's own workload-isolation guide uses, a taint the NodeSet tolerates (`docs/usage/workload-isolation.md`).
- **Never the same GPU.** slurmd's pod takes every GPU on its node through the device plugin. Even a pod that slipped past the label and the taint would find no GPU left to allocate. The device plugin, not a convention, is what keeps the two schedulers apart.
- **The staging gate applies to both.** A new H200 joins with `eu1.io/staging=pending:NoSchedule`, and the slurmd pod doesn't tolerate it, exactly like KAI's pods. Slurm only ever sees a node after NVCRE has certified it and the gate has promoted it.
- **Moving a node between them** is maintenance: cordon it, which makes Slinky drain its Slurm node, wait for the jobs to finish, delete the slurmd pod, then change the label and taint. W2 showed one more reason to keep the split per node: KAI v0.18.6 won't place a whole-GPU pod on a node with MIG on ([ADR 0008](adr/0008-gpu-sharing.md)), so fin's node pools already have to be whole-GPU or MIG, node by node.

KAI could also schedule the slurmd pods themselves, through an `hpc` queue whose quota is the Slurm nodes' GPUs, so one fair-share view covers both. I'd leave that out at first. KAI could then reclaim a slurmd pod like any over-quota workload, and with it every Slurm job on that node.

### fin's 580 driver and the CUDA in slurmd

fin's image ships driver 580.178.04. The R580 branch is CUDA 13.0's own; CUDA 13.1 to 13.4 belong to R590 through R615, and run on 580 only through minor-version compatibility ("13.x: >= 580" in NVIDIA's CUDA Toolkit release notes, read 22 October). That mode has limits: anything that needs a newer driver fails, and PTX built by a newer toolkit can't be compiled by the older driver. So the ceiling for jobs on fin is CUDA 13.0 natively, or 13.x with those limits.

The pinned slurmd image holds no CUDA at all. Its environment sets none, its layers carry no `libcuda`, and the driver's libraries arrive from the container runtime. So a job's CUDA comes from one of two places:

- **The slurmd image itself**, rebuilt with the tenant's stack, as Slinky's PyTorch tutorial does (`docs/usage/tutorial-pytorch.md`). That puts every tenant on one image, which EU1 would have to keep within CUDA 13.0.
- **The job's own container**, through pyxis and enroot (`docs/usage/pyxis.md`, with Slinky's `slurmd-pyxis` image). Tenants bring their image, and EU1 keeps one slurmd. Part 1's trainer image, CUDA 12.8, already ran natively on this driver in W2. The cost is that Slinky's pyxis guide runs the login container privileged so enroot works there.

For a group with its own software stack, I'd pick pyxis: it keeps the CUDA choice with the tenant, and the platform's job is only to publish the ceiling.

### Why it wasn't run

- **Cost.** Every minute on fin is a billed H200. Slurm with GPUs needs its own operator and controller on fin, then the node taken away from KAI for the run, which in W2 would have meant fewer minutes for the gang and MIG.
- **No free check reaches the parts that matter.** I can render the charts, dry-run the objects on a cluster and parse the Slurm config for free. Whether `AutoDetect=nvidia` finds both GPUs inside the pod, whether `ConstrainDevices` fences them per job, and whether a prolog can reach DCGM only show on a GPU node.

W3, on Saturday, has an hour on fin. It could run this if it's built on Friday and passes those free checks first. That's a call for cos and Yassine on Friday, not a plan yet.

## Run it

| Target | What it does | Needs |
|---|---|---|
| `make sched-check` | Free checks: renders of both charts, digests, Slinky's objects against their CRDs; `DRY_RUN=server` adds a dry run on par | nothing |
| `make slurm-test` | The four steps above, into `docs/artifacts/scheduling/slurm-par-<stamp>.txt` | par's CPU worker, `slinky` synced |

## What one VM can't show

- **Two machines.** Both Slurm nodes run on one VM (`oversubscribeNode`, which Slinky marks as not for production).
- **GPUs in Slurm.** par's Slurm is CPU-only, and Slurm on fin's H200s isn't built in this PoC. The design is below, under "Slurm with GPUs on fin".
- **Shared storage.** With no ReadWriteMany volume, a job's output stays on the node that ran it.
- **Accounting and fair share over time.** No slurmdbd.
- **Performance next to a bare-metal Slurm.** Not measured.

## Evidence

- [`make slurm-test`, all four steps passing](artifacts/scheduling/slurm-par-20261021T121647Z.txt), 21 October, after PR #19.
- [The first run](artifacts/scheduling/slurm-par-20261021T115447Z.txt), with step 4 failing under `RollingUpdate`.
- [Free checks, 21 October](artifacts/scheduling/free-checks-20261021T065628Z.txt): renders, digests, Slinky's objects against their CRDs, server-side dry run on par.
- Source at the pinned versions: slurm-operator 1.2.3 `docs/usage/nodeset-operations.md` ("Cordoning Pods") and `internal/controller/nodeset/nodeset_sync.go`; slurm chart 1.2.3 `values.yaml` (`controller.persistence.storageClassName`) and `templates/secrets/slurmkey.yaml`; upstream PR #271.
- Sources for the GPU design, at the pinned versions: slurm-operator 1.2.3 `internal/builder/workerbuilder/worker_app.go` (`slurmd -Z`), `docs/usage/workload-isolation.md`, `docs/usage/pyxis.md`, `docs/usage/tutorial-pytorch.md`; slurm chart 1.2.3 `values.yaml` (`configFiles`, `controller.extraConfMap`, `nodesets.*.extraConfMap`) and `templates/vendor/nvidia/dcgm/_helpers.tpl`; Slurm 26.05.5 `doc/man/man5/gres.conf.5` (`AutoDetect`, `MultipleFiles`), `doc/html/gres.shtml` ("MIG Management") and `debian/control`; the layers of the pinned `ghcr.io/slinkyproject/slurmd` image (`gpu_nvidia.so`, no `gpu_nvml.so`; version label 26.05.5); GPU Operator v26.7.2 `assets/state-dcgm/0500_service.yaml`; NVIDIA's CUDA Toolkit release notes, read 22 October (driver branch per toolkit, minor-version compatibility).

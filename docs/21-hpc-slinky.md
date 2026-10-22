# Use case 5: a Slurm group on the same platform

One of EU1's first customers is a research group that has used Slurm for years. Its people submit with `sbatch` and `srun` and won't rewrite their scripts as Kubernetes Jobs. EU1 doesn't want a second fleet for them. So Slurm runs inside par's Kubernetes cluster through [Slinky](https://github.com/SlinkyProject/slurm-operator), SchedMD's own operator, on the same CPU worker, monitoring and health story as every other tenant. [ADR 0007](adr/0007-hpc-tenants-slurm.md) says why Slinky and not Soperator or a separate Slurm cluster.

!!! note "Status, Wednesday 21 October"
    Running on par since 21 October. `make slurm-test` passes all four of its steps. Slurm with GPUs on fin isn't built in this PoC.

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

## Run it

| Target | What it does | Needs |
|---|---|---|
| `make sched-check` | Free checks: renders of both charts, digests, Slinky's objects against their CRDs; `DRY_RUN=server` adds a dry run on par | nothing |
| `make slurm-test` | The four steps above, into `docs/artifacts/scheduling/slurm-par-<stamp>.txt` | par's CPU worker, `slinky` synced |

## What one VM can't show

- **Two machines.** Both Slurm nodes run on one VM (`oversubscribeNode`, which Slinky marks as not for production).
- **GPUs in Slurm.** par's Slurm is CPU-only, and Slurm on fin's H200s isn't built in this PoC. It would need a Slinky Application on fin, a GPU NodeSet with Slurm's GRES configured for the H200s, and the GPU Operator's container runtime in slurmd. None of it is tested here.
- **Shared storage.** With no ReadWriteMany volume, a job's output stays on the node that ran it.
- **Accounting and fair share over time.** No slurmdbd.
- **Performance next to a bare-metal Slurm.** Not measured.

## Evidence

- [`make slurm-test`, all four steps passing](artifacts/scheduling/slurm-par-20261021T121647Z.txt), 21 October, after PR #19.
- [The first run](artifacts/scheduling/slurm-par-20261021T115447Z.txt), with step 4 failing under `RollingUpdate`.
- [Free checks, 21 October](artifacts/scheduling/free-checks-20261021T065628Z.txt): renders, digests, Slinky's objects against their CRDs, server-side dry run on par.
- Source at the pinned versions: slurm-operator 1.2.3 `docs/usage/nodeset-operations.md` ("Cordoning Pods") and `internal/controller/nodeset/nodeset_sync.go`; slurm chart 1.2.3 `values.yaml` (`controller.persistence.storageClassName`) and `templates/secrets/slurmkey.yaml`; upstream PR #271.

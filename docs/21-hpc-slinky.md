# HPC: a Slurm group on the same platform, with Slinky

=== "In short"

    ### The problem

    Many research groups have used **Slurm**, the classic HPC job scheduler, for years. They
    submit with `sbatch` and `srun` and won't rewrite their scripts for Kubernetes. A
    partner doesn't want a second, separate cluster just for them.

    ### What I used

    **Slinky**, SchedMD's own operator, runs Slurm *inside* Kubernetes: Slurm's scheduler
    and its worker daemons are pods, on the same nodes, monitoring and health checks as
    every other tenant ([ADR 0007](adr/0007-hpc-tenants-slurm.md) explains why not
    Soperator or a separate Slurm cluster).

    ### What happened (Paris CPU worker, 21 October)

    | Check | Result |
    |---|---|
    | A user's jobs | `srun` across both Slurm nodes and an `sbatch` job completed in 7 s |
    | A health check before every job | A sick node (simulated fault) was drained by Slurm in 1 s; the job was held, then completed once the node was fixed |
    | Kubernetes and Slurm agree on maintenance | Cordoning a worker pod in Kubernetes drained the matching Slurm node in 6 s |

    One upstream bug: Slinky's default update mode undid that drain one second later. I
    switched to the mode that holds it, at the price of a manual step per node on upgrades.

    ### Slurm with GPUs: designed, not run

    Running it would have meant untested work on a rented H200, so I wrote the design
    instead:

    - **Whole GPUs work with the standard Slurm image;** MIG slices and a GPU health check
      need a custom image (built with NVIDIA's NVML library).
    - **Each GPU server belongs either to Slurm or to KAI,** never shared: a label and a
      taint keep them apart, and Slurm's pod takes every GPU on its server.
    - **The same certification gate applies:** Slurm only sees a server after it passed Day 1.
    - **Tenants bring their own container** (pyxis), so their CUDA version stays their
      choice, within the driver's limit.

    ### In one sentence

    Slurm users keep `sbatch` while running on the same Kubernetes platform, maintenance
    stays in sync both ways, and I designed the GPU version on paper rather than test it
    untested on rented H200 time.

=== "Run evidence"

    ### Setup

    - One Application, `slinky`: slurm-operator and slurm charts 1.2.3, Slurm 26.05, in
      namespace `slurm` on the Paris CPU worker. Two Slurm nodes (`cpu-0`, `cpu-1`) on one
      VM (`oversubscribeNode`); slurmctld state on a 2 GiB `local-path` volume.
    - **Keys made in the cluster, not in Git:** the chart's `randAscii` + `lookup` would
      change on every Argo CD sync ([finding](findings.md)), so a wave -1 Job creates the
      auth and JWT keys once, as immutable Secrets.
    - **Prolog `00-node-health.sh`:** fails if `/tmp` isn't writable, if under 256 MiB of
      memory is free, or if the SIMULATED marker `/var/run/eu1-simulated-fault` exists.
    - No accounting (no slurmdbd), no ssh logins (sssd not wired): the test runs commands in
      the login pod.

    ### Results, Paris, 21 October (UTC)

    ```{ .sh .terminal }
    $ make slurm-test
    ...
    ## 2. srun across both nodes, then sbatch   [12:16:49Z]
    0: cpu-1
    1: cpu-0
    ...
    after 7s: job 5 completed
    ...
    ## 3. Prolog health check: SIMULATED fault on cpu-0   [12:16:57Z]
    marker /var/run/eu1-simulated-fault created in slurm-worker-cpu-0 at 12:16:58Z
    submitted job 6 to cpu-0
    after 1s: cpu-0 drained by the prolog
    REASON               USER      TIMESTAMP           NODELIST
    Prolog error         slurm     2026-10-21T12:16:59 cpu-0
    ...
    after 160s: job 6 completed after the fix
    ...
    ## 4. Kubernetes to Slurm: nodeset.slinky.slurm.net/pod-cordon=true on slurm-worker-cpu-1   [12:19:42Z]
    ...
    after 6s: cpu-1 drained by the operator
    REASON               USER      TIMESTAMP           NODELIST
    slurm-operator: Pod  slurm     2026-10-21T12:19:43 cpu-1
    SlurmNodeStateDrain=True message="slurm-operator: Pod (slurm/slurm-worker-cpu-1) was cordoned" since 2026-10-21T12:19:45Z
    ...
    jobs ran from the login pod; prolog and Kubernetes drains both seen from Slurm and Kubernetes
    ```

    [Full capture](artifacts/scheduling/slurm-par-20261021T121647Z.txt). The held job
    (`launch_failed_requeued_held`) completed with `Restarts=1`. Removing the annotation
    returned `cpu-1` to idle within 6 s. The test cordons one pod, not the shared worker;
    a node cordon takes the same operator path (`syncCordon`) but isn't shown.

    ### Issues met, all fixed in Git

    | Issue | Cause | Fix |
    |---|---|---|
    | slurmctld Pending | No default StorageClass; the chart's class defaults to null | `local-path`; delete the StatefulSet before its claim |
    | Argo CD shows Healthy while Slurm is down | Slinky's objects have no status | `make slurm-test` is the health check |
    | Pod-cordon drain undone 1 s later ([first run](artifacts/scheduling/slurm-par-20261021T115447Z.txt)) | Slinky 1.2.3 under `RollingUpdate` (upstream PR 271, open) | NodeSet `OnDelete`; an upgrade becomes a drain and delete per node |
    | Operator lost leader election 4 times | Grafana page-faulting under 384 Mi starved etcd's disk | Grafana limit raised; leader election off with one replica |

    ### Slurm with GPUs, Finland: designed, not run

    Written from the source at the pinned versions (slurm-operator and chart 1.2.3, Slurm
    26.05.5, GPU Operator v26.7.2, KAI v0.18.6); only `helm template` was run.

    ```yaml
    nodesets:
      h200:
        enabled: true
        replicas: 1                      # one slurmd pod per GPU node
        slurmd:
          resources:
            limits:
              nvidia.com/gpu: 2          # every GPU on the node
        extraConfMap:
          Gres: ["gpu:2"]                # becomes slurmd -Z --conf "Gres=gpu:2"
        updateStrategy:
          type: OnDelete                 # as in Paris, so a pod-cordon drain holds
        podSpec:
          nodeSelector:
            eu1.io/pool: gpu-slurm
          tolerations:
            - key: eu1.io/slurm
              operator: Exists
              effect: NoSchedule
    controller:
      extraConfMap:
        GresTypes: [gpu]
    configFiles:
      gres.conf: |
        AutoDetect=nvidia
      cgroup.conf: |
        CgroupPlugin=cgroup/v2
        IgnoreSystemd=yes
        ConstrainDevices=yes             # a job sees only the GPUs Slurm gave it
    ```

    | Topic | Design | From the source |
    |---|---|---|
    | GPUs into slurmd | Via the device plugin and NVIDIA runtime; `ConstrainDevices` fences each job | The chart enables DCGM for any NodeSet with an `nvidia.com/gpu` limit |
    | GRES | On the NodeSet, not a `NodeName=` line | Slinky starts slurmd as a dynamic node, `slurmd -Z --conf` |
    | Whole GPUs vs MIG | `AutoDetect=nvidia` works for whole GPUs; MIG needs `AutoDetect=nvml`, so an image rebuilt with NVML | The pinned slurmd image has `gpu_nvidia.so`, no `gpu_nvml.so` |
    | GPU health check | Prolog `dcgmi diag -r 1` via Service `nvidia-dcgm:5555` (node-local); needs `dcgmi` in the image and a UUID map of GPU indices | GPU Operator v26.7.2 `assets/state-dcgm/0500_service.yaml` |
    | KAI vs Slurm | Per node: label `eu1.io/pool: gpu-slurm`, taint `eu1.io/slurm`; slurmd takes every GPU; the staging taint applies to both | Slinky's workload-isolation guide |
    | Faults | NVSentinel cordons the node, Slinky drains the Slurm node | `syncCordon` holds under any update strategy |
    | CUDA | Tenants bring their container through pyxis; the platform publishes the driver ceiling (CUDA 13.0 native on 580) | Slinky's pyxis guide runs the login container privileged |

    Not run because every minute is a rented H200, and no check without a GPU reaches what
    matters: whether `AutoDetect` finds the GPUs in the pod, whether `ConstrainDevices`
    fences them, whether the prolog reaches DCGM.

    ### Limits

    - Two Slurm nodes on one VM; no shared storage; no accounting or fair share over time.
    - The Paris Slurm is CPU only. Not compared with a bare-metal Slurm.

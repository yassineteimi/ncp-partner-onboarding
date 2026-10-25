# Findings

What didn't behave as the documentation, or my first assumption, said, and what I
changed. Part 1's findings are on [its own page](https://yassineteimi.github.io/nvidia-gpu-fleet-poc/findings/).

## NVIDIA stack

| Component | Finding | Impact | What I did | Evidence |
|---|---|---|---|---|
| NVCRE v0.8.0 | Assumes 8 GPUs per H200 node (4 for unknown GPUs like the L4), ships no thresholds, its only DCGM category is level 4 (about 90 min), and doesn't enforce its "controller on a non-GPU node" rule | A 2-GPU node is dropped; PASSED only means "ran" | `gpusPerNode`, a 64 GB/s floor, my own level 2 `WorkloadRun`, a node affinity | [Day 1](10-day1.md#nvcre-certify-the-node-before-tenants-use-it) |
| NVCRE v0.8.0 | Summary prints `Transport: Socket` for an all-reduce that ran over NVLink | The summary can't prove the transport | The gate reads the raw `NCCL_DEBUG=INFO` channel lines | [report](artifacts/readiness/nvcre-fin-20261022T100307Z-report.txt), [NCCL log](artifacts/readiness/nvcre-fin-20261022T100307Z-nccl.log) |
| NVCRE v0.8.0 | Its `pytorch:26.01` image targets driver 590; Finland runs 580 | Expected a forward-compatibility failure | It ran: the MPI all-reduce through the image's compat libraries (`13010`), the loopback through minor-version compatibility (`13000`); 25.11 fallback unused | [NCCL log](artifacts/readiness/nvcre-fin-20261022T100307Z-nccl.log) |
| NVCRE v0.7.0 | Controller exits on `unknown flag: --namespace-access-timeout` from the v0.8.0 chart | Image and chart must move together | Noted; the rolling update kept v0.8.0 serving | [drift demo](artifacts/readiness/aicr/drift-demo-par.txt) |
| NVSentinel v1.28.0 | Defaults: drain waits for jobs to finish, the reboot provider `kind` fakes the reboot, the circuit breaker trips on the first cordon with one GPU node and blocks the uncordon, the Git chart uses tag `main` | Remediation would never have run | `Immediate` drain, `generic` provider, breaker off, OCI chart pinned | [values](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/gitops/values/readiness/nvsentinel-par.yaml) |
| NVSentinel + journald | journald takes `NVRM:` from a userspace `/dev/kmsg` write as the syslog identifier and strips it | Part 1's simulated XID is invisible (real kernel XIDs aren't affected) | `[uptime]` prefix, as NVSentinel's tests do (systemd 255) | `fc2-journald-*.txt` in the readiness evidence |
| AICR v1.1.0 | No recipe for `kubeadm` or the L4; every H200 recipe requires Ubuntu 24.04 (Finland runs 26.04); its Kubeflow recipe pins Trainer 2.2.0 (NVCRE needs 2.2.1) and cert-manager 1.20.2 (NVSentinel needs 1.21) | Can't install or validate this cluster | AICR as reference only (ADR 0003) | [Day 1](10-day1.md#aicr-a-known-good-software-stack) |
| AICR v1.1.0 | `aicr diff` missed a hand-changed image: digest-pinned images read `latest`, and same-named pods merge | Not a drift detector on a GitOps cluster | Argo CD stays the drift detector (it reverted the change in 11 s) | [drift demo](artifacts/readiness/aicr/drift-demo-par.txt) |
| AICR v1.1.0 | The snapshot can't read the kernel configuration: neither provider image ships `/boot/config-*` | No kernel options in snapshots | Noted | [agent log](artifacts/readiness/aicr/snapshot-par-20261021T105254Z.yaml.log) |
| dcgm-exporter 4.8.4 | Starts before the DCGM host engine, fails on `nvidia-dcgm:5555` and restarts (3 times on the L4, about 3 min on the H200) | Exporter restart counts mean nothing on a fresh node | Alerts on exporter restarts must ignore a node's first minutes | [L4 acceptance](artifacts/par/acceptance-20261021T165702Z.txt) |
| dcgm-exporter 4.8.4 | `DCGM_FI_PROF_PCIE_TX/RX_BYTES` are gauges in bytes per second, not counters as Part 1 declared | Wrong rates | Declared as gauges | [values](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/gitops/values/base/gpu-operator.yaml) |
| KAI v0.18.6 | On a node with `nvidia.com/mig.strategy=mixed`, any non-MIG task gets a fit error, though the GPU Operator still advertises the whole GPU | MIG slices and whole GPUs can't share a node | Split per node (ADR 0008) | [capture](artifacts/scheduling/mig-whole-gpu-fin-20261022T102435Z.txt) |
| KAI | Highest tags v0.20.0 and v0.20.1 were retracted | "Newest" would install a withdrawn release | Pinned v0.18.6 from KAI's support policy | |

## Providers

| Component | Finding | Impact | What I did | Evidence |
|---|---|---|---|---|
| Verda H200 | Both GPUs run with ECC off, so `dcgmi diag -r 2` skips its memory test and still says PASS | My gate passed the node without a memory check | The gate now checks ECC first and refuses a skipped test (ADR 0004) | [node state](artifacts/fin/w2-final-20261022T102719Z.txt), [diag log](artifacts/readiness/diag-fin-20261022T101241Z.log) |
| Verda images | "Ubuntu 26.04 + CUDA 13.4 Open" ships driver 580.178.04 (`nvidia-driver-580-server-open`); the API has no driver field | Two driver branches across sites | Booted it on a CPU instance to read it; ADR 0002 | [inventory](artifacts/fin/image-inventory-20261020T075300Z-rehearsal.txt) |
| Verda API | Deleted instances' volumes stay listed `detached` for 20 to 40 s | The sweep reported volumes about to disappear | `make fin-down` waits for the volumes | [sweep](artifacts/fin/rehearsal-20261020-sweep.txt) |
| Verda API + Terraform 1.1.4 | An order went to status `error`, then `discontinued`, with no charge; the provider kept a tainted ghost in the state | `fin-down` refused to plan | Removed from the state by hand after the API confirmed it gone | [preflight](artifacts/fin/preflight-20261021T121643Z.json) |
| Verda Terraform 1.1.4 | Leaves the OS volume to the API's default (before 1.1.4, destroy left volumes billing, [issue #17](https://github.com/verda-cloud/terraform-provider-verda/issues/17)) | Possible billing leftovers | `fin-down` deletes through the API with the volume IDs | |
| Scaleway | PLAY2-MICRO costs €0.055/h, not "about 4 cents" as in Part 1 | First budget too low | Budget corrected (about €0.065/h with its disk) | [prices](artifacts/par/scaleway-prices-20261020.json) |

## Kubernetes, Argo CD and charts

| Component | Finding | Impact | What I did | Evidence |
|---|---|---|---|---|
| kubelet | `serializeImagePulls: true` by default: a 90 MB image waited 5 min behind 13 GB of pre-pulls | The first H200 acceptance timed out on a healthy node | Small images first, or parallel pulls; reran: PASS | [first run](artifacts/fin/acceptance-20261022T095659Z.txt), [rerun](artifacts/fin/acceptance-20261022T100225Z.txt) |
| Kubernetes | A powered-off node keeps every DaemonSet one pod short | kube-prometheus-stack and the root app stuck Progressing | `make par-cpu-down` deletes the Node object; `par-cpu-up` restores labels | |
| containerd | Part 1 never pinned it; the same script later got 2.4.2, outside GPU Operator v26.7's 2.0 to 2.3 range | Silent upgrade into an unsupported version | Pinned 2.3.6 | [node facts](artifacts/par/control-plane-facts.txt) |
| Argo CD v3.5.3 | Adds delete-hook finalizers to child Applications | The root app showed OutOfSync forever | Root ignores those finalizers | [root.yaml](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/gitops/sites/par/root.yaml) |
| Kubeflow Trainer 2.2.1 | Its chart renders webhook Secrets empty; self-heal wiped the certificates every 5 min | Controllers kept reissuing certificates | Ignore `/data` on those Secrets | |
| Grafana (kube-prometheus-stack) | A 384Mi limit made the kernel re-read Grafana's binary: 89 GB of disk reads, etcd slowed, about 20 controllers lost leases | API server unavailable for minutes | Limit 1Gi: I/O pressure from 85% to 1% | [evidence](artifacts/par/control-plane-io-20261021.txt) |
| kube-prometheus-stack 91.4.1 | Silently drops everything but `existingSecret.name` and `key` from the sidecar's bucket config | First overlay rendered with no bucket | Secret written at sync wave -1 | `templates/prometheus/prometheus.yaml` |
| Slurm chart 1.2.3 | Generates keys with Helm `lookup`, which Argo CD doesn't run | New keys on every sync | An in-cluster Job creates them once | |
| Slinky 1.2.3 | Under `RollingUpdate`, the pod-cordon drain undoes itself 1 s later (upstream PR 271) | Kubernetes maintenance didn't drain Slurm | NodeSet `OnDelete` | [first run](artifacts/scheduling/slurm-par-20261021T115447Z.txt), [rerun](artifacts/scheduling/slurm-par-20261021T121647Z.txt) |
| fake-gpu-operator, KWOK | The fake operator can't share a node with the real GPU Operator; neither ships a nodeSelector; KWOK nodes raise `TargetDown` | Fake GPUs on real nodes break; controllers on the 4 vCPU control plane | KWOK nodes only, pinned to the CPU worker, kubelet targets dropped | [what is simulated](simulated.md) |
| KubeVirt v1.9.1 | Pinning virt-operator by digest doesn't pin virt-template components (Beta gate on by default, own release v0.2.3) | Two components ran from tags | Both pinned via their `*_IMAGE` variables | [capture](artifacts/platform/kubevirt-20261021T103649Z.txt) |

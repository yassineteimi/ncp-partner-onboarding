# Day 0: which versions go together, per hardware class

!!! abstract "The use case"
    In Part 1 I pinned every version of the GPU stack by hand (GPU Operator, driver, DCGM,
    NFD, scheduler, monitoring) and checked each pin against its release notes. NVIDIA's
    AI Cluster Runtime (AICR) offers the other way: version-locked recipes, tested
    together, rendered for Argo CD, with a validator that checks a live cluster against
    them. Here I compare the two on the same stack: I asked AICR for Nordhaven's two GPU
    pools and set its answer beside what they run.

!!! success "Ran 20 to 22 October 2026"
    AICR has no recipe for either pool as it is built: the L4 and kubeadm are unknown
    to it, and every H200 recipe requires Ubuntu 24.04 where the Finland image is 26.04.
    So AICR became the reference for the H200 pool, not its installer
    ([ADR 0003](adr/0003-known-good-stack.md)). Its drift check missed a version I changed
    by hand; Argo CD undid the same change in 11 seconds.

## What AICR v1.1.0 offers Nordhaven

For the training pool, three H200 recipes on Ubuntu resolve: `eks`, `eks` with Kubeflow,
and `k0s`. None is ours. `k0s` is the closest, because it's the only one that leaves the
driver to the host as the Finland provider's image does; but its container toolkit points
at k0s's containerd, and every one of them insists on Ubuntu 24.04.

For the inference pool there's nothing to compare: AICR rejects `l4` as an accelerator
and `kubeadm` as a service outright, and the `generic` service it offers for self-managed
clusters only has a GB300 recipe.

```{ .sh .terminal }
$ make aicr-recipe
...
eks-h200-training      exit=0  aicr recipe --service eks --accelerator h200 --os ubuntu --intent training
eks-h200-kubeflow      exit=0  aicr recipe --service eks --accelerator h200 --os ubuntu --intent training --platform kubeflow
k0s-h200-training      exit=0  aicr recipe --service k0s --accelerator h200 --os ubuntu --intent training
# What we run, or the closest names to it, refused:
kubeadm-h200           exit=2  aicr recipe --service kubeadm --accelerator h200 --os ubuntu --intent training
    [cli] command failed: error=[INVALID_REQUEST] error parsing criteria: [INVALID_REQUEST] invalid service type: kubeadm exitCode=2
generic-h200           exit=2  aicr recipe --service generic --accelerator h200 --os ubuntu --intent training
...
```

Full output: [recipes-summary.txt](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/recipes-summary.txt).

So AICR is Nordhaven's reference for the H200 pool, not its installer, and the L4 keeps
Part 1's hand-pinned values. [ADR 0003](adr/0003-known-good-stack.md) has the reasoning
and the full version table; the short version:

| | Same as AICR | Newer than AICR | AICR behind what Nordhaven needs |
|---|---|---|---|
| Nordhaven (the Finland pool; NVSentinel runs in Paris) | GPU Operator v26.7.2, NFD 0.19.0, NVSentinel v1.28.0 | kube-prometheus-stack 91.4.1, driver 580.178.04, KAI v0.18.6 | cert-manager 1.20.2 (NVSentinel asks for 1.21), Kubeflow Trainer 2.2.0 (NVCRE needs 2.2.1) |

## The bundle

`aicr bundle --deployer argocd` turns the `k0s` recipe into eleven Argo CD Applications
under an app of apps. I kept it as evidence, untouched and checked against its own
checksums ([listing](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/bundle-argocd.txt)),
and synced none of it: in Finland it would install a second GPU Operator, NFD and
Prometheus beside the ones the base platform runs.

## Drift: AICR missed it

On 21 October in Paris, with Argo CD paused for the one Application: a snapshot, NVCRE's
controller set back from v0.8.0 to v0.7.0 by hand, a second snapshot and `aicr diff`
between them; then Argo CD resumed and a third snapshot
([every command with its time](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/drift-demo-par.txt)).

| UTC | What happened |
|---|---|
| 10:52:54 | Snapshot 1 |
| 10:54:02 | Argo CD paused for `nvcre` (`skip-reconcile`) |
| 10:54:15 | `kubectl set image` to `manager:v0.7.0`. The new pod crashlooped on `unknown flag: --namespace-access-timeout`, a flag the v0.8.0 chart passes; the rolling update kept the v0.8.0 pod serving |
| 10:57:37 | Snapshot 2 and `aicr diff`: "DRIFT DETECTED", 16 changes, every one a runtime counter (sysctl, a random UUID, containerd and kubelet memory). The image change isn't among them |
| 10:57:54 | Argo CD resumed |
| 10:58:05 | v0.8.0 back, 11 seconds later; the v0.7.0 pod gone |
| 10:58:12 | Snapshot 3 and `aicr diff`: 15 changes, again only counters |

```{ .sh .terminal }
$ make aicr-drift SITE=par
[cli] snapshot diff complete: added=0 removed=0 modified=16
CHANGES (0 added, 0 removed, 16 modified)
KIND      PATH                                        BASELINE                              TARGET
----      ----                                        --------                              ------
...
MODIFIED  OS.sysctl./proc/sys/kernel/ns_last_pid      46758                                 51647
MODIFIED  OS.sysctl./proc/sys/kernel/random/uuid      fdc5589e-a70c-4fbd-9b2b-bea2a5fb7e05  15a9f270-204f-40c3-a2ae-da8657512bd6
MODIFIED  SystemD.containerd.service.CPUUsageNSec     161826597000                          183748188000
...
MODIFIED  SystemD.kubelet.service.MemoryPeak          91459584                              98009088

DRIFT DETECTED
```

Full output: [diff-par-20261021T105737Z.txt](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/diff-par-20261021T105737Z.txt).

Why it missed the change: AICR's snapshot keeps one `name: tag` per image's last path
segment. An image pinned by digest, as everything in this repository is, has no tag and
reads `latest`, and the two pods were both called `manager`, so the inventory had one
entry for them. A version change on a digest-pinned workload doesn't show, and what does
show is buried in counters that change every second.

So on a GitOps cluster `aicr diff` isn't Nordhaven's drift detector: Argo CD found and
undid the same change in 11 seconds. It stays useful for what Git doesn't own, the node's
OS, kernel and services, provided someone filters the counters out first. In Paris it
couldn't read the kernel configuration at all: the image has no `/boot/config-*`.

## Validation of the Finland pool

On 22 October I took a snapshot of the Finland H200 node and ran `aicr validate` against
the `k0s` H200 training recipe. It never reached the deployment checks. Its readiness
pre-flight passed Kubernetes and the OS family, then stopped on the Ubuntu release:

```{ .sh .terminal }
$ make aicr-validate SITE=fin
...
[cli] readiness pre-flight: constraints=3
[cli] readiness constraint passed: name=K8s.server.version expected=>= 1.34 actual=v1.36.5
[cli] readiness constraint passed: name=OS.release.ID expected=ubuntu actual=ubuntu
[cli] command failed: error=[INVALID_REQUEST] readiness check failed: OS.release.VERSION_ID expected 24.04, got 26.04 exitCode=2
aicr validate exit=2 (2 = readiness pre-flight failed)
```

Full output: [validate-fin-20261022T101408Z.log](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/validate-fin-20261022T101408Z.log).

That's the refusal I expected, and it's the whole result: AICR can tell Nordhaven that
the Finland node isn't the OS it tested, not whether its components match. The version
table above, built by hand, is still the comparison. As in Paris, the snapshot couldn't
read the kernel configuration ([snapshot](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/snapshot-fin-20261022T101356Z.yaml)).

## What was simulated

Nothing. The recipes, the refusals, the bundle and the validation are AICR's real output
against the real clusters; the drift was a real image change, made by hand on purpose.

## What this can't show

AICR building a cluster: nothing here was installed from a recipe. And one H200 node is
one data point for a recipe meant for fleets.

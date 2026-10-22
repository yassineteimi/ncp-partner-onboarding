# Day 0: which versions go together, per hardware class

!!! abstract "The use case"
    Before a pool takes any work, EU1 needs one answer to "which GPU Operator, driver,
    DCGM, NFD and scheduler versions are known to work together on this hardware".
    NVIDIA's AI Cluster Runtime (AICR) gives that answer as a version-locked recipe,
    renders it for Argo CD and checks a live cluster against it. I asked it for EU1's two
    pools and compared its answer with what they run.

!!! success "Done"
    The recipes, the refusals, the version comparison and the drift demo ran on 20 and 21
    October, and the validation of fin against the recipe in W2 on 22 October.

## What AICR v1.1.0 offers EU1

For the training pool, three H200 recipes on Ubuntu resolve: `eks`, `eks` with Kubeflow,
and `k0s`. None is ours. `k0s` is the closest, because it's the only one that leaves the
driver to the host as Verda's image does; but its container toolkit points at k0s's
containerd, and every one of them insists on Ubuntu 24.04 where fin's image is 26.04.

For the inference pool there's nothing to compare: AICR rejects `l4` as an accelerator
and `kubeadm` as a service outright, and the `generic` service it offers for self-managed
clusters only has a GB300 recipe ([summary](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/recipes-summary.txt)).

So AICR is EU1's reference for the H200 pool, not its installer, and the L4 keeps Part 1's
hand-pinned values. [ADR 0003](adr/0003-known-good-stack.md) has the reasoning and the
full version table; the short version:

| | Same as AICR | Newer than AICR | AICR behind what EU1 needs |
|---|---|---|---|
| EU1 (fin; NVSentinel runs on par) | GPU Operator v26.7.2, NFD 0.19.0, NVSentinel v1.28.0 | kube-prometheus-stack 91.4.1, driver 580.178.04, KAI v0.18.6 | cert-manager 1.20.2 (NVSentinel asks for 1.21), Kubeflow Trainer 2.2.0 (NVCRE needs 2.2.1) |

## The bundle

`aicr bundle --deployer argocd` turns the `k0s` recipe into eleven Argo CD Applications
under an app of apps. I kept it as evidence, untouched and checked against its own
checksums ([listing](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/bundle-argocd.txt)),
and synced none of it: on fin it would install a second GPU Operator, NFD and Prometheus
beside the ones the base platform runs.

## Drift: AICR missed it

On 21 October on par, with Argo CD paused for the one Application: a snapshot, NVCRE's
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

Why it missed the change: AICR's snapshot keeps one `name: tag` per image's last path
segment. An image pinned by digest, as everything in this repository is, has no tag and
reads `latest`, and the two pods were both called `manager`, so the inventory had one
entry for them. A version change on a digest-pinned workload doesn't show, and what does
show is buried in counters that change every second.

So on a GitOps cluster `aicr diff` isn't EU1's drift detector: Argo CD found and undid
the same change in 11 seconds. It stays useful for what Git doesn't own, the node's OS,
kernel and services, provided someone filters the counters out first. On par it couldn't
read the kernel configuration at all: the image has no `/boot/config-*`.

## Validation on fin

In W2 I took a snapshot of fin's H200 node and ran `aicr validate` against the `k0s` H200
training recipe. It never reached the deployment checks. Its readiness pre-flight passed
Kubernetes (v1.36.5 against ">= 1.34") and the OS family, then stopped:

```text
readiness check failed: OS.release.VERSION_ID expected 24.04, got 26.04
```

That's the refusal I expected, and it's the whole result: AICR can tell EU1 that fin
isn't the OS it tested, not whether fin's components match. The version table above,
built by hand, is still the comparison. As on par, the snapshot couldn't read the
kernel configuration ([validation log](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/validate-fin-20261022T101408Z.log),
[snapshot](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/aicr/snapshot-fin-20261022T101356Z.yaml)).

## What this can't show

AICR building a cluster: nothing here was installed from a recipe. And one H200 node
is one data point for a recipe meant for fleets.

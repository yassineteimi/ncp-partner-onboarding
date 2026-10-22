# ADR 0003: AICR as the known-good reference for the H200 pool, hand-pinned values for the L4

Status: accepted
Scope: GPU stack versions, Finland H200 pool and Paris L4 pool. Decided after the H200 run, 22 October 2026.

## Context

Nordhaven needs one answer per hardware class to "which versions of the GPU stack go
together": operator, driver, DCGM, NFD, scheduler, monitoring. Part 1 pinned each version
by hand in Git and checked them against each component's release notes. NVIDIA's AI
Cluster Runtime (AICR) generates version-locked recipes per service, accelerator, OS and
intent, renders them for Argo CD, and validates a cluster against them. Nordhaven's two
pools are a 2× H200 node on Verda in Finland and an L4 on Scaleway in Paris, both on
self-managed kubeadm.

## Options considered

| Option | What it is | For Nordhaven | Against, for Nordhaven |
|---|---|---|---|
| A. AICR v1.1.0 deploys the H200 pool | Its Argo CD bundle replaces the Finland site's base platform | One NVIDIA-tested set of versions, installed as tested | No recipe matches the Finland node (below); the bundle brings a second GPU Operator, NFD and Prometheus next to the base platform's, plus KAI, the DRA driver and NodeWright, all of which would have to be reconciled with what already runs there |
| B. AICR as the reference, hand-pinned values deploy | The Finland site keeps its base platform; AICR's recipe is rendered and kept, compared version by version, and `aicr validate` runs against the live cluster | The known-good set is NVIDIA's, the deployment stays one Argo CD tree Nordhaven already runs and understands | Two sources of versions to keep in step by hand; drift between them is a review task, not a sync |
| C. Hand-pinned only, as in Part 1 | Each version pinned and checked against release notes | No new tool | Every combination is Nordhaven's own research, per hardware class |

AICR at v1.1.0 doesn't have a recipe for what Nordhaven runs, which is what limits
option A:

| Query (`aicr recipe ...`) | Result |
|---|---|
| `--service kubeadm --accelerator h200` | Refused: `invalid service type: kubeadm` |
| `--service generic --accelerator h200 --os ubuntu --intent training` | Refused: `generic` exists for self-managed clusters but only with GB300 |
| `--service metal3`, `kind`, `bcm` with H200, Ubuntu, training | Refused: no such recipe |
| `--service eks` or `k0s` with H200, Ubuntu, training | Resolves; `k0s` is the only one that leaves the driver to the host, as Verda's image does, but its container toolkit points at k0s's containerd |
| `--accelerator l4` with any service | Refused: `invalid accelerator type: l4` |
| Every recipe that resolves | Constrains Ubuntu to `24.04`; the Finland image is 26.04 |

## Decision

B for the H200 pool, C for the L4. AICR's recipe is the reference that the Finland
versions are checked against, and `aicr validate` runs against the Finland node; nothing
from the bundle syncs. The L4 keeps Part 1's hand-pinned values, with AICR's resolved
versions as the reference where the two overlap, because AICR covers neither the L4 nor
kubeadm.

What would change it: a `kubeadm` or `generic` H200 recipe, or Ubuntu 26.04 support,
would make A worth a trial; an L4 entry would bring the Paris pool under the same
reference.

## Consequences

Where the Finland pool and the reference stand (its versions from the Argo CD
Applications in Git; AICR's from the `k0s` H200 training recipe):

| Component | AICR v1.1.0 | Finland | Action |
|---|---|---|---|
| GPU Operator | v26.7.2 | v26.7.2 | Aligned |
| NFD | 0.19.0 | 0.19.0 | Aligned |
| Driver | host-owned in the `k0s` recipe (the `eks` one pins 580.173.02) | 580.178.04, from Verda's image | Same branch, newer patch; ADR 0002 owns the driver |
| kube-prometheus-stack | 84.4.0 | 91.4.1 | Newer here; kept, since the cross-site metrics rely on it |
| cert-manager | v1.20.2 | not in Finland; v1.21.2 in Paris | AICR's pin is below the 1.21 that NVSentinel v1.28.0's README asks for |
| NVSentinel | v1.28.0 | not in Finland; v1.28.0 in Paris | Aligned where it runs |
| KAI Scheduler | v0.16.9 | v0.18.6 | Chosen in ADR 0006 |
| Kubeflow Trainer | 2.2.0, namespace `kubeflow` (the `eks` Kubeflow recipe) | 2.2.1, `kubeflow-system` | NVCRE v0.8.0 needs exactly 2.2.1; AICR's would break it |
| DRA driver, NodeWright, prometheus-adapter | 0.5.0, v0.20.0, 5.3.0 | not deployed | Out of scope for this PoC |

- Nordhaven gets NVIDIA's view of which versions go together without handing its
  deployment to a recipe that doesn't fit its hardware or OS. The cost is this table: it
  has to be redone when either side moves, and it's only as current as the last time
  someone ran `make aicr-recipe`.
- Two of the differences are AICR being behind what Nordhaven's other components need
  (cert-manager, Kubeflow Trainer). They go in the findings, not into the Finland pool.
- `aicr diff` isn't Nordhaven's drift detector for what Git owns. In Paris it missed a
  hand-made version change (NVCRE v0.8.0 to v0.7.0): its snapshot keeps one `name: tag`
  per image's last path segment, so a digest-pinned image reads `latest`, and real
  changes are buried in runtime counters. Argo CD found and undid the same change in 11
  seconds. AICR's snapshot stays useful for what Git doesn't own (OS, kernel, services),
  once the counters are filtered.
- `aicr validate` against the Finland node stopped at its readiness pre-flight, as
  expected: Kubernetes v1.36.5 and the Ubuntu ID passed, and `OS.release.VERSION_ID`
  failed, 26.04 against the recipe's 24.04. No deployment check ran after that, so the
  version table above remains the comparison, done by hand. AICR also couldn't read the
  node's kernel configuration, as in Paris.
- What this can't show: AICR as a deployer. The validation checks the Finland node
  against the recipe; it doesn't prove the recipe would have built it.

## Evidence

- The use case 1 page: [10-day0-aicr.md](../10-day0-aicr.md).
- Recipes, refusals and the summary: `docs/artifacts/readiness/aicr/` (`make aicr-recipe`);
  the Finland snapshot and validation log: `aicr/snapshot-fin-20261022T101356Z.yaml` and
  `aicr/validate-fin-20261022T101408Z.log`.
- AICR at v1.1.0: `pkg/recipe/criteria.go` (accepted services and accelerators),
  `pkg/recipe/coverage.go` (no fallback), `recipes/mixins/os-ubuntu.yaml` (Ubuntu 24.04),
  `recipes/components/gpu-operator/values.yaml` (driver 580.173.02, "the exact measured
  baseline" for EFA).

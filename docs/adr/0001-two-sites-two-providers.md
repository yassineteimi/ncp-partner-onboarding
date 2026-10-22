# ADR 0001: Two sites on two providers, one repository

Status: accepted
Scope: both sites, the bootstrap and GitOps layout. Use case: all.

## Context

Nordhaven has two pools with different jobs: L4s for inference and development, and
H200s with NVLink for training. A real partner rarely gets both from one building, and
what usually differs between its sites is the layer underneath: networking, firewalls,
images, who installs the driver. I wanted the project to meet those differences rather
than avoid them, while keeping one way to bootstrap and operate both pools. Cost decides
the rest: the H200s can only exist while they're in use.

## Options considered

| Option | What it is | For Nordhaven | Against, for Nordhaven |
|---|---|---|---|
| A. One site, one provider | Both pools on Scaleway in Paris, one cluster | One network, one firewall model, one bill. Part 1's setup almost unchanged | The bootstrap and GitOps never meet a second provider, which is the part a multi-site partner actually has to solve. Nothing about metrics or readiness has to cross a site boundary |
| B. Two sites, two providers, one repository | Paris on Scaleway (L4, persistent control plane), Finland on Verda (2× H200 SXM5), each a kubeadm cluster with its own ArgoCD reading the same repository | The same scripts, versions and Git layout on both; the provider differences show up as small, named overlays. Verda rents a 2× H200 NVLink node by the hour, billed in 10-minute blocks | Two firewall models, two image catalogs, metrics that cross the internet, and a site that has to be built from zero in minutes every time |
| C. One cluster stretched across both sites | A single control plane in Paris, the H200 node joining over the internet | One API, one scheduler view of every GPU | Kubelet, etcd-adjacent traffic and the pod network over the public internet; a Paris outage stops Finland's training. No partner would run a production cluster like this |

## Decision

B. Each site is its own cluster, both built by the same bootstrap from the same
repository, with the provider differences kept in per-site files: `terraform/par` and
`terraform/fin`, `gitops/apps/par` and `gitops/apps/fin`, and `-par`/`-fin` values
overlays. The one thing that crosses sites is metrics, over Thanos remote write with
mutual TLS ([ADR 0009](0009-metrics-across-sites.md)).

This would change for a partner whose sites share a private backbone: then a single
metrics store without remote write, or even a stretched cluster for CPU-only services,
becomes reasonable.

## Consequences

- Verda has no private network and no cloud firewall, so the Finland nodes run nftables
  from their startup script; Paris uses Scaleway security groups and a Private Network.
  Same bootstrap, two firewall paths.
- The provider decides who installs the GPU driver on each site, and the two sites end
  up on different driver branches ([ADR 0002](0002-driver-ownership.md)).
- The Finland site is rebuilt from nothing for every GPU run. On 22 October its control
  plane came up in about 3.5 minutes and the H200 node went from order to two
  schedulable GPUs in 2 minutes 49 seconds.
- Capacity isn't guaranteed. At 11:19 Paris on 22 October Verda had no H200 of any size
  in any location; one appeared in FIN-02 at 11:46. A partner plans around the same
  problem with reservations; here a poll and a pre-approved spot fallback stood in.
- Two bootstrap paths mean two sets of bugs. Two of them only showed on the real H200
  run, because the CPU-only tests of the Finland site skip those code paths
  ([findings](../findings.md)).

## Evidence

- Bring-up timelines: [control plane](../artifacts/fin/cp-bringup-20261022T094702Z.txt),
  [H200 node](../artifacts/fin/gpu-bringup-20261022T095203Z.txt).
- Availability log: [h200-availability.csv](../artifacts/fin/h200-availability.csv);
  the refused and passing preflights: `docs/artifacts/fin/preflight-20261022T*.json`.
- Firewalls: `terraform/par/network.tf`, `terraform/par/cpu-worker.tf`,
  `terraform/fin/startup/node.sh.tftpl`.

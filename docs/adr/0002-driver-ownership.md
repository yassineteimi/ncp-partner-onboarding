# ADR 0002: Who owns the GPU driver: the GPU Operator or the provider image

Status: accepted
Scope: GPU driver lifecycle on both sites. Use cases: 1, 2.

## Context

Part 1's main result was a driver that comes from Git: the L4 boots with no driver, the
GPU Operator installs the version pinned in its values, and an upgrade is a commit.
Verda's GPU images arrive with a driver already installed and loaded.
"Ubuntu 26.04 + CUDA 13.4 Open" (`26.04.cuda13.4`) ships 580.178.04, from the R580 server
branch, while Paris runs 595.91.07. Whoever installs the driver also owns its upgrades,
its kernel module builds and the blame when they break, so this has to be decided per
site, not per cluster component.

## Options considered

| Option | What it is | For Nordhaven | Against, for Nordhaven |
|---|---|---|---|
| A. GPU Operator everywhere | Boot a driverless image on Finland too (`26.04.base`) and let the operator build 595.91.07 there | One driver branch and one upgrade path on both sites, from Git | Never tested on Verda's H200 VMs, and the first test would cost H200 time: a driver container building against kernel 7.0 on a passthrough VM, with fabric-manager questions on an NVLink machine. The provider supports its own image on that hardware, not mine |
| B. Provider image everywhere | Use each provider's GPU image and turn the operator's driver off on both sites | No driver build on any node | Scaleway's L4 path in Part 1 had no driver in the image, and moving Paris off the operator gives up the driver-from-Git result Part 1 was built on |
| C. Per site: the owner of the image owns the driver | Paris: the operator installs 595.91.07 from Git. Finland: the image's 580.178.04, with `driver.enabled=false` and the packages held | Each driver stays with whoever supports it on that hardware; no H200 time spent on driver builds | Two branches in one fleet: CUDA images and tests must suit 580 on Finland |
| D. Upgrade the provider's driver by hand | Keep Verda's image and install 595 over it at boot | One branch | A driver nobody owns: neither Git nor the provider. That's the drift Part 1 set out to remove |

## Decision

C. The owner of the image owns the driver, and the driver owner picks the branch. On
Paris the GPU Operator installs 595.91.07, pinned in `gitops/values/base/gpu-operator-par.yaml`.
On Finland the operator runs with its driver component off, the bootstrap fails within a
minute of boot if the image's driver doesn't see both GPUs, and it holds the NVIDIA
packages with `apt-mark hold` so nothing upgrades them during a run.

I'd revisit A if Verda published a driverless H200 image it supports, or if Nordhaven
needed one driver branch across the fleet for a certification or a support contract.

## Consequences

- Two driver branches in one fleet. Anything built for a newer driver has to be checked
  against 580 on Finland. NVCRE's `pytorch:26.01-py3` image ran there through CUDA
  compatibility; how it did is in the [findings](../findings.md).
- The acceptance test on Finland checks the driver the image reported at boot, not a
  version in Git. Paris's check compares against Git, as in Part 1.
- AICR's H200 recipe assumes its own driver and OS choices; the comparison is on the
  [Day 0 page](../10-day0-aicr.md).
- On the H200 node the provider's choices come along with its driver. On 22 October ECC
  was off on both GPUs, which the readiness gate now refuses
  ([ADR 0004](0004-readiness-gate.md)).

## Evidence

- Image inventory at boot, with the driver, NVLink and fabric-manager state:
  [image-inventory-20261022T095649Z.txt](../artifacts/fin/image-inventory-20261022T095649Z.txt).
- Acceptance on the H200: [acceptance-20261022T100225Z.txt](../artifacts/fin/acceptance-20261022T100225Z.txt);
  on the L4: `docs/artifacts/par/acceptance-20261021T165702Z.txt`.
- Bootstrap driver check and package hold: `terraform/fin/startup/node.sh.tftpl`.

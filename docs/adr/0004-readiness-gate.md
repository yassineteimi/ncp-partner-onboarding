# ADR 0004: NVCRE certification behind a staging taint as the readiness gate

Status: accepted, after W2 on 22 October (proposed 21 October)
Date: 2026-10-22. Owner: ws-readiness. Use case: 2.

## Context

A GPU node EU1 receives from a provider shouldn't take a tenant's job until something
has shown it works: GPUs talk to each other at the speed the hardware promises, and the
diagnostic finds nothing. Part 1 proved an L4 with burn-in scripts and a runbook that a
person ran; nothing stopped a tenant scheduling there in the meantime. EU1's training
pool is 2× H200 per node, rented by the hour, so the check has to be short, and it has to
block scheduling until it passes.

## Options considered

| Option | What it is | For EU1 | Against, for EU1 |
|---|---|---|---|
| A. NVCRE v0.8.0 behind a staging taint | NVIDIA's Cluster Readiness Engine runs catalog categories (NCCL collectives, NVLink loopback, DCGM level 4, training) as TrainJobs and writes a results file; the node joins tainted and a small gate removes the taint on a pass | NVIDIA's own sizing and NCCL tuning per architecture; one results format for every pool and site; multi-node categories ready for when EU1 has more than one node; tolerations injected for the staging taint | Doesn't fit a 2-GPU H200 or an L4 out of the box (gpusPerNode, no L4 entry); ships no thresholds; its only DCGM category runs about 90 minutes; never taints or promotes, so the gate is mine; releases weekly |
| B. Part 1's burn-in and runbook | `dcgmi diag -r 3`, three hours of tensor load, a stability record, and a handover checklist run by a person | Proven on the L4, criteria written before the run, catches thermal and stability faults a short test misses | A person in the loop, three hours per node, nothing blocks scheduling while it runs, no interconnect test at all |
| C. My own gate from upstream tools | A Job running nccl-tests' `all_reduce_perf` and `dcgmi diag`, and a script reading their output | Small, no CRDs, exactly the categories I want | I'd own per-architecture sizing and NCCL settings, the output parsing and a results format, for every GPU type EU1 adds |

## Decision

A, with two additions of mine: the staging taint at join, and `dcgmi diag -r 2` beside
the certification, because NVCRE's DCGM category is level 4 only and 90 minutes doesn't
fit a window shared with other work. What decided it is that NVCRE carries the
per-architecture knowledge (GPUs per node, NCCL environment, which loopback variant
crosses NVLink) that option C would make me maintain, and that its results file is the
same on every site, which is what a gate needs to read.

What would change it: a provider that hands over nodes already certified with NVCRE's
level 4 would let EU1 trust their report and keep only the short checks; and if NVCRE's
catalog ever gets a shorter DCGM level, the diagnostic moves inside it.

## Consequences

- The gate is code EU1 owns (`scripts/readiness/promote.py`, tested), because NVCRE
  deliberately leaves promotion to the platform. It tells hardware from tooling failures,
  so a broken test doesn't get read as a broken GPU.
- Thresholds are EU1's to set and justify. Without one, PASSED only means "ran". On fin
  the floor is 64 GB/s bus bandwidth, the most PCIe Gen5 can carry each way, which proves
  NVLink without pretending to be a performance target.
- Level 2 isn't level 4: no targeted power, no targeted stress, no nvbandwidth. Level 3
  runs when a window allows, and the use case 2 page says what was skipped.
- What one node can't show: the inter-node fabric and rack-scale NVLink that NVCRE's
  multi-node categories are built for, and the training categories (4 GPUs at least).

## What the windows showed

The gate worked as designed on both sites. fin's 2× H200 node went from Ready to open in
19 min 39 s, certified at 351 GB/s all-reduce bus bandwidth over NVLink, and the same
gate rehearsed on par's L4 the day before. Two things change how I'd run it:

- **A skipped test passed.** ECC is off on Verda's H200s, so DCGM skipped its memory test
  and still reported PASS, and the gate, which trusts DCGM's overall result, opened the
  node with no memory check. The gate now refuses with cause "unclear" when DCGM skips
  any test, and the diagnostic first records each GPU's current ECC mode (DCGM field
  300, read from the same host engine); a GPU with ECC off is refused as "unclear", and
  a missing record as "tooling". Fed the H200's diagnostic log unchanged, the gate now
  refuses that node. The ECC read itself hasn't run on a GPU yet.
- **NVCRE's summary can't be the record of the transport.** It printed
  `Transport: Socket` for a run that went over NVLink on every channel. The gate already
  reads the raw NCCL channel lines, which is why it wasn't misled; that stays a rule.

## Evidence

- Use case 2 page: [10-day1-nvcre.md](../10-day1-nvcre.md), with the W1 and W2 results.
- W2: `nvcre-fin-20261022T100307Z*`, `diag-fin-20261022T101241Z.log`,
  `promote-fin-20261022T101348Z.txt` in `docs/artifacts/readiness/`; the two findings in
  [findings.md](../findings.md).
- W1: `nvcre-par-20261021T172328Z*`, `diag-par-20261021T172533Z.log`,
  `promote-par-20261021T172554Z.txt`.
- NVCRE at v0.8.0: `pkg/catalog/entries/_lib/gpu-defaults.yaml` (8 GPUs for an H200),
  `docs/getting-started/first-certification.md` ("No thresholds ship by default"), the
  README ("NVCRE never cordons, taints, or otherwise modifies a node").
- Offline renders of the runs: `docs/artifacts/readiness/fc8-fc13-nvcre-render/`.
- The image and driver check: `docs/artifacts/readiness/fc11-pytorch-images.txt`.
- Part 1's burn-in: [session D](https://yassineteimi.github.io/nvidia-gpu-fleet-poc/04-goodput-and-burn-in/#the-burn-in).

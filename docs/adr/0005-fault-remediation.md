# ADR 0005: NVSentinel for GPU fault remediation

Status: proposed (the before and after numbers come from W1, 21 October)
Date: 2026-10-21. Owner: ws-readiness. Use case: 3.

## Context

When a GPU in EU1's fleet throws a fatal XID, the node has to leave service, its
workloads have to move, it has to be repaired and come back, with nobody paged at 3 a.m.
Part 1 did this on one L4 with node-problem-detector and a controller I wrote, and the
outage it measured (360.9 s) was 83% a lookback timer of mine and 11% a person who
hadn't yet run the return-to-service command. EU1 runs two GPU types on two providers,
so whatever it picks has to know GPU faults, not just node failures, and cost little to
operate per pool.

## Options considered

| Option | What it is | For EU1 | Against, for EU1 |
|---|---|---|---|
| A. NVSentinel v1.28.0 | NVIDIA's GPU fault pipeline: syslog and DCGM health monitors, quarantine, drain, remediation through a janitor with per-provider back ends, events in MongoDB | Knows GPU faults: NVIDIA's XID catalog decides reboot vs GPU reset vs "call support"; DCGM health watches catch faults the kernel log doesn't; the node returns by itself when the monitors report healthy; maintained, released weekly | Heavy for one node: MongoDB, cert-manager, seven Deployments and six DaemonSets with every stage on (two of them only for DCGM 3.x or Kata nodes). Its defaults assume a fleet (circuit breaker, a drain that never evicts) and had to be changed here. Weekly releases mean pinning and reading changelogs |
| B. Part 1's controller | node-problem-detector turns the XID line into a node condition; 369 lines of Python cordon and evict; a scripted, gated return to service | Small, and every line is mine to read; Part 1 tested it (42 tests) and measured it; the return runs `dcgmi diag` before uncordoning | I maintain the XID knowledge; a person runs the return; the five-minute lookback exists only because node-problem-detector replays old kernel lines after a restart; no DCGM path, no reboot or GPU reset |
| C. node-problem-detector, medik8s Node Healthcheck and Self Node Remediation | Generic: NPD sets a condition, Node Healthcheck v0.12.0 acts on conditions held for a set duration and hands the node to a remediation template, Self Node Remediation v0.13.0 reboots it in software or through a watchdog, no BMC needed | Vendor-neutral, covers every kind of node failure, with a `minHealthy`/`maxUnhealthy` guard against remediating half a cluster | Knows nothing about GPUs: every XID needs a hand-written NPD rule and a decision about what it means; remediation is node-level only (no GPU reset); conditions must hold for a duration before anything happens (300 s by default), so the timer Part 1 measured comes back by design; no drain policy per namespace |

## Decision

NVSentinel, for the GPU pools. Two things decided it. It carries NVIDIA's knowledge of
which XID needs what: XID 79 maps to a reboot, others to a GPU reset or to a human,
and that's knowledge B and C would make me write and keep current. And it closes the
loop with no person in it, which is where Part 1 lost 11% of its outage.

What would change the answer: a provider that already runs medik8s for its CPU fleet
would put NVSentinel's GPU knowledge in front of Node Healthcheck rather than run two
remediation stacks (NVSentinel's janitor has an external-remediation hook for that). And
on a single small node, B is honestly enough; NVSentinel's footprint pays off with a
fleet.

## Consequences

- EU1 now runs MongoDB (Percona, one member here) and cert-manager for its fault
  pipeline, and NVSentinel's control pods need somewhere to live that isn't a GPU node:
  on par, the CPU worker, which is powered off between windows, so NVSentinel only
  protects the L4 while that worker is on.
- The settings I changed are fleet decisions, not demo ones: on a real pool the circuit
  breaker stays on with an absolute cap, and the drain mode is chosen per namespace.
- A node comes back without a diagnostic unless post-remediation validation
  (lifecycle-manager) is turned on. I measured NVSentinel as shipped, so the use case 3
  page says what that leaves out.
- What one L4 can't show: the job can only resume on the node that failed; one
  simulated XID is not a fleet's fault mix; and the generic reboot is the only
  remediation exercised, since Scaleway exposes no API NVSentinel's janitor knows.

## Evidence

- Use case 3 page: [10-day2-nvsentinel.md](../10-day2-nvsentinel.md), results after W1.
- NVSentinel at v1.28.0: `health-monitors/syslog-health-monitor/pkg/patterns/xid.go`
  (XID pattern), `docs/circuit-breaker.md`, `distros/kubernetes/nvsentinel/charts/node-drainer/values.yaml`
  (drain modes), `janitor-provider/pkg/csp/generic/generic.go` (the reboot Job).
- Free checks: `docs/artifacts/readiness/fc2-journald-*.txt`, `fc3-kind-demo-*.txt`,
  `fc4-kind-par-values-*.txt`, `fc6-fc7-render-dryrun-*.txt`.
- Part 1: [session C](https://yassineteimi.github.io/nvidia-gpu-fleet-poc/03-fault-remediation/)
  and [session D](https://yassineteimi.github.io/nvidia-gpu-fleet-poc/04-goodput-and-burn-in/).
- medik8s: [node-healthcheck-operator](https://github.com/medik8s/node-healthcheck-operator)
  README and `docs/configuration.md` at v0.12.0 (default unhealthy conditions: Ready
  False or Unknown for 300 s), [self-node-remediation](https://github.com/medik8s/self-node-remediation)
  README.

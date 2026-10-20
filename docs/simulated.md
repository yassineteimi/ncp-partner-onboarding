# What is simulated

Every injected fault, simulated GPU or emulated VM in this project is listed here, and labelled again where it appears. If something isn't on this list, it ran on real hardware.

| What | Where it appears | Why it's simulated | Use case | Status |
|---|---|---|---|---|
| A second Prometheus on par posing as fin, with `site="fin-sim"` and `simulated="true"` on every series | Thanos on par, before the H200 window | It runs the whole fin-to-par metrics path, mTLS included, for free before a real fin site exists | 6 | planned |
| Synthetic blocks backfilled into the Thanos bucket, labelled `site="sim-backfill"` and `simulated="true"` | Thanos compactor, downsampling check | Downsampling needs blocks that span far more time than a two-hour window produces | 6 | planned |

The VM tenant of use case 7 is not on this list: the par CPU worker exposes `/dev/kvm` (AMD SVM, [node facts](artifacts/par/cpu-worker-facts.txt)), so KubeVirt runs it on KVM, with no software emulation.

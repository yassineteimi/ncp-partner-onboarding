# Findings

Things that didn't behave the way the documentation or my first assumption said, and what I changed because of them. One line each, with a link to the page or file that has the detail. Part 1's findings are on [its own page](https://yassineteimi.github.io/nvidia-gpu-fleet-poc/findings/).

## Platform

- **dcgm-exporter documents the PCIe byte fields as a rate.** Part 1 declared `DCGM_FI_PROF_PCIE_TX_BYTES` and `DCGM_FI_PROF_PCIE_RX_BYTES` as counters, copied from a commented-out line in `etc/default-counters.csv` at 4.6.0-4.8.3. The same file at [4.8.4](https://github.com/NVIDIA/dcgm-exporter/blob/4.8.4/etc/default-counters.csv), the exporter that GPU Operator v26.7.2 deploys, lists them only as gauges in bytes per second. The shared values now declare them as gauges ([`gitops/values/base/gpu-operator.yaml`](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/gitops/values/base/gpu-operator.yaml)).

# Findings

Things that didn't behave the way the documentation or my first assumption said, and what I changed because of them. One entry each, with a link to the evidence or the file that has the detail. Part 1's findings are on [its own page](https://yassineteimi.github.io/nvidia-gpu-fleet-poc/findings/).

## Verda

- **The image's name gives the CUDA release, not the driver.** "Ubuntu 26.04 + CUDA 13.4 Open" (`26.04.cuda13.4`) ships driver 580.178.04, which is Ubuntu's `nvidia-driver-580-server-open` built by DKMS, with `nvidia-fabricmanager-580` enabled. I had expected the 595 branch that par runs, partly because the confidential-computing variant of the same image says "driver 595" in its name. `/v1/images` has no driver field, so I booted the image on a $0.048/h CPU instance to read it ([inventory](artifacts/fin/image-inventory-20261020T075300Z-rehearsal.txt)). The two sites therefore run two driver branches, which is the trade ADR 0002 is about.
- **Deleting an instance doesn't delete its volumes at the same moment.** I passed both OS volume IDs in `volume_ids` with `delete_permanently: true`. The instances left `/v1/instances` within seconds; their volumes stayed listed as `detached` for another 20 to 40 seconds, then went. My leftover sweep ran inside that gap and reported two billing volumes that were about to disappear, so `make fin-down` now waits for the volumes too ([sweep afterwards](artifacts/fin/rehearsal-20261020-sweep.txt)).
- **Terraform provider 1.1.4 leaves the OS volume to the API's default.** Before 1.1.4, `terraform destroy` left every OS volume detached and billing ([issue #17](https://github.com/verda-cloud/terraform-provider-verda/issues/17)). The fix sends `volume_ids: null` and lets the API decide; and the resource's Read errors on an instance that no longer exists instead of dropping it from the state (`internal/provider/resource_instance.go` at v1.1.4). `make fin-down` deletes through the API with the IDs, then removes the instances from the state itself.

## Node bootstrap

- **Part 1 never pinned containerd, and it moved.** Part 1's bootstrap installed whatever `containerd.io` Docker's repository had, which was 2.3.5 and then 2.3.6. Three weeks later the same script got 2.4.2, a release GPU Operator v26.7.x doesn't list: its platform page validates containerd 2.0 to 2.3. I pinned 2.3.6 and rebuilt par's control plane while it was still empty ([node facts](artifacts/par/control-plane-facts.txt)).

## Kubernetes and ArgoCD

- **A powered-off node keeps every DaemonSet one pod short.** I power par's CPU worker off between uses so it stops billing. Left in the cluster as a NotReady node, it held flannel, kube-proxy and node-exporter at one pod of two, and that kept kube-prometheus-stack, and the root Application above it, at Progressing until the worker came back. `make par-cpu-down` now deletes the Node object after the drain. The kubelet still has its credentials on disk and registers the node again on power-on, and `make par-cpu-up` puts its labels back.

## GPU Operator and DCGM

- **dcgm-exporter documents the PCIe byte fields as a rate.** Part 1 declared `DCGM_FI_PROF_PCIE_TX_BYTES` and `DCGM_FI_PROF_PCIE_RX_BYTES` as counters, copied from a commented-out line in `etc/default-counters.csv` at 4.6.0-4.8.3. The same file at [4.8.4](https://github.com/NVIDIA/dcgm-exporter/blob/4.8.4/etc/default-counters.csv), the exporter that GPU Operator v26.7.2 deploys, lists them only as gauges in bytes per second. The shared values now declare them as gauges ([`gitops/values/base/gpu-operator.yaml`](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/gitops/values/base/gpu-operator.yaml)).

## Scaleway

- **PLAY2-MICRO costs €0.055 an hour, not "about 4 cents".** Part 1's prerequisites page carried the lower figure, and my first budget for this project used it. Scaleway's API read 0.05508 in fr-par-1 and fr-par-2 on 20 October ([prices](artifacts/par/scaleway-prices-20261020.json)). With its 80 GB disk the always-on control plane comes to about €0.065 an hour, or €11 a week.

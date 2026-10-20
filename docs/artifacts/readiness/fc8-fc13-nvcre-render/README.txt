# FC8 and FC13: NVCRE v0.8.0 renders, offline, 2026-10-20 on the laptop
#
# nvcrectl v0.8.0 (darwin-arm64, checksum OK against the release's checksums.txt)
#   certification render --platform onprem --gpu-arch h200  workloads/readiness/certification-fin.yaml
#   certification render --platform onprem                  workloads/readiness/certification-par.yaml
#   workloadrun render   --platform onprem --gpu-arch h200  workloads/readiness/diag-fin.yaml
#   workloadrun render   --platform onprem                  workloads/readiness/diag-par.yaml
# Each file here is the Workflows the controller would create. What they show:
#
# certification-fin: two Workflows (nccl-all-reduce, nccl-loopback-nvswitch);
#   nvidia.com/gpu "2" per worker; NCCL_DEBUG=INFO and NCCL_DEBUG_SUBSYS=INIT,GRAPH
#   passed to mpirun with -x; a toleration for eu1.io/staging:NoSchedule; the
#   threshold busBandwidthGBps "value >= 64.0"; image nvcr.io/nvidia/pytorch:26.01-py3.
#   The MPI workers install openssh-server with apt-get if the image has no
#   /usr/sbin/sshd, which needs package mirror egress from the node.
# certification-par: one Workflow, nvidia.com/gpu "1". nvcrectl warns:
#   communication/nccl-all-reduce: GPU architecture "l4" has no entry in the
#   catalog's GPU defaults, which fall back to gpusPerNode=4 mlnxPerNode=0 for it;
#   this run is sized at gpusPerNode=1 mlnxPerNode=0.
#   Without nvidia.com/gpu.product in the target, the offline render refuses:
#   "cannot determine GPU architecture" (and --gpu-arch only accepts the catalog's
#   architectures: a100, b200, b300, gb200, gb300, h100, h200, l40, l40s, rtxpro6000).
# diag-fin, diag-par: a WorkloadRun with the exec framework renders: the DCGM 4.6.1
#   image, /config/diag.sh from a ConfigMap, the GPUs requested, the staging
#   toleration. Rendering doesn't prove it can reach the host engine: W1 tries
#   it on the L4 first, and W2 falls back to kubectl exec in the nvidia-dcgm pod
#   (DIAG_VIA=exec) if it doesn't.

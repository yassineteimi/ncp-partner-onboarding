#!/usr/bin/env bash
#
# Install ArgoCD on site par and hand it gitops/sites/par/root.yaml. Run once,
# after cluster-up.sh.
#
# The root Application reads gitops/apps/par/ recursively. The base platform
# lives in gitops/apps/par/base/ and syncs in waves:
#   wave -1  local-path-provisioner
#   wave  0  node-feature-discovery, kube-prometheus-stack
#   wave  1  gpu-operator
#   wave  2  checkpoint-store (Garage), tenants
# The use case lanes add their own Applications beside base/, from wave 3.
#
# Nothing NVIDIA is installed until a GPU node exists, so the GPU Operator
# looks idle until make par-gpu-up.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par

require_tools kubectl helm
require_kubeconfig

bootstrap_argocd

cat <<'TXT'

ArgoCD is installed and pointed at gitops/apps/par in this repository, on
branch main. Open the UI with:

  make argocd-ui

TXT

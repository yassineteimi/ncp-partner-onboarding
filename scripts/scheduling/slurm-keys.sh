#!/usr/bin/env bash
#
# Creates the two Slurm authentication Secrets on par, once, outside Git
# (use case 5): slurm-auth-slurm (slurm.key) and slurm-auth-jwt (jwt.key) in
# the slurm namespace, 1024 random printable characters each, like the slurm
# chart's own randAscii 1024 (templates/secrets/slurmkey.yaml at 1.2.3).
#
# Why not the chart: it guards randAscii with a lookup of the existing Secret,
# and ArgoCD renders offline, where lookup returns nothing, so every render
# would make new keys for immutable Secrets (Part 1 rule 5).
#
# Never rotates: an existing Secret is left as it is. Run it before the slinky
# Application's first sync. The keys never leave the cluster; nothing is
# printed or written to disk.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par
require_kubeconfig
require_tools kubectl head tr

NS=slurm

kubectl_cp create namespace "$NS" --dry-run=client -o yaml | kubectl_cp apply -f - >/dev/null

make_key() {
  local name="$1" key="$2"
  if kubectl_cp -n "$NS" get secret "$name" >/dev/null 2>&1; then
    log "$NS/$name exists, left as it is"
    return
  fi
  # Printable ASCII without spaces, straight from /dev/urandom into the API
  # server through a pipe.
  LC_ALL=C tr -dc '[:graph:]' < /dev/urandom | head -c 1024 \
    | kubectl_cp -n "$NS" create secret generic "$name" --from-file="$key=/dev/stdin" \
        --dry-run=client -o json \
    | sed 's/"kind": "Secret"/"kind": "Secret", "immutable": true/' \
    | kubectl_cp apply -f - >/dev/null
  log "$NS/$name created ($key, 1024 characters, immutable)"
}

make_key slurm-auth-slurm slurm.key
make_key slurm-auth-jwt jwt.key

#!/usr/bin/env bash
#
# Runs on a fin node, over SSH, before kubeadm init or join. Sets the address
# the kubelet advertises, which on Verda is only known once the instance
# exists: its public address if the instance carries it on an interface, else
# the address its default route leaves from (with the public one kept as a
# certificate SAN by cp-init.sh). Prints the address it chose.
#
#   NODE_NAME=... PUBLIC_IP=... bash -s < node-address.sh
#
set -euo pipefail
: "${NODE_NAME:?}" "${PUBLIC_IP:?}"

if ip -4 -o addr show | grep -q " ${PUBLIC_IP}/"; then
  NODE_IP="$PUBLIC_IP"
else
  NODE_IP="$(ip -o route get 1.1.1.1 | sed -n 's/.* src \([^ ]*\).*/\1/p')"
fi

sed -i "/ ${NODE_NAME}\$/d" /etc/hosts
echo "${NODE_IP} ${NODE_NAME}" >> /etc/hosts
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
echo "node_ip=${NODE_IP}" >> /var/lib/eu1/bootstrap-facts.txt
echo "public_ip=${PUBLIC_IP}" >> /var/lib/eu1/bootstrap-facts.txt
echo "$NODE_IP"

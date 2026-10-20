#!/usr/bin/env bash
#
# Runs on the fin control plane, over SSH, after node-address.sh. The same
# kubeadm configuration as par's control plane bootstrap
# (terraform/par/cloud-init/control-plane.sh.tftpl), with the addresses passed
# in rather than rendered, because on Verda they only exist after the instance.
#
#   NODE_NAME=... NODE_IP=... PUBLIC_IP=... CLUSTER_NAME=... POD_SUBNET=...
#   SERVICE_SUBNET=... FLANNEL_VERSION=... bash -s < cp-init.sh
#
set -euo pipefail
exec > >(tee -a /var/log/eu1-bootstrap.log) 2>&1
: "${NODE_NAME:?}" "${NODE_IP:?}" "${PUBLIC_IP:?}" "${CLUSTER_NAME:?}" "${POD_SUBNET:?}" "${SERVICE_SUBNET:?}" "${FLANNEL_VERSION:?}"

log() { echo "[cp-init $(date -Is)] $*"; }

if [ -f /etc/kubernetes/admin.conf ]; then
  log "control plane already initialised, skipping kubeadm init"
else
  cat > /etc/kubernetes/kubeadm-init.yaml <<YAML
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${NODE_IP}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: ${CLUSTER_NAME}
controlPlaneEndpoint: "${NODE_IP}:6443"
networking:
  podSubnet: ${POD_SUBNET}
  serviceSubnet: ${SERVICE_SUBNET}
apiServer:
  certSANs:
    - ${NODE_IP}
    - ${PUBLIC_IP}
    - ${NODE_NAME}
    - 127.0.0.1
    - localhost
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
YAML
  log "running kubeadm init"
  kubeadm init --config /etc/kubernetes/kubeadm-init.yaml
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/.kube
install -o root -g root -m 0600 /etc/kubernetes/admin.conf /root/.kube/config

# Flannel pinned and pointed at the interface that reaches the control plane,
# as on par. Here that is the public interface: there is no private network,
# and the host firewall allows VXLAN only from the other node of the site.
FLANNEL_MANIFEST=/var/lib/eu1/kube-flannel.yml
curl -fsSL --retry 5 -o "$FLANNEL_MANIFEST" \
  "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
sed -i "s#10.244.0.0/16#${POD_SUBNET}#g" "$FLANNEL_MANIFEST"
kubectl apply -f "$FLANNEL_MANIFEST"
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s || true
kubectl -n kube-flannel patch daemonset kube-flannel-ds --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--iface-can-reach=${NODE_IP}\"}]"
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s || true

# Schedulable, as on par: the control plane carries ArgoCD, Prometheus and the
# NVCRE controller, which must run on a node without GPUs.
kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/control-plane- || true
kubectl label node "${NODE_NAME}" eu1.io/site=fin eu1.io/pool=control --overwrite
kubectl wait --for=condition=Ready "node/${NODE_NAME}" --timeout=300s

touch /var/lib/eu1/cp-init-complete
log "control plane initialised"

#!/usr/bin/env bash
#
# Free check for W2 step 5: parses fin's MIG config with mig-parted's own
# loader, without a GPU. The config is taken from the GPU Operator render of
# gitops/values/scheduling/gpu-operator-fin.yaml, so what is checked is what
# fin will get, and run through the MIG manager image the operator deploys
# (k8s-mig-manager v0.15.1), on par's CPU worker:
#
#   nvidia-mig-parted assert --valid-config -f config.yaml -c <config>
#
# --valid-config parses the file and selects the config, then returns before
# NVML starts (cmd/nvidia-mig-parted/assert/assert.go at v0.15.1). It proves
# the file and the profile syntax, not that an H200 offers 3g.71gb: W2 step 1
# captures nvidia-smi mig -lgip for that.
#
# Needs the CPU worker on. Uses team-a, the lane's namespace on par, and
# deletes what it creates. Writes docs/artifacts/scheduling/mig-config-par-<stamp>.txt.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
use_site par
require_kubeconfig
require_tools kubectl helm perl awk
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GPU_OPERATOR_VERSION=v26.7.2
MIG_MANAGER_IMAGE="nvcr.io/nvidia/cloud-native/k8s-mig-manager:v0.15.1@sha256:c1674fa2f46012dc425539f7fcac6445dce13bc81a05e4f91e311c7b8c27bcaf"
NS=team-a
work="$(mktemp -d)"
trap 'rm -rf "$work"; kubectl_cp -n "$NS" delete pod mig-config-check configmap mig-config-check --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

start_capture mig-config

section "Render fin's GPU Operator values and extract the MIG config"
helm pull gpu-operator --repo https://helm.ngc.nvidia.com/nvidia --version "$GPU_OPERATOR_VERSION" \
  --untar --untardir "$work" >/dev/null 2>&1
values=(-f "$REPO_ROOT/gitops/values/base/gpu-operator.yaml" -f "$REPO_ROOT/gitops/values/base/gpu-operator-fin.yaml")
for lane in readiness scheduling platform; do
  f="$REPO_ROOT/gitops/values/$lane/gpu-operator-fin.yaml"
  [ -f "$f" ] && values+=(-f "$f")
done
# templates/mig_config.yaml renders the mig-parted-eu1 ConfigMap at v26.7.2.
helm template gpu-operator "$work/gpu-operator" --namespace gpu-operator "${values[@]}" \
  --show-only templates/mig_config.yaml > "$work/cm.yaml"
grep -q 'name: mig-parted-eu1' "$work/cm.yaml" || die "the render has no mig-parted-eu1 ConfigMap"
# The config.yaml block, de-indented.
awk '/^  config.yaml: \|/{on=1; next} on && /^  [^ ]/{on=0} on' "$work/cm.yaml" | sed 's/^    //' > "$work/config.yaml"
[ -s "$work/config.yaml" ] || die "no config.yaml in the rendered mig-parted-eu1 ConfigMap"
cat "$work/config.yaml"

section "Run mig-parted's loader on the CPU worker"
kubectl_cp -n "$NS" create configmap mig-config-check --from-file=config.yaml="$work/config.yaml" \
  --dry-run=client -o yaml | kubectl_cp apply -f -
kubectl_cp -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mig-config-check
  namespace: $NS
spec:
  restartPolicy: Never
  nodeSelector:
    eu1.io/pool: cpu
  containers:
    - name: check
      image: $MIG_MANAGER_IMAGE
      # The image has no /bin/sh; busybox and its applets live in /busybox/.
      command: ["/busybox/sh", "-c"]
      args:
        - |
          nvidia-mig-parted --version
          for c in all-disabled h200-split; do
            echo "== \$c"
            nvidia-mig-parted assert --valid-config -f /config/config.yaml -c "\$c" || exit 1
          done
          echo "== a config that isn't in the file must fail"
          if nvidia-mig-parted assert --valid-config -f /config/config.yaml -c does-not-exist; then exit 1; fi
          echo "refused as expected"
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      configMap:
        name: mig-config-check
EOF
pod_done() {
  case "$(kubectl_cp -n "$NS" get pod mig-config-check -o jsonpath='{.status.phase}' 2>/dev/null)" in
    Succeeded | Failed) return 0 ;;
    *) return 1 ;;
  esac
}
wait_for "the check pod finished" 300 pod_done || true
kubectl_cp -n "$NS" logs mig-config-check 2>&1 || true
phase="$(kubectl_cp -n "$NS" get pod mig-config-check -o jsonpath='{.status.phase}')"

section "Result"
echo "pod phase: $phase"
# A container that never started has no log; its termination message says why.
kubectl_cp -n "$NS" get pod mig-config-check \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.message}{"\n"}' 2>/dev/null || true
[ "$phase" = Succeeded ] || exit 1
echo "fin's MIG config parses with mig-parted v0.15.1; both configs selectable"

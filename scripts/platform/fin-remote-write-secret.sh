#!/usr/bin/env bash
#
# Give fin's Prometheus its client certificate for Thanos Receive on par.
#
# Copies Secret thanos/thanos-client-fin from par, made there by the
# thanos-certs Job (gitops/manifests/platform/thanos/certs.yaml), into
# monitoring/thanos-remote-write on fin, the name
# gitops/values/platform/kube-prometheus-stack-fin.yaml reads.
#
# Called by scripts/fin/cp-up.sh after kubeadm and before ArgoCD: the Secret
# must exist before kube-prometheus-stack syncs on fin, or the Prometheus
# Operator can't render the remote write configuration and wave 0 never gets
# healthy. So it creates the monitoring namespace itself.
#
# Run from the repository root, no arguments:
#   PAR_KUBECONFIG=kubeconfig-par FIN_KUBECONFIG=kubeconfig-fin \
#     scripts/platform/fin-remote-write-secret.sh
# Idempotent: re-running applies the same Secret. Only reads from par.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools kubectl base64

PAR_KUBECONFIG="${PAR_KUBECONFIG:-$REPO_ROOT/kubeconfig-par}"
FIN_KUBECONFIG="${FIN_KUBECONFIG:-$REPO_ROOT/kubeconfig-fin}"
[ -f "$PAR_KUBECONFIG" ] || die "no par kubeconfig at $PAR_KUBECONFIG"
[ -f "$FIN_KUBECONFIG" ] || die "no fin kubeconfig at $FIN_KUBECONFIG"

par() { kubectl --kubeconfig "$PAR_KUBECONFIG" "$@"; }
fin() { kubectl --kubeconfig "$FIN_KUBECONFIG" "$@"; }

SOURCE_NS=thanos
SOURCE=thanos-client-fin
TARGET_NS=monitoring
TARGET=thanos-remote-write

par -n "$SOURCE_NS" get secret "$SOURCE" >/dev/null 2>&1 \
  || die "par has no $SOURCE_NS/$SOURCE yet. The thanos-certs Job makes it, on the CPU worker: is the thanos Application synced on par?"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

for key in tls.crt tls.key ca.crt; do
  par -n "$SOURCE_NS" get secret "$SOURCE" -o "jsonpath={.data.${key//./\\.}}" | base64 -d > "$WORK/$key"
  [ -s "$WORK/$key" ] || die "$SOURCE_NS/$SOURCE on par has no $key"
done

if command -v openssl >/dev/null 2>&1; then
  log "client certificate: $(openssl x509 -in "$WORK/tls.crt" -noout -subject -enddate | tr '\n' ' ')"
fi

log "creating namespace $TARGET_NS on fin if it's missing"
fin create namespace "$TARGET_NS" --dry-run=client -o yaml | fin apply -f -

log "applying $TARGET_NS/$TARGET on fin"
fin -n "$TARGET_NS" create secret generic "$TARGET" \
  --from-file=tls.crt="$WORK/tls.crt" \
  --from-file=tls.key="$WORK/tls.key" \
  --from-file=ca.crt="$WORK/ca.crt" \
  --dry-run=client -o yaml | fin apply -f -

log "on fin: $TARGET_NS/$TARGET with keys $(fin -n "$TARGET_NS" get secret "$TARGET" \
  -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
log "fin can now write to par as tenant fin"

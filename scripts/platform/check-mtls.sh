#!/usr/bin/env bash
#
# Free end-to-end check of fin's write path, on this laptop, before any site
# exists: the certificates, mutual TLS, and the tenant taken from the client
# certificate.
#
#   1. runs the "sign" step of the thanos-certs Job (certs.yaml) as written,
#      with a local openssl 3, and checks the chain and the key usages
#   2. starts thanos receive with the flags of receive.yaml, minus the bucket
#   3. starts a Prometheus whose remote write block mirrors fin's overlay:
#      dialled by IP, checking the name thanos-receive.eu1.internal
#   4. checks that its samples arrive as tenant_id="fin", through thanos query
#   5. checks that a client without a certificate, and one whose certificate
#      says CN=fin but comes from another CA, are both refused
#
# Needs thanos 0.42.4 and prometheus 3.14.0 (the versions the cluster runs),
# openssl 3, curl and python3 with PyYAML. Writes its transcript to
# docs/artifacts/platform/mtls-local-<timestamp>.txt with ARTIFACT=1.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools thanos prometheus openssl curl python3

MANIFESTS="$REPO_ROOT/gitops/manifests/platform/thanos"
WORK="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null || true
    # Only these PIDs: a bare wait also waits for the tee below, which never ends.
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "${ARTIFACT:-0}" = 1 ]; then
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  TRANSCRIPT="$REPO_ROOT/docs/artifacts/platform/mtls-local-$STAMP.txt"
  mkdir -p "$(dirname "$TRANSCRIPT")"
  # Colour codes stripped, so the transcript reads as plain text.
  exec > >(perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*m//g' | tee "$TRANSCRIPT") 2>&1
  echo "# $(basename "$0"), $STAMP, laptop clock, UTC"
  echo "# $(thanos --version 2>&1 | head -n1)"
  echo "# $(prometheus --version 2>&1 | head -n1)"
  echo "# $(openssl version)"
fi

########################################
# 1. The Job's sign step, as written
########################################

python3 - "$MANIFESTS/certs.yaml" "$WORK" > "$WORK/sign.sh" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "Job":
        init = {c["name"]: c for c in d["spec"]["template"]["spec"]["initContainers"]}
        print(init["sign"]["args"][0].replace("/work", sys.argv[2] + "/certs"))
PY
mkdir -p "$WORK/certs"
log "running the Job's sign step"
sh "$WORK/sign.sh"
C="$WORK/certs"
log "a second run creates nothing"
sh "$WORK/sign.sh" | grep -E 'created|signed' && die "the sign step is not idempotent"

openssl verify -CAfile "$C/thanos-ca/ca.crt" -purpose sslserver "$C/thanos-receive-tls/tls.crt"
for cn in fin fin-sim; do
  openssl verify -CAfile "$C/thanos-ca/ca.crt" -purpose sslclient "$C/thanos-client-$cn/tls.crt"
  openssl x509 -in "$C/thanos-client-$cn/tls.crt" -noout -subject | grep -q "CN *= *$cn$" \
    || die "client certificate for $cn has the wrong subject"
done
openssl verify -CAfile "$C/thanos-ca/ca.crt" -purpose sslclient "$C/thanos-receive-tls/tls.crt" >/dev/null 2>&1 \
  && die "the server certificate must not be usable as a client certificate"
log "chain and key usages are right"
openssl x509 -in "$C/thanos-receive-tls/tls.crt" -noout -ext subjectAltName

########################################
# 2. Receive with the flags of receive.yaml
########################################

python3 - "$MANIFESTS/receive.yaml" "$WORK" > "$WORK/receive.args" <<'PY'
import sys, yaml
work = sys.argv[2]
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "StatefulSet":
        for a in d["spec"]["template"]["spec"]["containers"][0]["args"]:
            if a.startswith("--objstore."):
                continue  # no bucket here: blocks stay local
            a = (a.replace("/etc/thanos/tls", work + "/certs/thanos-receive-tls")
                  .replace("/var/thanos/receive", work + "/tsdb")
                  .replace("$(POD_NAME)", "local-0")
                  .replace("0.0.0.0:", "127.0.0.1:")
                  .replace(".thanos-receive-headless.thanos.svc.cluster.local", ""))
            print(a)
PY
log "thanos $(tr '\n' ' ' < "$WORK/receive.args")"
# One argument per line, quotes kept, as the kubelet passes them. (xargs would
# strip the quotes --label needs.)
RECEIVE_ARGS=()
while IFS= read -r a; do RECEIVE_ARGS+=("$a"); done < "$WORK/receive.args"
thanos "${RECEIVE_ARGS[@]}" > "$WORK/receive.log" 2>&1 &
PIDS+=($!)

########################################
# 3. A Prometheus that writes like fin
########################################

cat > "$WORK/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  external_labels:
    site: fin
scrape_configs:
  - job_name: self
    static_configs: [{targets: ["127.0.0.1:19090"]}]
remote_write:
  - name: par-thanos
    url: https://127.0.0.1:19291/api/v1/receive
    tls_config:
      server_name: thanos-receive.eu1.internal
      ca_file: $C/thanos-client-fin/ca.crt
      cert_file: $C/thanos-client-fin/tls.crt
      key_file: $C/thanos-client-fin/tls.key
EOF
prometheus --config.file="$WORK/prometheus.yml" --storage.tsdb.path="$WORK/prom" \
  --web.listen-address=127.0.0.1:19090 > "$WORK/prometheus.log" 2>&1 &
PIDS+=($!)

thanos query --http-address=127.0.0.1:19192 --grpc-address=127.0.0.1:19193 \
  --endpoint.sd-config="$(printf 'endpoints:\n  - address: 127.0.0.1:10901\n')" \
  --query.replica-label=prometheus_replica --query.replica-label=receive_replica \
  > "$WORK/query.log" 2>&1 &
PIDS+=($!)

########################################
# 4. Samples arrive as tenant fin
########################################

log "waiting for samples to arrive through mutual TLS"
result=""
for _ in $(seq 1 30); do
  sleep 2
  result="$(curl -sf 'http://127.0.0.1:19192/api/v1/query' \
    --data-urlencode 'query=count by (tenant_id, site, receive_replica) (up)' || true)"
  echo "$result" | grep -q '"tenant_id":"fin"' && break
done
echo "$result"
echo "$result" | grep -q '"tenant_id":"fin"' || {
  tail -n 20 "$WORK/receive.log" "$WORK/prometheus.log"
  die "no samples from tenant fin"
}
echo "$result" | grep -q '"site":"fin"' || die "the site label did not survive the trip"
log "samples arrived as tenant_id=fin with site=fin"
grep -E 'samples_failed|Failed to send' "$WORK/prometheus.log" | head -n 3 || true

########################################
# 5. Who gets refused
########################################

post() { # extra curl args...
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    --resolve thanos-receive.eu1.internal:19291:127.0.0.1 \
    --cacert "$C/thanos-ca/ca.crt" -X POST --data-binary 'x' \
    "$@" https://thanos-receive.eu1.internal:19291/api/v1/receive || true
}

code="$(post)"
log "no client certificate: HTTP code '$code' (000 means the TLS handshake was refused)"
[ "$code" = 000 ] || die "a client without a certificate got an HTTP answer"

mkdir -p "$WORK/rogue"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj "/O=EU1/CN=rogue-ca" -keyout "$WORK/rogue/ca.key" -out "$WORK/rogue/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/O=EU1/CN=fin" \
  -keyout "$WORK/rogue/tls.key" -out "$WORK/rogue/req.csr" 2>/dev/null
printf 'extendedKeyUsage=clientAuth\n' > "$WORK/rogue/ext.cnf"
openssl x509 -req -in "$WORK/rogue/req.csr" -CA "$WORK/rogue/ca.crt" -CAkey "$WORK/rogue/ca.key" \
  -CAcreateserial -days 1 -extfile "$WORK/rogue/ext.cnf" -out "$WORK/rogue/tls.crt" 2>/dev/null
code="$(post --cert "$WORK/rogue/tls.crt" --key "$WORK/rogue/tls.key")"
log "CN=fin from another CA: HTTP code '$code'"
[ "$code" = 000 ] || die "a certificate from another CA got an HTTP answer"

code="$(post --cert "$C/thanos-client-fin/tls.crt" --key "$C/thanos-client-fin/tls.key")"
log "the real fin certificate with a garbage body: HTTP code '$code' (TLS accepted, request rejected)"
case "$code" in 4??) ;; *) die "expected a 4xx for a garbage body with a valid certificate" ;; esac

log "all mTLS checks passed"

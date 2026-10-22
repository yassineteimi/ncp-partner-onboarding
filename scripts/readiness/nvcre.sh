#!/usr/bin/env bash
#
# Use case 2 in a GPU window: stage a node, certify it with NVCRE, run the
# DCGM diagnostic, and promote it only if everything passed.
#
#   SITE=par|fin scripts/readiness/nvcre.sh prepull         pull the workload images onto the GPU node
#   SITE=par     scripts/readiness/nvcre.sh stage           add the staging taint (fin's node joins with it)
#   SITE=par|fin scripts/readiness/nvcre.sh certify         run workloads/readiness/certification-$SITE.yaml
#   SITE=par|fin scripts/readiness/nvcre.sh diag            dcgmi diag -r 2 (DIAG_LEVEL=3 for W3; DIAG_VIA=workloadrun, the default, or exec)
#   SITE=par|fin scripts/readiness/nvcre.sh promote         promote.py, then remove the taint only on its yes
#
# WORKLOAD_IMAGE=<image@digest> makes certify run the NCCL tests in another
# image without a commit: the fallback if pytorch:26.01-py3 (built for driver
# 590) can't run on fin's driver 580 through CUDA forward compatibility.
#
# Every step writes its evidence to docs/artifacts/readiness/ as soon as it
# ends, because fin may run on a spot node that can be reclaimed mid-window.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
SITE="${SITE:?SITE=par or SITE=fin}"
use_site "$SITE"

require_tools kubectl
require_kubeconfig
PYTHON="${PYTHON:-$REPO_ROOT/.venv/bin/python}"
NVCRECTL="${NVCRECTL:-nvcrectl}"
OUT="$REPO_ROOT/docs/artifacts/readiness"
TAINT_KEY="eu1.io/staging"
TAINT="$TAINT_KEY=pending:NoSchedule"
RUNS_NS="readiness-runs"
mkdir -p "$OUT"

stamp() { date -u +%Y%m%dT%H%M%SZ; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

gpu_node() {
  local node
  node="$(kubectl_cp get nodes -l "eu1.io/site=$SITE,eu1.io/pool=gpu" -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$node" ] || die "no GPU node on $SITE (label eu1.io/pool=gpu)"
  echo "$node"
}

taints() {
  kubectl_cp get node "$1" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}'
}

# The newest file matching a pattern, or nothing.
newest() { compgen -G "$1" | sort | tail -1; }

case "${1:-}" in
  prepull)
    node="$(gpu_node)"
    images=("nvcr.io/nvidia/pytorch:26.01-py3@sha256:38ed2ecb2c16d10677006d73fb0a150855d6ec81db8fc66e800b5ae92741007e")
    if [ "$SITE" = par ]; then
      # The goodput trainer and the janitor's reboot Job, for use case 3.
      images+=("$(awk '/image: ghcr.io\/yassineteimi\/goodput-trainer@/ {print $2}' "$REPO_ROOT/workloads/goodput/job.yaml")")
      images+=("public.ecr.aws/docker/library/busybox:1.37.0")
    fi
    kubectl_cp create namespace "$RUNS_NS" --dry-run=client -o yaml | kubectl_cp apply -f - >/dev/null
    log "pulling ${#images[@]} images onto $node"
    i=0
    for img in "${images[@]}"; do
      i=$((i + 1))
      kubectl_cp -n "$RUNS_NS" delete pod "prepull-$i" --ignore-not-found --wait >/dev/null
      kubectl_cp -n "$RUNS_NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: prepull-$i
  labels: {app.kubernetes.io/name: readiness-prepull}
spec:
  restartPolicy: Never
  nodeName: $node
  tolerations:
    - {key: $TAINT_KEY, operator: Exists, effect: NoSchedule}
  containers:
    - name: pull
      image: $img
      command: ["true"]
      resources: {requests: {cpu: 10m, memory: 16Mi}}
YAML
    done
    file="$OUT/prepull-$SITE-$(stamp).txt"
    started="$(now)"
    kubectl_cp -n "$RUNS_NS" wait pod -l app.kubernetes.io/name=readiness-prepull \
      --for=jsonpath='{.status.phase}'=Succeeded --timeout=1500s >/dev/null || warn "not every pull finished in 25 minutes"
    {
      echo "# pre-pull on $node, started $started, ended $(now)"
      kubectl_cp -n "$RUNS_NS" get events --field-selector reason=Pulled \
        -o custom-columns='TIME:.lastTimestamp,POD:.involvedObject.name,MESSAGE:.message'
    } | tee "$file"
    kubectl_cp -n "$RUNS_NS" delete pod -l app.kubernetes.io/name=readiness-prepull --wait=false >/dev/null
    ;;

  stage)
    node="$(gpu_node)"
    kubectl_cp taint node "$node" "$TAINT" --overwrite
    echo "staged=$(now) node=$node taint=$TAINT" | tee -a "$OUT/nvcre-$SITE-timeline.txt"
    taints "$node"
    ;;

  certify)
    require_tools "$NVCRECTL"
    node="$(gpu_node)"
    cert="$REPO_ROOT/workloads/readiness/certification-$SITE.yaml"
    ts="$(stamp)"
    name="eu1-$SITE-$(date -u +%H%M%S)"
    if [ -n "${WORKLOAD_IMAGE:-}" ]; then
      warn "workload image overridden: $WORKLOAD_IMAGE"
      copy="$REPO_ROOT/.cache/readiness/certification-$SITE-$ts.yaml"
      "$PYTHON" -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); d["spec"]["image"] = sys.argv[2]
yaml.safe_dump(d, open(sys.argv[3], "w"), sort_keys=False)' "$cert" "$WORKLOAD_IMAGE" "$copy"
      cert="$copy"
    fi
    taints "$node" | grep -q "^$TAINT_KEY=" || die "$node isn't staged: the certification only targets nodes with $TAINT_KEY"
    kubectl_cp create namespace "$RUNS_NS" --dry-run=client -o yaml | kubectl_cp apply -f - >/dev/null
    echo "certify_started=$(now) node=$node name=$name image=${WORKLOAD_IMAGE:-catalog}" | tee -a "$OUT/nvcre-$SITE-timeline.txt"
    set +e
    "$NVCRECTL" certification run --kubeconfig "$KUBECONFIG_PATH" -n "$RUNS_NS" --cert-file "$cert" \
      --name "$name" --wait --timeout "${TIMEOUT:-20m}" --results-file "$OUT/nvcre-$SITE-$ts.json" \
      2>&1 | perl -CSD -pe 's/\x{2014}/--/g' | tee "$OUT/nvcre-$SITE-$ts-report.txt"
    rc=${PIPESTATUS[0]}
    set -e
    echo "certify_ended=$(now) name=$name exit=$rc" | tee -a "$OUT/nvcre-$SITE-timeline.txt"
    # The raw NCCL log of every pod the run left behind: launcher and workers.
    for pod in $(kubectl_cp -n "$RUNS_NS" get pods -o name); do
      echo "== $pod"
      kubectl_cp -n "$RUNS_NS" logs "$pod" --all-containers --timestamps 2>&1
    done > "$OUT/nvcre-$SITE-$ts-nccl.log"
    kubectl_cp -n "$RUNS_NS" get certification "$name" -o yaml > "$OUT/nvcre-$SITE-$ts-certification.yaml" 2>/dev/null || true
    kubectl_cp -n "$RUNS_NS" get bandwidthmeasurements -o yaml > "$OUT/nvcre-$SITE-$ts-bandwidth.yaml" 2>/dev/null || true
    log "results in docs/artifacts/readiness/nvcre-$SITE-$ts*"
    exit "$rc"
    ;;

  diag)
    node="$(gpu_node)"
    ts="$(stamp)"
    LEVEL="${DIAG_LEVEL:-2}"
    [[ "$LEVEL" =~ ^[1-4]$ ]] || die "DIAG_LEVEL must be 1 to 4"
    file="$OUT/diag-$SITE-$ts.log"
    echo "diag_started=$(now) node=$node level=$LEVEL via=${DIAG_VIA:-workloadrun}" | tee -a "$OUT/nvcre-$SITE-timeline.txt"
    if [ "${DIAG_VIA:-workloadrun}" = workloadrun ]; then
      require_tools "$NVCRECTL"
      kubectl_cp create namespace "$RUNS_NS" --dry-run=client -o yaml | kubectl_cp apply -f - >/dev/null
      name="eu1-$SITE-diag-$(date -u +%H%M%S)"
      # The YAML says -r 2; W3 asks for level 3 on the same objects.
      spec="$REPO_ROOT/.cache/readiness/diag-$SITE-$ts.yaml"
      sed "s/ -r 2 -j/ -r $LEVEL -j/" "$REPO_ROOT/workloads/readiness/diag-$SITE.yaml" > "$spec"
      grep -q -- "-r $LEVEL -j" "$spec" || die "couldn't set the diagnostic level in $spec"
      "$NVCRECTL" workloadrun run --kubeconfig "$KUBECONFIG_PATH" -n "$RUNS_NS" --name "$name" \
        --wait --timeout "${TIMEOUT:-10m}" "$spec" \
        > "$OUT/diag-$SITE-$ts-report.txt" 2>&1 || warn "the WorkloadRun didn't succeed, see diag-$SITE-$ts-report.txt"
      for pod in $(kubectl_cp -n "$RUNS_NS" get pods -o name | grep "$name" || true); do
        kubectl_cp -n "$RUNS_NS" logs "$pod" --all-containers 2>&1
      done > "$file"
    else
      # Part 1's way: the standalone host engine's own pod runs dcgmi.
      pod="$(kubectl_cp -n gpu-operator get pods -l app=nvidia-dcgm --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}')"
      [ -n "$pod" ] || die "no nvidia-dcgm pod on $node"
      set +e
      # The ECC mode first, as the WorkloadRun's script does (diag-<site>.yaml).
      kubectl_cp -n gpu-operator exec "$pod" -- dcgmi dmon -e 300 -c 1 2>&1 \
        | awk '$1 == "GPU" { m = ($3 == "1") ? "Enabled" : ($3 == "0") ? "Disabled" : $3; print "ecc_mode gpu=" $2 " current=" m }' > "$file"
      kubectl_cp -n gpu-operator exec "$pod" -- dcgmi diag -r "$LEVEL" -j >> "$file" 2>&1
      rc=$?
      set -e
      echo "dcgmi_exit=$rc" >> "$file"
      if [ "$rc" != 0 ] || grep -Eq '"(status|result)"[[:space:]]*:[[:space:]]*"Fail' "$file"; then
        echo "diag_result=FAIL" >> "$file"
      else
        echo "diag_result=PASS" >> "$file"
      fi
    fi
    echo "diag_ended=$(now) $(grep -E '^diag_result=' "$file" || echo diag_result=none)" | tee -a "$OUT/nvcre-$SITE-timeline.txt"
    ;;

  promote)
    node="$(gpu_node)"
    results="$(newest "$OUT/nvcre-$SITE-*Z.json")"
    diag="$(newest "$OUT/diag-$SITE-*Z.log")"
    [ -n "$results" ] || die "no certification results for $SITE yet"
    [ -n "$diag" ] || die "no diagnostic log for $SITE yet"
    args=(--node "$node" --results "$results" --diag "$diag")
    if [ "$SITE" = fin ]; then
      # Two GPUs: both categories, and the channels must have used NVLink.
      args+=(--require communication/nccl-all-reduce communication/nccl-loopback-nvswitch)
      args+=(--nccl-log "${results%.json}-nccl.log")
    else
      # One GPU: no channel between GPUs exists, so no transport to check.
      args+=(--require communication/nccl-all-reduce)
    fi
    file="$OUT/promote-$SITE-$(stamp).txt"
    {
      echo "# promote.py at $(now), inputs ${results#"$REPO_ROOT"/} and ${diag#"$REPO_ROOT"/}"
      echo "taints before:"; taints "$node"
    } > "$file"
    set +e
    "$PYTHON" -I "$REPO_ROOT/scripts/readiness/promote.py" "${args[@]}" | tee -a "$file"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" = 0 ]; then
      kubectl_cp taint node "$node" "$TAINT_KEY-" | tee -a "$file"
      echo "promoted=$(now) node=$node" | tee -a "$OUT/nvcre-$SITE-timeline.txt"
    else
      # hardware cuts the later W2 steps, tooling allows a recorded override,
      # unclear goes to Yassine (W2 run sheet).
      cause="$(sed -n 's/^REFUSE .* cause=//p' "$file" | tail -1)"
      echo "refused=$(now) node=$node exit=$rc cause=${cause:-unknown}" | tee -a "$OUT/nvcre-$SITE-timeline.txt"
      warn "staging taint kept on $node. Cause: ${cause:-unknown}; the FAIL lines above say which check and why"
    fi
    { echo "taints after:"; taints "$node"; } | tee -a "$file"
    exit "$rc"
    ;;

  *)
    die "usage: SITE=par|fin scripts/readiness/nvcre.sh prepull|stage|certify|diag|promote"
    ;;
esac

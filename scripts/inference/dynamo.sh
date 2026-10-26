#!/usr/bin/env bash
#
# NVIDIA Dynamo on par: team-a's first inference service on the L4.
#
#   dynamo.sh check    no cluster change: render the platform chart as Argo CD
#                      will, check every image is pinned by digest, validate the
#                      model deployment against the v1beta1 CRD in Git, and
#                      dry-run the CRDs server-side on par (DRY_RUN=server)
#   dynamo.sh deploy   apply workloads/inference/qwen3-agg.yaml and time it from
#                      apply to both pods Ready (image pull included)
#   dynamo.sh test     through the frontend: list models, one answer, then
#                      latency to first token and tokens per second, one request
#                      at a time and 4 at once; the GPU as the worker sees it
#   dynamo.sh delete   remove the model deployment, before the L4 goes
#
# deploy and test write docs/artifacts/inference/dynamo-<mode>-<stamp>.txt.
# Times are this laptop's clock, UTC.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

MODE="${1:-}"
case "$MODE" in check | deploy | test | delete) ;; *) die "usage: $0 check|deploy|test|delete" ;; esac

use_site par
NS=team-a
DGD="$REPO_ROOT/workloads/inference/qwen3-agg.yaml"
VALUES="$REPO_ROOT/gitops/values/inference/dynamo-platform-par.yaml"
CRDS="$REPO_ROOT/gitops/manifests/inference/dynamo-crds"
CHART_VERSION=1.5.1
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

capture() {
  OUTFILE="$REPO_ROOT/docs/artifacts/inference/dynamo-$MODE-$STAMP.txt"
  mkdir -p "$(dirname "$OUTFILE")"
  exec > >(perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*m//g' | tee "$OUTFILE") 2>&1
  echo "# dynamo.sh $MODE, $STAMP, laptop clock, UTC. git $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
}

case "$MODE" in
check)
  require_tools helm kubectl python3
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  log "rendering dynamo-platform $CHART_VERSION with par's values"
  helm pull dynamo-platform --repo https://helm.ngc.nvidia.com/nvidia/ai-dynamo \
    --version "$CHART_VERSION" --untar -d "$work" >/dev/null
  helm template dynamo-platform "$work/dynamo-platform" -n dynamo-system -f "$VALUES" > "$work/render.yaml"
  kubectl kustomize "$CRDS" > "$work/crds.yaml"
  python3 - "$work/render.yaml" "$DGD" <<'PY'
import re, sys
render, dgd = (open(p).read() for p in sys.argv[1:])
images = set(re.findall(r'image:\s*"?([^"\s]+)', render + dgd))
unpinned = [i for i in images if "@sha256:" not in i]
print("images:", *sorted(images), sep="\n  ")
assert not unpinned, f"not pinned by digest: {unpinned}"
assert "kind: Deployment" in render, "no operator Deployment rendered"
assert "crd-apply" not in render, "upgradeCRD must stay off for a namespace-scoped operator"
assert len(re.findall(r'kubernetes\.io/metadata\.name: "?team-a"?', render)) >= 8, "every webhook must be scoped to team-a"
print("operator: one Deployment, no crd-apply, all 8 webhooks scoped to team-a")
PY
  if python3 -c 'import jsonschema, yaml' 2>/dev/null; then
    python3 - "$CRDS/nvidia.com_dynamographdeployments.yaml" "$DGD" <<'PY'
import sys, yaml, jsonschema
crd, dgd = (yaml.safe_load(open(p)) for p in sys.argv[1:])
schema = next(v for v in crd["spec"]["versions"] if v["name"] == "v1beta1")["schema"]["openAPIV3Schema"]
strip = lambda s: ({k: strip(v) for k, v in s.items() if not k.startswith("x-kubernetes")} if isinstance(s, dict)
                   else [strip(x) for x in s] if isinstance(s, list) else s)
errors = list(jsonschema.Draft7Validator(strip(schema)).iter_errors(dgd))
for e in errors: print("  ", e.message[:160], list(e.path))
assert not errors, "the model deployment doesn't match the v1beta1 CRD"
print("model deployment: valid against the v1beta1 CRD in Git")
PY
  else
    warn "no jsonschema/yaml in this python: the model deployment wasn't validated against its CRD"
  fi
  if [ "${DRY_RUN:-}" = server ]; then
    require_kubeconfig
    log "server-side dry run of the six CRDs on par"
    kubectl_cp apply --server-side --dry-run=server -f "$work/crds.yaml"
  fi
  log "dynamo check passed"
  ;;

deploy)
  require_tools kubectl
  require_kubeconfig
  capture
  kubectl_cp get crd dynamographdeployments.nvidia.com >/dev/null || die "no Dynamo CRDs on par: is the dynamo Application synced?"
  kubectl_cp -n dynamo-system get deploy -o wide
  echo "applied_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kubectl_cp apply -f "$DGD"
  deadline=$(( $(date +%s) + 1800 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ready="$(kubectl_cp -n "$NS" get pods -l nvidia.com/dynamo-graph-deployment-name=qwen3-agg \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{end}' 2>/dev/null || true)"
    total=$(wc -w <<<"$ready"); ok=$(grep -o true <<<"$ready" | wc -l)
    [ "$total" -ge 2 ] && [ "$ok" -eq "$total" ] && break
    sleep 10
  done
  echo "ready_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) pods_ready=${ok:-0}/${total:-0}"
  echo; echo "== pods"; kubectl_cp -n "$NS" get pods -o wide
  echo; echo "== the model deployment"; kubectl_cp -n "$NS" get dynamographdeployments.nvidia.com qwen3-agg -o wide || true
  echo; echo "== worker scheduling"
  kubectl_cp -n "$NS" get pods -o custom-columns='POD:.metadata.name,SCHEDULER:.spec.schedulerName,QUEUE:.metadata.labels.kai\.scheduler/queue,NODE:.spec.nodeName'
  echo; echo "== image pulls"
  kubectl_cp -n "$NS" get events --field-selector reason=Pulled -o custom-columns='TIME:.lastTimestamp,POD:.involvedObject.name,MESSAGE:.message' || true
  ;;

test)
  require_tools kubectl python3
  require_kubeconfig
  capture
  svc="$(kubectl_cp -n "$NS" get svc -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | tr ' ' '\n' | grep -m1 frontend)"
  [ -n "$svc" ] || die "no frontend Service in $NS"
  echo "frontend service: $svc"
  kubectl_cp -n "$NS" port-forward "svc/$svc" 18000:8000 >/dev/null 2>&1 &
  pf=$!; trap 'kill $pf 2>/dev/null' EXIT
  sleep 3
  python3 - <<'PY'
import json, time, urllib.request, concurrent.futures
BASE = "http://127.0.0.1:18000"
def get(path): return json.load(urllib.request.urlopen(BASE + path, timeout=30))
print("== models"); print(json.dumps(get("/v1/models"), indent=1)[:600])
def ask(prompt, max_tokens=128):
    body = json.dumps({"model": "Qwen/Qwen3-0.6B", "stream": True, "max_tokens": max_tokens,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", body, {"Content-Type": "application/json"})
    t0 = time.monotonic(); first = None; tokens = 0; text = []
    with urllib.request.urlopen(req, timeout=120) as r:
        for line in r:
            line = line.decode().strip()
            if not line.startswith("data:") or line.endswith("[DONE]"): continue
            delta = json.loads(line[5:])["choices"][0].get("delta", {}).get("content") or ""
            if delta:
                first = first or time.monotonic(); tokens += 1; text.append(delta)
    end = time.monotonic()
    return (first - t0) * 1000, tokens / (end - first) if tokens > 1 else 0, "".join(text)
ttft, tps, text = ask("In one sentence, what does a GPU cloud partner do?", 64)
print("== one answer"); print(text.strip()[:400])
def run(n, conc):
    with concurrent.futures.ThreadPoolExecutor(conc) as pool:
        res = list(pool.map(lambda i: ask(f"Write a short paragraph about GPU number {i}."), range(n)))
    t = sorted(r[0] for r in res); s = [r[1] for r in res]
    print(f"concurrency {conc}, {n} requests: time to first token p50 {t[len(t)//2]:.0f} ms, "
          f"max {t[-1]:.0f} ms; decode {sum(s)/len(s):.1f} tokens/s per request")
print("== latency"); run(8, 1); run(16, 4)
PY
  echo; echo "== the GPU, from the worker"
  worker="$(kubectl_cp -n "$NS" get pods -o name | grep -m1 -i worker)"
  kubectl_cp -n "$NS" exec "$worker" -- nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,utilization.gpu --format=csv || true
  ;;

delete)
  require_tools kubectl
  require_kubeconfig
  kubectl_cp delete -f "$DGD" --ignore-not-found --wait=true
  kubectl_cp -n "$NS" get pods
  ;;
esac

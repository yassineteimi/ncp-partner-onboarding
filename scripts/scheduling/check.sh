#!/usr/bin/env bash
#
# Free checks for use cases 4 and 5, before anything reaches a cluster:
#
#   1. KAI v0.18.6 renders on both sites with the lane values; every KAI pod
#      template carries the site's nodeSelector; no secret is generated at
#      render time (no randAlphaNum, randAscii, genCA or genSignedCert)
#   2. the GPU Operator v26.7.2 renders on fin with every overlay that exists,
#      and the rendered ClusterPolicy has mixed MIG and the mig-parted-eu1 config
#   3. the vendored simulated-GPU manifests match a fresh render (no hand edits)
#      and every kustomization builds: sim-gpu, the queues, the workloads
#   4. allreduce.py compiles; the overlays set what they claim (the fin gang asks
#      for one GPU per pod and no staging toleration, the gloo check asks for none)
#   5. with DRY_RUN=server, every built object that par's API server knows
#      the kind of passes a server-side dry run against par (changes nothing;
#      kinds whose CRD isn't installed yet are listed and skipped)
#
# Renders are left in $OUT (default: a temporary directory) for inspection.
# ARTIFACT=1 also writes the transcript to
# docs/artifacts/scheduling/free-checks-<stamp>.txt.
# Needs PyYAML: the repository's .venv has it (make docs creates it), and it
# is used when present.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

if [ "${ARTIFACT:-}" = "1" ]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  transcript="$REPO_ROOT/docs/artifacts/scheduling/free-checks-$stamp.txt"
  mkdir -p "$(dirname "$transcript")"
  exec > >(perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*m//g' | tee "$transcript") 2>&1
  echo "# scripts/scheduling/check.sh, $stamp, laptop clock, UTC. git $(git -C "$REPO_ROOT" rev-parse --short HEAD). DRY_RUN=${DRY_RUN:-none}"
fi

if [ -x "$REPO_ROOT/.venv/bin/python3" ]; then
  PATH="$REPO_ROOT/.venv/bin:$PATH"
fi
require_tools helm kubectl python3 diff
python3 -c 'import yaml' 2>/dev/null || die "python3 has no PyYAML: run make docs once to create .venv"

KAI_VERSION=v0.18.6
GPU_OPERATOR_VERSION=v26.7.2
VALUES="$REPO_ROOT/gitops/values"
MANIFESTS="$REPO_ROOT/gitops/manifests/scheduling"
WORKLOADS="$REPO_ROOT/workloads/scheduling"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT/charts"
log "renders go to $OUT"

fail() { die "check failed: $*"; }

########################################
# 1. KAI on both sites
########################################

helm pull oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler --version "$KAI_VERSION" \
  --untar --untardir "$OUT/charts" >/dev/null 2>&1
KAI_CHART="$OUT/charts/kai-scheduler"

if grep -rn -E 'randAlphaNum|randAscii|genCA|genSignedCert|genPrivateKey' "$KAI_CHART/templates"; then
  fail "the KAI chart generates secrets at render time (Part 1 rule 5)"
fi
log "KAI chart generates no secret at render time"

for site in par fin; do
  case "$site" in par) pool=cpu ;; fin) pool=control ;; esac
  # --include-crds: ArgoCD applies the chart's crds/ too, so they get dry-run.
  helm template kai-scheduler "$KAI_CHART" --namespace kai-scheduler --include-crds \
    -f "$VALUES/scheduling/kai-scheduler.yaml" \
    -f "$VALUES/scheduling/kai-scheduler-$site.yaml" > "$OUT/kai-$site.yaml"
  python3 - "$OUT/kai-$site.yaml" "$pool" <<'PY'
import sys, yaml
path, pool = sys.argv[1], sys.argv[2]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
bad = []
for d in docs:
    kind = d["kind"]
    if kind in ("Deployment", "Job"):
        sel = d["spec"]["template"]["spec"].get("nodeSelector") or {}
        if sel.get("eu1.io/pool") != pool:
            bad.append(f"{kind}/{d['metadata']['name']}")
    if kind == "Config":
        sel = d["spec"]["global"].get("nodeSelector") or {}
        if sel.get("eu1.io/pool") != pool:
            bad.append("Config/kai-config global.nodeSelector")
hooks = [d["metadata"]["name"] for d in docs
         if "helm.sh/hook" in (d["metadata"].get("annotations") or {})]
if bad:
    sys.exit(f"without eu1.io/pool={pool}: {', '.join(bad)}")
print(f"    every KAI pod template and the Config select eu1.io/pool={pool}; hooks left: {', '.join(hooks)}")
PY
  log "KAI renders on $site"
done

########################################
# 2. GPU Operator on fin, MIG overlay
########################################

helm pull gpu-operator --repo https://helm.ngc.nvidia.com/nvidia --version "$GPU_OPERATOR_VERSION" \
  --untar --untardir "$OUT/charts" >/dev/null 2>&1
gpu_values=(-f "$VALUES/base/gpu-operator.yaml" -f "$VALUES/base/gpu-operator-fin.yaml")
for lane in readiness scheduling platform; do
  if [ -f "$VALUES/$lane/gpu-operator-fin.yaml" ]; then
    gpu_values+=(-f "$VALUES/$lane/gpu-operator-fin.yaml")
  fi
done
helm template gpu-operator "$OUT/charts/gpu-operator" --namespace gpu-operator \
  "${gpu_values[@]}" > "$OUT/gpu-operator-fin.yaml"
python3 - "$OUT/gpu-operator-fin.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cp = next(d for d in docs if d["kind"] == "ClusterPolicy")["spec"]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "mig-parted-eu1")
assert cp["mig"]["strategy"] == "mixed", cp["mig"]
assert cp["migManager"]["enabled"] is True
assert cp["migManager"]["config"]["name"] == "mig-parted-eu1"
env = {e["name"]: e["value"] for e in cp["migManager"].get("env") or []}
assert env.get("WITH_REBOOT") == "false", env
configs = yaml.safe_load(cm["data"]["config.yaml"])["mig-configs"]
assert set(configs) == {"all-disabled", "h200-split"}, configs
assert cp["driver"]["enabled"] is False
print("    ClusterPolicy: mig.strategy=mixed, migManager on with mig-parted-eu1, WITH_REBOOT=false, driver off")
print("    configs:", ", ".join(sorted(configs)))
PY
log "GPU Operator renders on fin with $((${#gpu_values[@]} / 2)) value files"

########################################
# 3. Vendored manifests and kustomizations
########################################

# A fresh render into a copy of the tree must change nothing.
cp -R "$REPO_ROOT/gitops/manifests/scheduling/sim-gpu" "$OUT/sim-gpu-committed"
"$REPO_ROOT/scripts/scheduling/render-sim-gpu.sh" >/dev/null
if ! diff -r "$OUT/sim-gpu-committed" "$MANIFESTS/sim-gpu" >/dev/null; then
  diff -r "$OUT/sim-gpu-committed" "$MANIFESTS/sim-gpu" | head -20
  fail "the vendored sim-gpu manifests differ from a fresh render; commit the render"
fi
log "vendored sim-gpu manifests match a fresh render"

builds=(
  "$MANIFESTS/sim-gpu"
  "$MANIFESTS/kai-queues/par"
  "$MANIFESTS/kai-queues/fin"
  "$WORKLOADS/allreduce/fin"
  "$WORKLOADS/allreduce/fin-too-big"
  "$WORKLOADS/allreduce/par-gloo"
  "$WORKLOADS/sim-demo"
  "$WORKLOADS/mig"
  "$WORKLOADS/prepull"
)
for dir in "${builds[@]}"; do
  name="$(echo "${dir#"$REPO_ROOT"/}" | tr '/' '_')"
  if [ -f "$dir/kustomization.yaml" ]; then
    kubectl kustomize "$dir" > "$OUT/$name.yaml"
  else
    cat "$dir"/*.yaml > "$OUT/$name.yaml"
  fi
  echo "    $(grep -c '^kind:' "$OUT/$name.yaml") objects from ${dir#"$REPO_ROOT"/}"
done
log "every kustomization builds"

# Rule 7: every image the lane's manifests and workloads name, including
# images passed in env values, is pinned by digest. KWOK Stage templates
# ({{ .image }}) aren't images.
unpinned="$(cat "$OUT"/gitops_manifests_scheduling_*.yaml "$OUT"/workloads_scheduling_*.yaml \
  | grep -E '^\s*(- )?image: *"?[a-z0-9]|^\s*(- )?value: *"?[a-z0-9.-]+\.[a-z]{2,}/[^ ]+:[^ ]+' \
  | grep -v -E '@sha256:|\{\{' || true)"
if [ -n "$unpinned" ]; then
  echo "$unpinned"
  fail "image references without a digest"
fi
log "every image reference is pinned by digest"

########################################
# 4. Workloads say what they claim
########################################

python3 -m py_compile "$WORKLOADS/allreduce/base/allreduce.py"
python3 - "$OUT" <<'PY'
import sys, yaml, os
out = sys.argv[1]
def jobs(name):
    return [d for d in yaml.safe_load_all(open(os.path.join(out, name))) if d and d["kind"] == "Job"]
def spec(job):
    return job["spec"]["template"]["spec"]
for name, size, pool, gpus, backend in (
    ("workloads_scheduling_allreduce_fin.yaml", 2, "gpu", 1, "nccl"),
    ("workloads_scheduling_allreduce_fin-too-big.yaml", 3, "gpu", 1, "nccl"),
    ("workloads_scheduling_allreduce_par-gloo.yaml", 2, "cpu", 0, "gloo"),
):
    (job,) = jobs(name)
    s = spec(job)
    c = s["containers"][0]
    env = {e["name"]: e.get("value") for e in c["env"]}
    got_gpus = int((c["resources"].get("limits") or {}).get("nvidia.com/gpu", 0))
    tolerations = [t.get("key") for t in s.get("tolerations") or []]
    assert job["metadata"]["annotations"]["kai.scheduler/batch-min-member"] == str(size), name
    assert job["spec"]["parallelism"] == size and env["WORLD_SIZE"] == str(size), name
    assert env["MASTER_ADDR"] == f"{s['subdomain']}-0.{s['subdomain']}", name
    assert s["schedulerName"] == "kai-scheduler" and s["nodeSelector"]["eu1.io/pool"] == pool, name
    assert got_gpus == gpus and env["BACKEND"] == backend, name
    assert "eu1.io/staging" not in tolerations, f"{name} tolerates the staging taint"
    print(f"    {name}: gang of {size}, pool {pool}, {gpus} GPU per pod, {backend}, no staging toleration")
PY
log "workloads checked"

########################################
# 5. Server-side dry run on par
########################################

if [ "${DRY_RUN:-}" = "server" ]; then
  use_site par
  require_kubeconfig
  known="$OUT/known-kinds.txt"
  # "Kind namespaced" for every kind the API server serves, and the
  # namespaces that exist.
  kubectl_cp api-resources --no-headers | awk '{print $NF, $(NF-1)}' | sort -u > "$known"
  kubectl_cp get namespaces -o name | sed 's|^namespace/||' > "$OUT/namespaces.txt"
  for f in kai-par.yaml gitops_manifests_scheduling_sim-gpu.yaml gitops_manifests_scheduling_kai-queues_par.yaml; do
    python3 - "$OUT/$f" "$known" "$OUT/namespaces.txt" "$OUT/dry-$f" <<'PY'
import sys, yaml
src, known_path, ns_path, dst = sys.argv[1:]
namespaced = dict(line.split() for line in open(known_path))
existing = set(open(ns_path).read().split())
created = set()
keep, skipped, moved = [], {}, {}
docs = [d for d in yaml.safe_load_all(open(src)) if d]
for d in docs:
    if d["kind"] == "Namespace":
        created.add(d["metadata"]["name"])
for d in docs:
    kind = d["kind"]
    if kind not in namespaced:
        skipped[kind] = skipped.get(kind, 0) + 1
        continue
    if namespaced[kind] == "true":
        ns = d["metadata"].get("namespace", "default")
        # ArgoCD creates these at sync (CreateNamespace, or a Namespace in the
        # same sync); a dry run can't, so validate the object in default.
        if ns not in existing:
            moved[ns] = moved.get(ns, 0) + 1
            d["metadata"]["namespace"] = "default"
    keep.append(d)
yaml.safe_dump_all(keep, open(dst, "w"))
print(f"    {len(keep)} objects to dry-run; skipped, CRD not installed yet: {skipped or 'none'}; "
      f"validated in default, namespace created at sync: {moved or 'none'}")
PY
    kubectl_cp apply --dry-run=server --server-side --force-conflicts \
      --field-manager=check-scheduling -f "$OUT/dry-$f" -o name | sed 's/^/    /'
  done
  log "server-side dry run on par passed"
fi

log "all scheduling checks passed"

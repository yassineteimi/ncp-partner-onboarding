"""Checks over the charts rendered by scripts/readiness/render.sh.

  python render_check.py <dir of rendered yaml>

Prints one summary and exits 1 if a check fails. The checks are the things
that would cost a GPU window if they were only found on the cluster:

  placement   every pod of a lane chart outside a DaemonSet asks for an
              eu1.io/pool, so it never lands on par's 4 vCPU control plane or
              on a GPU node
  images      every image has a version tag or a digest, none says main or latest
  webhooks    which API calls each admission webhook intercepts, and whether
              one could block core resources (pods, nodes) for everyone while
              its pod is down, which on par is whenever the CPU worker is off
  hooks       Helm hooks, which Argo CD runs as its own sync hooks
  staging     on fin, the GPU Operator operands tolerate the staging taint
"""

import sys
from pathlib import Path

import yaml

POOL = "eu1.io/pool"
STAGING = "eu1.io/staging"
POD_OWNERS = {"Deployment", "StatefulSet", "Job", "ReplicaSet"}
CORE = {("", "pods"), ("", "nodes"), ("", "*"), ("*", "*"), ("apps", "*")}


def documents(path):
    for doc in yaml.safe_load_all(path.read_text()):
        if isinstance(doc, dict) and doc.get("kind"):
            yield doc


def pod_spec(doc):
    kind = doc["kind"]
    spec = doc.get("spec") or {}
    if kind == "CronJob":
        return spec["jobTemplate"]["spec"]["template"]["spec"]
    if kind in POD_OWNERS or kind == "DaemonSet":
        return spec["template"]["spec"]
    if kind == "Pod":
        return spec
    return None


def asks_for_pool(spec):
    if POOL in (spec.get("nodeSelector") or {}):
        return True
    required = (((spec.get("affinity") or {}).get("nodeAffinity") or {})
                .get("requiredDuringSchedulingIgnoredDuringExecution") or {})
    for term in required.get("nodeSelectorTerms") or []:
        if any(e.get("key") == POOL for e in term.get("matchExpressions") or []):
            return True
    return False


def image_ok(image):
    if "@sha256:" in image:
        return True
    name = image.rsplit("/", 1)[-1]
    if ":" not in name:
        return False
    return name.split(":", 1)[1] not in ("main", "latest", "")


def percona_replsets(doc):
    for rs in (doc.get("spec") or {}).get("replsets") or []:
        yield rs


def check(rendered):
    lines, failures = [], []

    def fail(msg):
        failures.append(msg)
        lines.append(f"  FAIL {msg}")

    for path in sorted(rendered.glob("*.yaml")):
        docs = list(documents(path))
        lines.append(f"== {path.stem}: {len(docs)} objects")

        for doc in docs:
            kind, name = doc["kind"], doc["metadata"]["name"]
            spec = pod_spec(doc)
            # The base platform's charts are cos's; only their staging check is ours.
            if spec is not None and "-base-" not in path.stem:
                containers = (spec.get("initContainers") or []) + (spec.get("containers") or [])
                for c in containers:
                    if not image_ok(c.get("image", "")):
                        fail(f"{kind}/{name} image {c.get('image')!r} has no fixed version")
                if kind == "DaemonSet":
                    selector = spec.get("nodeSelector") or {}
                    lines.append(f"  DaemonSet/{name} on nodes with {selector or 'any label'}")
                elif asks_for_pool(spec):
                    lines.append(f"  {kind}/{name} placed by {POOL}")
                else:
                    fail(f"{kind}/{name} doesn't ask for an {POOL}")

            if kind == "PerconaServerMongoDB":
                for rs in percona_replsets(doc):
                    sel = rs.get("nodeSelector") or {}
                    sc = (((rs.get("volumeSpec") or {}).get("persistentVolumeClaim") or
                           (rs.get("volumeSpec") or {}).get("pvc") or {}).get("storageClassName"))
                    if POOL not in sel:
                        fail(f"MongoDB replset {rs.get('name')} doesn't ask for an {POOL}")
                    if not sc:
                        fail(f"MongoDB replset {rs.get('name')} has no storageClassName")
                    lines.append(f"  MongoDB replset {rs.get('name')}: size {rs.get('size')}, "
                                 f"{POOL}={sel.get(POOL)}, storage class {sc}")

            if kind in ("ValidatingWebhookConfiguration", "MutatingWebhookConfiguration"):
                for hook in doc.get("webhooks") or []:
                    targets = sorted({(g, r) for rule in hook.get("rules") or []
                                      for g in rule.get("apiGroups") or []
                                      for r in rule.get("resources") or []})
                    policy = hook.get("failurePolicy", "Fail")
                    shown = ", ".join(f"{g or 'core'}/{r}" for g, r in targets)
                    scope = hook.get("objectSelector") or hook.get("namespaceSelector")
                    scoped = f", only objects matching {scope}" if scope else ""
                    lines.append(f"  {kind[:8]} {hook['name']}: {policy} on {shown}{scoped}")
                    if policy == "Fail" and CORE & set(targets) and not scope:
                        fail(f"webhook {hook['name']} can block {shown} while its pod is down")

            hook = (doc["metadata"].get("annotations") or {}).get("helm.sh/hook")
            if hook:
                lines.append(f"  Helm hook {hook}: {kind}/{name}")

            if kind == "ClusterPolicy":
                tolerations = ((doc.get("spec") or {}).get("daemonsets") or {}).get("tolerations") or []
                keys = sorted(t.get("key", "*") for t in tolerations)
                lines.append(f"  ClusterPolicy operands tolerate {keys}")
                if path.stem.startswith("fin-") and STAGING not in keys:
                    fail(f"fin's GPU Operator operands don't tolerate {STAGING}")

    lines.append(f"== {'FAILED: ' + str(len(failures)) if failures else 'all checks passed'}")
    return lines, failures


def main():
    lines, failures = check(Path(sys.argv[1]))
    print("\n".join(lines))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()

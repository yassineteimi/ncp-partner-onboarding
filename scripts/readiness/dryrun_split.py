"""Split rendered manifests into what the API server can dry-run today and what it can't.

  python dryrun_split.py <api-resources file> <out dir> <rendered yaml>...

A server-side dry run of a custom resource fails with "no matches for kind"
until its CRD exists, and a dry run never creates the CRD. So objects whose
kind the cluster doesn't serve yet are set aside and listed; they are checked
when Argo CD syncs the CRDs for real. The api-resources file is the output of
`kubectl api-resources -o wide --no-headers`, read as group/version and kind.

Writes <out dir>/<name>.yaml with the objects to dry-run, and prints the
skipped ones. Namespaces are stripped: the lane's namespaces don't exist until
Argo CD creates them, and a dry run into a missing namespace fails before any
schema is checked, so namespaced objects are dry-run in whatever namespace the
caller passes to kubectl.
"""

import sys
from pathlib import Path

import yaml


def served(api_resources):
    kinds = set()
    for line in Path(api_resources).read_text().splitlines():
        cols = line.split()
        # NAME [SHORTNAMES] APIVERSION NAMESPACED KIND VERBS ...
        for i, col in enumerate(cols):
            if col in ("true", "false") and i >= 2:
                kinds.add((cols[i - 1], cols[i + 1]))
                break
    return kinds


def main():
    known = served(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for rendered in map(Path, sys.argv[3:]):
        keep, skipped = [], []
        for doc in yaml.safe_load_all(rendered.read_text()):
            if not isinstance(doc, dict) or not doc.get("kind"):
                continue
            if (doc["apiVersion"], doc["kind"]) in known or doc["kind"] == "CustomResourceDefinition":
                doc["metadata"].pop("namespace", None)
                keep.append(doc)
            else:
                skipped.append(f"{doc['apiVersion']} {doc['kind']}/{doc['metadata']['name']}")
        (out / rendered.name).write_text(yaml.safe_dump_all(keep, sort_keys=False))
        print(f"{rendered.stem}: {len(keep)} to dry-run, {len(skipped)} set aside (kind not served yet)")
        for s in skipped:
            print(f"  set aside: {s}")


if __name__ == "__main__":
    main()

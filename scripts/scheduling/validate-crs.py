"""Validates custom resources against the CRDs rendered next to them.

A server-side dry run can't check a custom resource whose CRD isn't installed
yet (KAI's Queue and Config, Slinky's Controller and NodeSet, KWOK's Stage on
a fresh par), so make sched-check validates them here against the OpenAPI
schema of the CRD that ships in the same chart or manifest. Unknown fields
are not caught (the API server prunes them rather than refusing them); types,
enums and required fields are. Run by scripts/scheduling/check.sh.

usage: validate-crs.py <file with CRDs> <file with CRs>...
"""
import sys, yaml, jsonschema


def strip(s):
    # OpenAPI v3.0 structural schema -> JSON Schema draft 4: drop Kubernetes
    # extensions, turn nullable into a null type.
    if isinstance(s, dict):
        out = {k: strip(v) for k, v in s.items() if not k.startswith("x-kubernetes") and k != "nullable"}
        if s.get("nullable") and "type" in out:
            out["type"] = [out["type"], "null"]
        return out
    if isinstance(s, list):
        return [strip(v) for v in s]
    return s


crds = {}
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "CustomResourceDefinition":
        group = d["spec"]["group"]
        for v in d["spec"]["versions"]:
            crds[(f"{group}/{v['name']}", d["spec"]["names"]["kind"])] = strip(v["schema"]["openAPIV3Schema"])

for path in sys.argv[2:]:
    for d in yaml.safe_load_all(open(path)):
        if not d:
            continue
        key = (d["apiVersion"], d["kind"])
        if key in crds:
            jsonschema.Draft4Validator(crds[key]).validate(d)
            print("valid:", d["apiVersion"], d["kind"], d["metadata"]["name"])

#!/usr/bin/env bash
#
# Prints the digest of an image tag, read from its registry over the
# distribution API, with no container runtime needed:
#
#   scripts/scheduling/image-digest.sh ghcr.io/run-ai/fake-gpu-operator/status-updater:0.2.1
#
# For a multi-arch image this is the digest of the index, the one to pin
# (rule 7), so the node pulls its own platform from it. Anonymous pulls only,
# which covers every public image this lane uses (ghcr.io, registry.k8s.io,
# docker.io, nvcr.io).
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools curl

ref="${1:?usage: image-digest.sh registry/repository:tag}"
registry="${ref%%/*}"
rest="${ref#*/}"
repo="${rest%:*}"
tag="${rest##*:}"
[ "$repo" != "$rest" ] || die "no tag in $ref"

if [ "$registry" = "docker.io" ]; then
  api="registry-1.docker.io"
  case "$repo" in */*) ;; *) repo="library/$repo" ;; esac
else
  api="$registry"
fi

accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
url="https://$api/v2/$repo/manifests/$tag"

# A registry that wants a token answers 401 with a Bearer challenge naming the
# realm and service. Ask that realm for an anonymous pull token.
headers="$(curl -sSI -H "Accept: $accept" "$url")"
if printf '%s' "$headers" | grep -qi '^www-authenticate: bearer'; then
  challenge="$(printf '%s' "$headers" | grep -i '^www-authenticate:' | tr -d '\r')"
  realm="$(printf '%s' "$challenge" | sed -E 's/.*realm="([^"]+)".*/\1/')"
  service="$(printf '%s' "$challenge" | sed -nE 's/.*service="([^"]+)".*/\1/p')"
  token="$(curl -sSf -G "$realm" --data-urlencode "service=$service" \
    --data-urlencode "scope=repository:$repo:pull" \
    | sed -nE 's/.*"(token|access_token)":"([^"]+)".*/\2/p' | head -n1)"
  [ -n "$token" ] || die "no anonymous token from $realm for $repo"
  headers="$(curl -sSIL -H "Accept: $accept" -H "Authorization: Bearer $token" "$url")"
else
  headers="$(curl -sSIL -H "Accept: $accept" "$url")"
fi

digest="$(printf '%s' "$headers" | grep -i '^docker-content-digest:' | tail -n1 \
  | awk '{print $2}' | tr -d '\r')"
[ -n "$digest" ] || die "no digest for $ref (is the tag right?)"
printf '%s\n' "$digest"

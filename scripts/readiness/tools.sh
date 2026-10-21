#!/usr/bin/env bash
#
# The lane's CLIs at their pinned versions (nvcrectl, aicr), in .cache/readiness/bin, each
# checked against the checksums file of its own GitHub release.
#
#   scripts/readiness/tools.sh
#
# NVCRE's installer (curl ... | bash) would install whatever "latest" is that
# day, and NVCRE releases weekly. The window runs the version this lane tested.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_tools gh shasum

NVCRE_VERSION=v0.8.0
AICR_VERSION=v1.1.0
BIN="$REPO_ROOT/.cache/readiness/bin"
mkdir -p "$BIN"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Darwin-x86_64) platform=darwin-amd64 ;;
  Linux-x86_64) platform=linux-amd64 ;;
  Linux-aarch64) platform=linux-arm64 ;;
  *) die "no nvcrectl build for $(uname -s) $(uname -m)" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh release download "$NVCRE_VERSION" -R NVIDIA/cluster-readiness-engine \
  -p "nvcrectl-$platform" -p checksums.txt -D "$work"
(cd "$work" && grep " nvcrectl-$platform\$" checksums.txt | shasum -a 256 -c -) \
  || die "nvcrectl-$platform doesn't match the release's checksums.txt"
install -m 0755 "$work/nvcrectl-$platform" "$BIN/nvcrectl"
log "$("$BIN/nvcrectl" --version) in ${BIN#"$REPO_ROOT"/}"

# AICR names its archives os_arch with an underscore and the version without v.
tarball="aicr_${AICR_VERSION#v}_${platform/-/_}.tar.gz"
gh release download "$AICR_VERSION" -R NVIDIA/aicr -p "$tarball" -p aicr_checksums.txt -D "$work"
(cd "$work" && grep " $tarball\$" aicr_checksums.txt | shasum -a 256 -c -) \
  || die "$tarball doesn't match the release's aicr_checksums.txt"
tar -xzf "$work/$tarball" -C "$work" aicr
install -m 0755 "$work/aicr" "$BIN/aicr"
log "aicr $("$BIN/aicr" --version 2>&1 | head -1) in ${BIN#"$REPO_ROOT"/}"

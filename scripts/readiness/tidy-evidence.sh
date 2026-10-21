#!/usr/bin/env bash
#
# Before evidence is committed: replace em dashes in docs/artifacts/readiness/
# with "--", and list every file changed.
#
#   scripts/readiness/tidy-evidence.sh
#
# The repository's lint (make lint, run by CI) refuses em dashes in any tracked
# file. The tools whose output is kept as evidence (nvcrectl, aicr, NCCL, DCGM)
# write them. The replacement is the only change, it is listed, and JSON stays
# valid (an em dash only ever appears inside a string).
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

DIR="$REPO_ROOT/docs/artifacts/readiness"
changed=0
while IFS= read -r -d '' f; do
  if grep -q $'\xe2\x80\x94' "$f"; then
    perl -CSD -pi -e 's/\x{2014}/--/g' "$f"
    echo "em dashes written as -- in ${f#"$REPO_ROOT"/}"
    changed=$((changed + 1))
  fi
done < <(find "$DIR" -type f -print0)
log "$changed file(s) changed"

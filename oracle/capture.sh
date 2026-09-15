#!/bin/sh
# oracle/capture.sh [case] — record runc's behaviour into oracle/expected/.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
CASE="${1:-basic}"
RUNTIME=runc CASE="$CASE" sh "$here/oracle/core.sh" || exit 1
obs="$here/oracle/.observed"
grep -q '^obs\.begin=1$' "$obs" || { echo "FAIL: no obs.begin -- the container did not run" >&2; exit 1; }
grep -q '^obs\.end=1$'   "$obs" || { echo "FAIL: no obs.end -- it did not finish" >&2; exit 1; }
cp "$here/oracle/.normalised" "$here/oracle/expected/$CASE.txt"
echo "wrote oracle/expected/$CASE.txt"

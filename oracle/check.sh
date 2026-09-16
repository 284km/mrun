#!/bin/sh
# oracle/check.sh [case...] — run mrun against the recorded expectations.
#
# Reports FIELD BY FIELD rather than pass/fail. A runtime being built is
# partially right, and "12 of 20 fields match, these 8 do not" is the number
# that says what to do next; a red light says only that something is wrong.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
IMG="${IMG:-gcc:14}"
RUNNER="${RUNNER:-colima ssh --}"
SRC="${SRC:-$here}"
out="$here/.build"; mkdir -p "$out"

echo "== build (emit on the host, compile for linux in $IMG, static) =="
"$M" -c "$here/mrun.mere" > "$out/mrun.c" 2> "$out/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,25p' "$out/emit.err" >&2; exit 1; }
[ -s "$out/mrun.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }
docker run --rm -v "$here:/w" -w /w "$IMG" \
  cc -O1 -static -o .build/mrun-linux .build/mrun.c linux_shim.c 2> "$out/cc.err" || {
  echo "FAIL: cc" >&2; sed -n '1,25p' "$out/cc.err" >&2; exit 1; }
$RUNNER sh -c "sudo cp $SRC/.build/mrun-linux /var/tmp/mrun && sudo chmod 755 /var/tmp/mrun" || exit 1

total=0; matched=0; cases_run=0
for c in "${@:-basic}"; do
  exp="$here/oracle/expected/$c.txt"
  [ -f "$exp" ] || { echo "  no expectation for $c"; continue; }
  echo "== $c =="
  RUNTIME=/var/tmp/mrun CASE="$c" sh "$here/oracle/core.sh" || { echo "  FAIL  runner"; continue; }
  got="$here/oracle/.normalised"
  cases_run=$((cases_run + 1))
  # Fields mrun is MEANT to differ from runc on. Empty, and the machinery stays
  # because the first entry proposed for it turned out not to belong: `lo` was
  # added on the assumption that runc leaves loopback down and everything above
  # it brings loopback up. runc leaves it UP -- mrun was simply missing a step,
  # and the staleness half of this check is what said so, by failing an entry
  # that no longer differed. An allowance is a claim, and this one checks it.
  DIVERGE=""
  grep -v '^#' "$exp" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    k=${line%%=*}
    g=$(grep "^$k=" "$got" 2>/dev/null | head -1)
    case " $DIVERGE " in
      *" $k "*)
        if [ "$g" = "$line" ]; then
          echo "  FAIL  $k  is on the deliberate-divergence list but matches runc now [${g#*=}]"
        else
          echo "  ok    $k  differs on purpose  runc[${line#*=}] mrun[${g#*=}]"
        fi ;;
      *)
        if [ "$g" = "$line" ]; then echo "  ok    $k"
        else echo "  FAIL  $k  want[${line#*=}] got[${g#*=}]"; fi ;;
    esac
  done > "$here/oracle/.report.$c"
  cat "$here/oracle/.report.$c"
  t=$(grep -c . "$here/oracle/.report.$c"); m=$(grep -c '^  ok ' "$here/oracle/.report.$c" || true)
  echo "  --> $m/$t fields match"
  total=$((total + t)); matched=$((matched + m))
done
[ "$cases_run" -gt 0 ] || { echo "no case ran"; exit 1; }
echo "TOTAL $matched/$total fields across $cases_run case(s)"
[ "$matched" = "$total" ] && exit 0 || exit 1

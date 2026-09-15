#!/bin/sh
# probe/run.sh — P0.5. Builds and runs probe_fork_exec, then asserts on the
# exact multiset of markers. Exits 0 only if every stage happened exactly once.
#
#   MERE=<mere checkout> sh probe/run.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M (dune build?)" >&2; exit 2; }

out="$here/.build"
mkdir -p "$out"

echo "== emit =="
"$M" -c "$here/probe_fork_exec.mere" > "$out/probe.c" 2> "$out/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$out/emit.err" >&2; exit 1; }
# A refusal that still exits 0 would leave an empty file; catch that too.
[ -s "$out/probe.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }

echo "== compile =="
cc -O1 -o "$out/probe" "$out/probe.c" "$here/proc_shim.c" 2> "$out/cc.err" || {
  echo "FAIL: cc" >&2; sed -n '1,20p' "$out/cc.err" >&2; exit 1; }

echo "== run (stdout redirected to a file: the strict buffering case) =="
"$out/probe" > "$out/run.log" 2>&1
rc=$?
cat "$out/run.log"

echo "== assert =="
fail=0
# Markers are anchored. `P0.5 child-exec` is a PREFIX of
# `P0.5 child-exec-FAILED`, so an unanchored grep counted the failure line as
# a success -- the poison run (exec pointed at a missing path) reported stage 3
# green. Anchor every marker that has a longer sibling.
count() { c=$(grep -c "$1" "$out/run.log" 2>/dev/null); [ -n "$c" ] || c=0; echo "$c"; }
expect() { # marker expected label
  got=$(count "$1")
  if [ "$got" = "$2" ]; then
    echo "  ok    $3  (x$got)"
  else
    echo "  FAIL  $3  expected x$2, got x$got"
    fail=1
  fi
}
expect '^P0\.5 begin pid='            1 'stage 0  parent runs (and stdout is NOT double-buffered into the child)'
# 492 = total digits of the decimal numerals 1..200 (9*1 + 90*2 + 101*3). A
# child whose allocator came through the fork intact can only produce this one.
expect '^P0\.5 child-alive len=492$'   1 'stage 2  child is still Mere, and allocates after the fork'
expect '^P0\.5 child-region len=492$'  1 'stage 2b a `region R {}` opened and rolled back INSIDE the forked child'
expect '^P0\.5 child-exec$'            1 'stage 3  child became /bin/echo'
expect '^P0\.5 parent-reaped status=0$' 1 'stage 4  parent reaped it and read the status'
expect 'FAILED'                     0 'no stage reported its own failure'
expect '^()$'                       1 'exactly one process fell off the end (the child never returned from exec)'

if [ "$rc" != 0 ]; then echo "  FAIL  probe exited $rc"; fail=1; else echo "  ok    probe exit 0"; fi
[ "$fail" = 0 ] && echo "P0.5 PASS" || echo "P0.5 FAIL"
exit "$fail"

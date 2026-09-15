#!/bin/sh
# probe/run_linux.sh — the same probe, compiled and run on Linux aarch64.
#
# P1 runs inside the guest, not on macOS, and fork/exec being POSIX is not the
# same as having measured it there. This also IS the P0.1 build path: `mere -c`
# emits on the host, the C is compiled inside a Linux container, and the binary
# runs on Linux. The guest has no compiler of its own (checked 2026-09-15:
# Ubuntu 24.04.4 aarch64 has no cc / gcc / clang / make).
#
#   MERE=<mere checkout> sh probe/run_linux.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
IMG="${IMG:-gcc:14}"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }

out="$here/.build-linux"
mkdir -p "$out"

echo "== emit (host) =="
"$M" -c "$here/probe_fork_exec.mere" > "$out/probe.c" 2> "$out/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$out/emit.err" >&2; exit 1; }
[ -s "$out/probe.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }

echo "== compile + run (linux aarch64, in $IMG) =="
docker run --rm -v "$here:/w" -w /w "$IMG" sh -c '
  set -e
  cc -O1 -o .build-linux/probe .build-linux/probe.c proc_shim.c
  ./.build-linux/probe
' > "$out/run.log" 2>&1
rc=$?
cat "$out/run.log"

echo "== assert =="
fail=0
count() { c=$(grep -c "$1" "$out/run.log" 2>/dev/null); [ -n "$c" ] || c=0; echo "$c"; }
expect() {
  got=$(count "$1")
  if [ "$got" = "$2" ]; then echo "  ok    $3  (x$got)"
  else echo "  FAIL  $3  expected x$2, got x$got"; fail=1; fi
}
expect '^P0\.5 begin pid='             1 'stage 0  parent runs, stdout not double-buffered into the child'
expect '^P0\.5 child-alive len=492$'   1 'stage 2  child is still Mere and allocates after the fork'
expect '^P0\.5 child-region len=492$'  1 'stage 2b a `region R {}` opened and rolled back inside the child'
expect '^P0\.5 child-exec$'            1 'stage 3  child became /bin/echo'
expect '^P0\.5 parent-reaped status=0$' 1 'stage 4  parent reaped it and read the status'
expect 'FAILED'                        0 'no stage reported its own failure'

if [ "$rc" != 0 ]; then echo "  FAIL  container exited $rc"; fail=1; else echo "  ok    container exit 0"; fi
[ "$fail" = 0 ] && echo "P0.5/linux PASS" || echo "P0.5/linux FAIL"
exit "$fail"

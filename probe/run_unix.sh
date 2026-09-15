#!/bin/sh
# probe/run_unix.sh — P0.3. AF_UNIX, and specifically that the byte path is
# binary-safe. Runs on the host, then again on Linux aarch64 in the CI image.
#
#   sh probe/run_unix.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
IMG="${IMG:-gcc:14}"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"

"$M" -c "$here/probe/probe_unix_socket.mere" > "$out/unix.c" 2> "$out/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$out/emit.err" >&2; exit 1; }
[ -s "$out/unix.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }

check() { # logfile label
  fail=0
  c() { n=$(grep -c "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; echo "$n"; }
  for pair in '^P0\.3 listening$:1:bound an AF_UNIX listener' \
              '^P0\.3 child-sent 5000$:1:child dialled it and wrote 5000 bytes' \
              '^P0\.3 binary-safe ok$:1:every byte survived, zero bytes included' \
              '^P0\.3 parent-reaped status=0$:1:child exited cleanly' \
              'FAILED:0:no stage reported its own failure'; do
    pat=${pair%%:*}; rest=${pair#*:}; want=${rest%%:*}; lbl=${rest#*:}
    got=$(c "$pat" "$1")
    if [ "$got" = "$want" ]; then echo "  ok    $lbl"
    else echo "  FAIL  $lbl (expected x$want, got x$got)"; fail=1; fi
  done
  return $fail
}

echo "== host =="
cc -O1 -o "$out/probe_unix" "$out/unix.c" "$here/unix_shim.c" "$here/probe/proc_shim.c" \
  2> "$out/cc.err" || { echo "FAIL: cc" >&2; sed -n '1,10p' "$out/cc.err" >&2; exit 1; }
rm -f /tmp/mere-p03.sock
"$out/probe_unix" > "$out/unix.log" 2>&1
check "$out/unix.log" || hostfail=1

echo "== linux aarch64 ($IMG) =="
docker run --rm -v "$here:/w" -w /w "$IMG" sh -c '
  cc -O1 -o /tmp/probe_unix .build/unix.c unix_shim.c probe/proc_shim.c || exit 1
  rm -f /tmp/mere-p03.sock; /tmp/probe_unix' > "$out/unix-linux.log" 2>&1
check "$out/unix-linux.log" || lxfail=1

if [ "${hostfail:-0}" = 0 ] && [ "${lxfail:-0}" = 0 ]; then echo "P0.3 PASS"; exit 0
else echo "P0.3 FAIL"; exit 1; fi

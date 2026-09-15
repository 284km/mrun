#!/bin/sh
# oracle/capture.sh — record what runc does, before mrun tries to do it.
#
# Runs against a Linux host with runc and cgroup v2. Here that is the colima VM,
# reached over `colima ssh`; set RUNNER to anything else that takes a shell
# script on stdin and runs it as a user with sudo.
#
# Everything happens in the VM's OWN filesystem (/var/tmp), never in a mounted
# host directory: a macOS-backed mount keeps neither uid 0 nor a mode-000 file,
# and a rootfs extracted there is not the rootfs the archive described.
#
# The rootfs comes from `docker export`, NOT from mtar. An oracle whose input is
# produced by the thing under test cannot contradict it.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${RUNNER:-colima ssh --}"
# Where this repository is visible FROM THE RUNNER. colima mounts $HOME into the
# VM at the same path, so the host path works there unchanged; set SRC when it
# does not (a different VM, a remote host, a mount at another prefix).
SRC="${SRC:-$here}"
WORK=/var/tmp/mrun-oracle
case_name="${1:-basic}"

$RUNNER sh -s <<EOF > "$here/oracle/.capture.raw" 2>&1
set -eu
[ -r $SRC/oracle/observe.sh ] || { echo "FAIL: this repo is not visible at $SRC from the runner; set SRC=" >&2; exit 1; }
sudo rm -rf $WORK
mkdir -p $WORK/bundle/rootfs
cd $WORK/bundle

# rootfs: a real alpine, via docker export
cid=\$(docker create alpine:latest true)
docker export "\$cid" | sudo tar x -C rootfs
docker rm -f "\$cid" >/dev/null

sudo cp $SRC/oracle/observe.sh rootfs/observe.sh
sudo chmod 755 rootfs/observe.sh

sudo runc spec
sudo cp $SRC/oracle/cases/$case_name.py $WORK/case.py
sudo python3 - <<'PYEOF'
import json, importlib.util, sys
spec = json.load(open("/var/tmp/mrun-oracle/bundle/config.json"))
spec["process"]["args"] = ["/observe.sh"]
spec["process"]["terminal"] = False
sp = importlib.util.spec_from_file_location("case", "/var/tmp/mrun-oracle/case.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
spec = m.mutate(spec)
json.dump(spec, open("/var/tmp/mrun-oracle/bundle/config.json", "w"), indent=2)
PYEOF

echo "=== HOSTNS ==="
for ns in pid mnt net uts ipc cgroup user; do
  echo "host.ns.\$ns=\$(sudo readlink /proc/1/ns/\$ns 2>/dev/null)"
done
echo "=== RUNC ==="
set +e
sudo runc run mrun-oracle-$case_name
rc=\$?; echo "=== EXIT=\$rc ==="
sudo runc delete -f mrun-oracle-$case_name 2>/dev/null || true
EOF
rc=$?
raw="$here/oracle/.capture.raw"
if [ "$rc" != 0 ] || ! grep -q '^=== RUNC ===$' "$raw"; then
  echo "FAIL: capture did not reach runc (runner exit=$rc)" >&2
  sed -n '1,25p' "$raw" >&2
  exit 1
fi

sed -n '/^=== HOSTNS ===$/,/^=== RUNC ===$/p' "$raw" | grep '^host\.ns\.' > "$here/oracle/.hostns"
sed -n '/^=== RUNC ===$/,/^=== EXIT=/p' "$raw" | grep '^obs\.'       > "$here/oracle/.observed"

# An observation that did not run end to end must not be recorded as one.
grep -q '^obs\.begin=1$' "$here/oracle/.observed" || { echo "FAIL: no obs.begin" >&2; exit 1; }
grep -q '^obs\.end=1$'   "$here/oracle/.observed" || { echo "FAIL: no obs.end" >&2; exit 1; }

out="$here/oracle/expected/$case_name.txt"
{
  echo "# recorded from runc by oracle/capture.sh -- do not hand-edit"
  echo "runc.exit=$(sed -n 's/^=== EXIT=\([0-9]*\) ===$/\1/p' "$raw" | head -1)"
  sh "$here/oracle/normalise.sh" "$here/oracle/.observed" "$here/oracle/.hostns"
} > "$out"
echo "wrote $out"
cat "$out"

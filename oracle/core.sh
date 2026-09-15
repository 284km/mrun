#!/bin/sh
# oracle/core.sh — build one bundle, run one runtime against it, normalise the
# result. capture.sh and check.sh are both thin wrappers around this, so runc
# and mrun are handed a byte-identical bundle. Two scripts that built the bundle
# separately would drift, and the comparison would start measuring the drift.
#
# env: RUNTIME (runc | /path/to/mrun)  CASE  RUNNER  SRC  WORK
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${RUNNER:-colima ssh --}"
SRC="${SRC:-$here}"
RUNTIME="${RUNTIME:-runc}"
CASE="${CASE:-basic}"
WORK="${WORK:-/var/tmp/mrun-oracle}"
raw="$here/oracle/.capture.raw"

$RUNNER sh -s <<EOF > "$raw" 2>&1
set -eu
[ -r $SRC/oracle/observe.sh ] || { echo "FAIL: repo not visible at $SRC from the runner; set SRC=" >&2; exit 1; }
sudo rm -rf $WORK
mkdir -p $WORK/bundle/rootfs
cd $WORK/bundle

cid=\$(docker create alpine:latest true)
docker export "\$cid" | sudo tar x -C rootfs
docker rm -f "\$cid" >/dev/null

sudo cp $SRC/oracle/observe.sh rootfs/observe.sh
sudo chmod 755 rootfs/observe.sh
sudo cp $SRC/oracle/cases/$CASE.py $WORK/case.py

sudo runc spec
sudo python3 - <<'PYEOF'
import json, importlib.util
p = "$WORK/bundle/config.json"
spec = json.load(open(p))
spec["process"]["args"] = ["/observe.sh"]
spec["process"]["terminal"] = False
sp = importlib.util.spec_from_file_location("case", "$WORK/case.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
json.dump(m.mutate(spec), open(p, "w"), indent=2)
PYEOF

echo "=== HOSTNS ==="
for ns in pid mnt net uts ipc cgroup user; do
  echo "host.ns.\$ns=\$(sudo readlink /proc/1/ns/\$ns 2>/dev/null)"
done
echo "=== RUN ==="
set +e
sudo $RUNTIME run mrun-oracle-$CASE
rc=\$?; echo "=== EXIT=\$rc ==="
sudo $RUNTIME delete -f mrun-oracle-$CASE 2>/dev/null
sudo runc delete -f mrun-oracle-$CASE 2>/dev/null
exit 0
EOF

grep -q '^=== RUN ===$' "$raw" || { echo "FAIL: never reached the runtime" >&2; sed -n '1,25p' "$raw" >&2; exit 1; }
sed -n '/^=== HOSTNS ===$/,/^=== RUN ===$/p' "$raw" | grep '^host\.ns\.' > "$here/oracle/.hostns"
sed -n '/^=== RUN ===$/,/^=== EXIT=/p'      "$raw" | grep '^obs\.'       > "$here/oracle/.observed"
{
  echo "# recorded from $RUNTIME by oracle/core.sh -- do not hand-edit"
  echo "runc.exit=$(sed -n 's/^=== EXIT=\([0-9]*\) ===$/\1/p' "$raw" | head -1)"
  sh "$here/oracle/normalise.sh" "$here/oracle/.observed" "$here/oracle/.hostns"
} > "$here/oracle/.normalised"

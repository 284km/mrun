#!/bin/sh
# oracle/observe.sh — runs as the container's process and reports what it can
# see. This is the comparison surface between runc and mrun.
#
# Namespace IDENTIFIERS are not printed raw: they are inode numbers that differ
# on every run, so comparing them would make every run differ from every other.
# The raw values go out tagged, and normalise.sh turns each into "new" or
# "host" by diffing against the host's own, which is the fact being claimed.
echo "obs.begin=1"
echo "obs.uid=$(id -u)"
echo "obs.gid=$(id -g)"
echo "obs.hostname=$(hostname)"
echo "obs.cwd=$(pwd)"
for ns in pid mnt net uts ipc cgroup user; do
  v=$(readlink "/proc/self/ns/$ns" 2>/dev/null) || v=missing
  echo "obs.rawns.$ns=${v:-missing}"
done
echo "obs.cgroup=$(cat /proc/self/cgroup 2>/dev/null | tr '\n' ';')"
# NOT the raw count of /proc/[0-9]*: that races with the subshells this script
# itself spawns and came back 4 on one run and 3 on the next -- an oracle field
# that disagrees with itself. The claims worth making are that this process is
# pid 1 in its namespace, and that the host's process table is not visible.
echo "obs.pid=$$"
_n=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
if [ "$_n" -lt 16 ]; then echo "obs.pids_few=yes"; else echo "obs.pids_few=no"; fi
# The LIST, not the count. "20 vs 7" says a runtime is missing mounts; it does
# not say which, and the count is equally satisfied by mounting the wrong ones.
echo "obs.mounts=$(awk '{print $2}' /proc/self/mounts | sort | tr '\n' ',')"
echo "obs.root=$(ls -A / 2>/dev/null | sort | tr '\n' ',')"
echo "obs.dev=$(ls /dev 2>/dev/null | sort | tr '\n' ',')"
# Is loopback usable? runc leaves it down and every layer above runc brings it
# up, so this is a field where a difference is expected -- and a field, rather
# than a silent divergence, is the only way that is true on purpose.
# The FLAGS, not operstate: loopback has no carrier, so its operstate reads
# `unknown` whether it is up or down -- a field that cannot tell the two apart
# and would have reported this divergence as absent. IFF_UP is 0x1, so 0x8 is
# down and 0x9 is up.
echo "obs.lo=$(cat /sys/class/net/lo/flags 2>/dev/null || echo unknown)"
echo "obs.caps=$(grep ^CapEff /proc/self/status | awk '{print $2}')"
echo "obs.capbnd=$(grep ^CapBnd /proc/self/status | awk '{print $2}')"
echo "obs.nofile=$(ulimit -n)"
echo "obs.env_case=${MRUN_CASE:-unset}"
echo "obs.end=1"
# An argument means "exit with this code", so the harness can check a status
# actually travels back rather than assuming 0 means success.
[ $# -ge 1 ] && exit "$1"
exit 0

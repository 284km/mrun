#!/bin/sh
# oracle/normalise.sh <observed-file> <host-ns-file>
#
# Turn a raw capture into facts that are the same on every run:
#   - each namespace becomes "new" or "host" rather than an inode number
#   - the cgroup path keeps its shape but loses the container id
# Anything left raw here would make two correct runs disagree, which is the
# failure mode that makes an oracle useless.
set -u
obs="$1"; hostns="$2"
grep -v '^obs\.rawns\.' "$obs" | grep -v '^obs\.cgroup=' | sed 's/^obs\.//'
for ns in pid mnt net uts ipc cgroup user; do
  mine=$(grep "^obs.rawns.$ns=" "$obs" | head -1 | cut -d= -f2-)
  theirs=$(grep "^host.ns.$ns=" "$hostns" | head -1 | cut -d= -f2-)
  if [ -z "$mine" ] || [ "$mine" = missing ]; then v=missing
  elif [ "$mine" = "$theirs" ]; then v=host
  else v=new; fi
  echo "ns.$ns=$v"
done
# 0::/path/to/scope -> 0::<scope>, so the container id does not leak into the
# expectation and make it un-rerunnable.
grep '^obs.cgroup=' "$obs" | sed 's/^obs\.//' | sed 's#/[^/;]*$#/<leaf>#'

#!/bin/sh
# oracle/normalise.sh <observed-file> <host-ns-file>
#
# Turn a raw capture into facts that are the same on every run:
#   - each namespace becomes "new", "host" or "given" rather than an inode
#     number. "given" is the third answer: a bundle can name a namespace that
#     already exists, and a runtime that quietly made a fresh one instead would
#     otherwise be indistinguishable from one that did as it was told.
#   - the cgroup path keeps its shape but loses the container id
# Anything left raw here would make two correct runs disagree, which is the
# failure mode that makes an oracle useless.
set -u
obs="$1"; hostns="$2"
# The interface list is a FACT about a namespace we made or were given, and
# whatever the machine happens to have when the namespace is the host's. Left
# raw, the expectation records this machine at this moment -- two correct runs
# disagree as soon as anything else on the box makes an interface, which is
# what happened: a daemon under development left bridges behind and a recorded
# expectation went stale without anything being wrong.
hostnet=$(grep "^obs.rawns.net=" "$obs" | head -1 | cut -d= -f2-)
theirnet=$(grep "^host.ns.net=" "$hostns" | head -1 | cut -d= -f2-)
grep -v '^obs\.rawns\.' "$obs" | grep -v '^obs\.cgroup=' | sed 's/^obs\.//' \
  | { if [ "$hostnet" = "$theirnet" ]; then sed 's/^netifs=.*/netifs=<the host\x27s>/'; else cat; fi; }
for ns in pid mnt net uts ipc cgroup user; do
  mine=$(grep "^obs.rawns.$ns=" "$obs" | head -1 | cut -d= -f2-)
  theirs=$(grep "^host.ns.$ns=" "$hostns" | head -1 | cut -d= -f2-)
  given=$(grep "^host.ns.given=" "$hostns" | head -1 | cut -d= -f2-)
  if [ -z "$mine" ] || [ "$mine" = missing ]; then v=missing
  elif [ "$mine" = "$theirs" ]; then v=host
  elif [ "$ns" = net ] && [ -n "$given" ] && [ "$mine" = "$given" ]; then v=given
  else v=new; fi
  echo "ns.$ns=$v"
done
# 0::/path/to/scope -> 0::<scope>, so the container id does not leak into the
# expectation and make it un-rerunnable.
grep '^obs.cgroup=' "$obs" | sed 's/^obs\.//' | sed 's#/[^/;]*$#/<leaf>#'

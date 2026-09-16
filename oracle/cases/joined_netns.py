# The network namespace given by PATH instead of created.
#
# The runtime-spec says an entry with a `path` means enter that namespace. It
# is the only way a container can be handed a network that was configured
# before its process started -- anything set up afterwards is a race the
# container can lose, and will usually win, which makes the failure rare
# rather than visible.
#
# oracle/core.sh makes /var/run/netns/mrun-oracle and puts a dummy interface
# in it, so "did you join it" is answered by what the container can SEE and not
# only by an inode.
def mutate(spec):
    for n in spec["linux"]["namespaces"]:
        if n.get("type") == "network":
            n["path"] = "/var/run/netns/mrun-oracle"
    return spec

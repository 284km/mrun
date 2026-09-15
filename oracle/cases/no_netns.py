# The network namespace REMOVED from the spec. Every other case asks for all
# six, so a runtime that simply creates all six unconditionally passes them
# all. This is the case that says whether the namespace list is being read.
def mutate(spec):
    spec["linux"]["namespaces"] = [n for n in spec["linux"]["namespaces"]
                                   if n.get("type") != "network"]
    return spec

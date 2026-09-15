# A hostname that is not the default. If a runtime creates a UTS namespace but
# never writes the name into it, `basic` still passes (the default IS "runc")
# and this case does not.
def mutate(spec):
    spec["hostname"] = "not-the-default"
    return spec

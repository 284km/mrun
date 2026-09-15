# A non-zero exit code, and a different cwd and env, all of which have to
# survive the trip back out. An exit status that is always reported as 0 is a
# runtime that looks like it works.
def mutate(spec):
    spec["process"]["args"] = ["/observe.sh", "42"]
    spec["process"]["cwd"] = "/tmp"
    spec["process"]["env"].append("MRUN_CASE=exit42")
    return spec

# mrun

An OCI runtime — `runc`'s job — written in [Mere](https://merelang.org/).

It runs a container, and on the four recorded cases it agrees with `runc` on
**100 of 100 compared fields**: the namespaces it enters, the twenty mounts it
builds, the device nodes in `/dev`, the capability sets, the hostname, the
working directory, the environment, and the exit status.

```sh
export MERE=/path/to/a/merelang/mere/checkout
sh oracle/check.sh basic hostname no_netns exit42
```

```
== basic ==     --> 25/25 fields match
== hostname ==  --> 25/25 fields match
== no_netns ==  --> 25/25 fields match
== exit42 ==    --> 25/25 fields match
TOTAL 100/100 fields across 4 case(s)
```

The check reports field by field rather than pass/fail, because a runtime being
built is partially right and "23 of 24, and here is the one" is the number that
says what to do next. The first run against the oracle scored 19 of 22.

### What the poisons say

A gate that reports 96/96 has to be able to report less. Four deliberate
breakages, each failing in exactly one place:

| break | what goes red |
|---|---|
| create all six namespaces instead of reading the spec's list | `no_netns` only, on `ns.net` |
| never call `sethostname` | `hostname` in all four cases |
| always exit 0 | `exit42` only, on the exit status |
| never call `capset` | `caps` and `capbnd` in all four |

The namespace poison is the one `basic` alone would have missed entirely.

### The field that could not tell the difference

`lo` was added to the recorded observations to make a deliberate divergence
visible: mrun brings loopback up, on the belief that runc leaves it down and
every layer above runc raises it. Two things came out of writing that down.

The first probe read `/sys/class/net/lo/operstate`, which says `unknown` for
loopback whether it is up or down — loopback has no carrier. A field that cannot
distinguish the two states would have recorded the divergence as absent. It
reads the interface flags now (`0x8` down, `0x9` up).

And then the divergence was not one. **runc leaves loopback UP.** mrun had been
missing a step, not adding one, and what said so was the staleness half of the
check — an allowance that no longer differed. The list is empty and the
machinery stays, because an allowance is a claim and this is what checks it.

### Still missing

cgroup resource limits (the container is not placed in a cgroup of its own),
seccomp, rootless/user-namespace mode, the `create`/`start` split — `run` is the
only verb — and `delete`/`state`/`kill`. Each is a case to record from runc
first.

## How it got here

**Nothing ran a container when this repo started.** What this repo currently holds is the
measurement that decides whether the runtime can be written at all, plus the
one C file it will need. That ordering is deliberate: a runtime has to `fork`,
keep running in the child, and then `exec` the container's process, and Mere is
a region-allocated language with no garbage collector. Whether its runtime
survives a `fork` is a question to answer before writing three thousand lines
on top of the assumption.

## The answer

It survives. `probe/probe_fork_exec.mere` checks five things, on macOS/arm64
and on linux/arm64:

| stage | question | result |
|---|---|---|
| 0 | the parent runs, and stdout is not double-buffered into the child | ok |
| 2 | the child is still Mere, and allocates *after* the fork | ok |
| 2b | a `region R { }` opens and rolls back inside the forked child | ok |
| 3 | the child becomes another program via `execv` | ok |
| 4 | the parent reaps it and reads the exit status | ok |

Stage 0 is the poison. If the child inherited an unflushed stdout buffer, the
`begin` marker would appear twice and the probe would fail — so the run that
says "no duplication" has actually looked.

The `P0.x` prefixes on the output lines are just the markers the harness
greps for, anchored so that `child-exec-FAILED` cannot be mistaken for
`child-exec` — a poison run found exactly that bug in the first version.

```sh
export MERE=/path/to/a/merelang/mere/checkout
sh probe/run.sh          # macOS or Linux, natively
sh probe/run_linux.sh    # emit on the host, compile and run in a container
sh probe/run_unix.sh     # AF_UNIX, both
```

## AF_UNIX, and why it is only three functions

`unix_shim.c` is `unix_listen`, `unix_accept`, `unix_connect`. That is the
whole file, because the Mere runtime's `tcp_read` / `tcp_write` / `tcp_close`
turn out to be plain `read(2)` / `write(2)` / `close(2)` against the FFI arena —
they do not care which address family the fd came from. Only the three calls
that have to name `AF_UNIX` were missing.

`probe/probe_unix_socket.mere` checks the byte path is **binary safe**, which is
the half that matters: a Docker socket carries HTTP bodies, and a path that
stopped at the first zero byte would pass a text smoke test and lose data on the
first push. The payload is 5,000 bytes with a zero byte roughly every 256, and
the check is a checksum over every byte received rather than a string compare —
which is exactly the test that would not notice.

## The oracle, recorded before the runtime is written

`runc` is the oracle, so what it does was written down first. `oracle/` drives a
Linux host with cgroup v2 (here the colima VM), builds a bundle, runs `runc`, and
normalises what the container saw into `oracle/expected/<case>.txt`.

```sh
sh oracle/capture.sh basic       # re-record a case from runc
```

The rootfs comes from `docker export`, not from `mtar` — an oracle whose input is
produced by the code under test cannot contradict it. Everything happens in the
Linux host's own filesystem, never a mounted macOS directory, which keeps neither
uid 0 nor a mode-000 file.

**Namespace identifiers are not recorded raw.** They are inode numbers that
change every run, so each is normalised to `new` or `host` by diffing against the
host's own — which is the fact being claimed anyway.

**The first capture was not reproducible.** `visible_pids` came back 4 on one run
and 3 on the next: the count races with the subshells the observation script
itself spawns. It is now `pid=1` (this process is init in its namespace) and
`pids_few=yes` (the host's process table is not visible), both of which hold
still. Three consecutive captures agree before a case is kept.

### The cases, and what each one would catch

Four cases, each isolating a different field — a single case would be passed by a
runtime that hardcodes the defaults.

| case | pins | a runtime that would pass everything else and fail here |
|---|---|---|
| `basic` | pid/mnt/net/uts/ipc/cgroup `new`, user `host`, `pid=1`, 20 mounts, `CapEff`, `nofile` | — the baseline |
| `hostname` | `hostname=not-the-default` | one that creates a UTS namespace but never writes the name into it — the default *is* `runc`, so `basic` cannot see this |
| `no_netns` | `ns.net=host` | one that creates all six namespaces unconditionally instead of reading the spec's list |
| `exit42` | `runc.exit=42`, `cwd=/tmp`, `env_case=exit42` | one that always reports success |

Pairwise they differ in every combination, so no case is redundant.

### Not covered yet

cgroup resource limits, the mount list beyond its length, seccomp, the full
capability sets, rootless/user-namespace mode, and the `create`/`start` split
(these all run through `runc run`). Each is a case to add when the runtime
reaches it.

## What is next

`create` / `start` / `state` / `kill` / `delete` as separate verbs, cgroup
limits, and seccomp — each recorded from runc before it is written.

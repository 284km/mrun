# mrun

An OCI runtime — `runc`'s job — written in [Mere](https://merelang.org/).

**Nothing here runs a container yet.** What this repo currently holds is the
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

## What is next

The runtime itself: `create` / `start` / `state` / `kill` / `delete` against the
[OCI Runtime Specification](https://github.com/opencontainers/runtime-spec), with
`runc` as the oracle — the same bundle handed to both, and everything observable
compared: exit status, output, namespace inodes, cgroup paths and values.

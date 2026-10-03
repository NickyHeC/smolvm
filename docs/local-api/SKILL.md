---
name: local-api
description: "Drives smolvm programmatically over its local HTTP API (smolvm serve) instead of the CLI: create machines, exec and stream commands, move files in and out, and tear them down. Use when building a client, harness, agent tool or MCP backend over smolvm; when a create call is accepted but the machine behaves as if a field was ignored; when a file uploaded over the API has disappeared; when an exec that failed still returned HTTP 200; or when choosing between the Unix socket and loopback TCP. Do not use it as a substitute for the CLI in a shell script, and do not bind a plain listener beyond loopback: a server started without mutual TLS has no authentication of any kind."
---

# Driving smolvm over HTTP

Verified on **smolvm v1.22.2** on macOS arm64, 2026-10-03, and on **v1.18.2** on Linux aarch64, 2026-09-24. Done means a machine went through
its whole lifecycle over HTTP and `GET /api/v1/machines` is empty again at the end.

Two rules run through everything here, and both are the same shape: **a 200 is not a result.**

1. **A failing guest command still returns HTTP 200.** Assert `exitCode` from the body.
2. **Upload files only after the workload container is running.** An upload before that returns
   200 with the resolved path and byte count for a file that is then unreadable.

## Procedure

**1. Preflight.**

```bash
scripts/preflight.sh
```

It reports `auth=none_unless_mtls`, which is not a warning about your setup: a server started the
way this packet starts it has no TLS, token or auth of any kind, so **the transport you pick is the
access control**. Mutual TLS exists, configured from the environment rather than by a flag;
`references/traps.md` has what it does and the plain listener it opens beside itself.

**2. Start the server.** A Unix socket is the default here, as it is smolvm's.

```bash
scripts/serve-start.sh
scripts/serve-start.sh --listen 127.0.0.1:8899
```

It waits for `"status":"ok"` from `/health` rather than for the process to exist, records the
listen address and pid for cleanup, and reports any `Reclaimed N dangling VM data dir(es)` line so
you do not later read those directories as a leak.

**3. Export the spec before writing a request body.** This is the step that saves the most time.

```bash
smolvm serve openapi -o ./openapi.json
```

The field names are the schema's, not the CLI's flags. `network` not `net`, `memoryMb` not
`memory`, and `cmd` for the workload you would pass after `--`. From v1.22.2 an unknown field is
refused with `422` and a message that names it; before that it was accepted with 200 and ignored.
`references/api-fields.md` has the full list and what each wrong name cost on older releases.

**4. Run the lifecycle.**

```bash
scripts/lifecycle-check.sh
```

Create, start, wait for the workload container to answer with a value, exec, exec a deliberately
failing command and assert its non-zero `exitCode` came back on a 200, stream, round-trip a file,
stop, delete, and assert the machine list is empty:

```
created_state=ok (created)
started_state=ok (running)
workload_ready_after_s=0
workload_ready=ok (yes)
exec_exit_code=ok (0)
exec_stdout=ok
failing_exec_exit_code=ok (3)
stream_lines=ok (3)
stream_exit_event=ok
file_roundtrip=ok (PAYLOAD123)
machines_empty=ok ({"machines":[]})
result=lifecycle_ok
```

**5. Clean up, machines first.**

```bash
scripts/cleanup.sh --purge
```

Order matters: **stopping the server does not stop machines**, it orphans them. The script deletes
recorded machines, then stops the server, then removes the socket.

## The calls, in short

```bash
B=http://127.0.0.1:8899   # or: curl --unix-socket "$SOCK" http://localhost/...

curl $B/health
curl -X POST $B/api/v1/machines -H 'content-type: application/json' \
  -d '{"name":"m","image":"python:3.12-alpine","network":true,"memoryMb":2048,
       "cmd":["sh","-c","while true; do sleep 3600; done"]}'
curl -X POST $B/api/v1/machines/m/start -H 'content-type: application/json' -d '{}'
curl -X POST $B/api/v1/machines/m/exec  -H 'content-type: application/json' \
  -d '{"command":["sh","-c","echo hi"]}'
curl -N -X POST $B/api/v1/machines/m/exec/stream -H 'content-type: application/json' \
  -d '{"command":["sh","-c","for i in 1 2 3; do echo line$i; sleep 1; done"]}'
curl -X PUT "$B/api/v1/machines/m/files/%2Ftmp%2Fabs.txt" --data-binary 'PAYLOAD'
curl        "$B/api/v1/machines/m/files/%2Ftmp%2Fabs.txt"
curl -X POST   $B/api/v1/machines/m/stop -H 'content-type: application/json' -d '{}'
curl -X DELETE $B/api/v1/machines/m
```

Paths in the `files` route are **absolute and URL-encoded**. `exec` returns stdout as text and as
base64; `exec/stream` emits one `event: stdout` per line then a terminal `event: exit`.

## Traps

Full detail in `references/traps.md` and `references/api-fields.md`.

- **Upload after the container is up, never before.** Reproduced on Linux aarch64 on v1.14.6: the
  PUT returned `200 {"path":"/tmp/r1.txt","size":6}` and the file was never readable, first with
  `failed to canonicalize target`, then with `failed to read /tmp/r1.txt in the workload
  container`. Both directions pick a namespace per request, and `/tmp` is a path the container
  mounts over. The same sequence on macOS returned the payload.
  **Re-run on v1.16.1 on 2026-09-15 and it did not reproduce on either host**: a machine created
  without a `cmd`, started, then written to immediately, read `ROUND1` back at once on macOS arm64
  and on Lima aarch64, and again at 20 s on Linux. **On v1.18.2 it reproduces again on Linux**,
  with the v1.14.6 messages word for word, and still not on macOS. Order the upload after a
  successful `exec`; a run that happens to work proves nothing.
- **A failing guest command is HTTP 200.**
- **Unknown fields are refused from v1.22.2, and were silently dropped before it.** On v1.22.2 a
  `memory` for `memoryMb` and a `net` for `network` each came back `422` with
  `unknown field ..., expected one of ...`. Before v1.22.2 a `net` was caught at create with a 400
  about the missing network, but a `memory` got no diagnostic at all and the machine silently took
  the default.
- **A second `serve start` on the same host fails** with `bind guest rollout ingress:
  127.0.0.1:10081: Address already in use`, whatever `--listen` says: every server binds that port
  for the branch-pool rollout routes. Set `SMOLVM_GUEST_ROLLOUT_HOST_PORT` to another port for the
  second one.
- **Killing the server orphans machines.**
- **The spec's `info.version` is not the binary's.** It says `0.5.2` on v1.14.2 while `/health`
  says `1.14.2`, and still `0.5.2` on v1.22.2. Take the version from `/health`.
- **The default listen path differs per platform, and `--help` shows only one of them.** The help
  prints `[default: unix:///tmp/smolvm.sock]`, and its own example line says
  `unix:///$XDG_RUNTIME_DIR/smolvm.sock`. Observed on v1.16.1: the socket appeared at
  `/tmp/smolvm.sock` on macOS arm64 and at `/run/user/501/smolvm.sock` on Lima aarch64. Read the
  path the server reports rather than assuming either.

## Pausing a machine over the API

v1.18.0 added `POST /api/v1/machines/{name}/pause` and `/resume`. Pause saves RAM, disks and the
running execution and stops the machine; resume brings back that execution under the same name
rather than booting a fresh guest. On macOS before v1.20.0 the machine has to be started
branchable, which over the API is a query parameter on start, and the calls below always do it:

```bash
curl -X POST "$B/api/v1/machines/m/start?branchable=true" -H 'content-type: application/json' -d '{}'
curl -X POST  $B/api/v1/machines/m/pause  -H 'content-type: application/json' -d '{}'   # state: paused
curl -X POST  $B/api/v1/machines/m/resume -H 'content-type: application/json' -d '{}'   # state: running
```

Assert on a value the workload holds in memory, not on the state field. Measured on v1.18.2 on
both hosts with a workload that writes an incrementing counter every second: it read 9 before the
pause, the machine stayed paused for 10 s, and 3 s after the resume it read 13 on macOS and 12 on
Linux, so the process continued from where it stopped, did not restart at 1, and did not run while
paused. Over the CLI a paused machine refuses `stop` and `start`; the `teardown` packet has those
messages, and `branch-and-checkpoint` covers pause alongside checkpoints.

## Security defaults, and why they are the defaults

- **The Unix socket is the default because it is the only access control a plain server has.** A
  server started without the mutual TLS variables has no TLS, certificate, token or auth of any
  kind, and the routes it exposes create machines, exec arbitrary commands and read and write files. The socket's file permissions are a real boundary;
  a loopback port is a boundary only in the sense that every process on the host is inside it.
- **Loopback TCP is for when you need a URL**, in a container network namespace or for a client
  that cannot do Unix sockets. Treat the port as equivalent to a shell on the host, and do not
  bind anything but `127.0.0.1`.
- **`scripts/serve-start.sh` puts its socket under the packet's own state directory**, not in a
  world-traversable temporary directory, and removes it at cleanup.
- **Machines are deleted before the server is stopped**, because a server shutdown leaves running
  VMs with nothing managing them and no route back to them from the CLI.

## Platform arms

- **macOS arm64** and **Linux aarch64**: the scripts were run here, over the Unix socket.
- **Linux x86_64**: verified in the material behind this packet, over both transports, not re-run
  here.
- **Windows x86_64**: `references/windows.md`, **re-run on 2026-09-11 against v1.14.6** on
  Windows 11 Home build 10.0.26200.0 UBR 9445, where the whole lifecycle passed over loopback TCP.
  No Unix socket form has ever been attempted there, **400 and 404 still return empty bodies**, and
  two shapes fail before reaching a machine: routes live under `/api/v1/`, and a bodiless POST to
  `start` or `stop` needs `application/json` with an empty JSON body.

## Eval prompts, and what they produced

Run on 2026-09-07 PT against v1.14.2 from the published release, under an isolated `HOME`. Output
is verbatim.

**1. "Write me something that drives a smolvm machine over HTTP end to end and proves it worked."**

`scripts/lifecycle-check.sh`, over a Unix socket. All eleven checks passed on macOS 26.6.2 arm64
and on Lima `linux-kvm` (Ubuntu 24.04 aarch64), the Linux one twice in a row. Output as shown in
step 4 above, including `failing_exec_exit_code=ok (3)`, which is the assertion that catches a
guest failure hiding behind a 200.

**2. "I uploaded a file right after starting the machine and now the API says it does not
exist."**

Reproduced on Linux aarch64 by doing exactly that:

```
PUT: {"path":"/tmp/r1.txt","size":6}
GET now: {"error":"agent operation failed: read file: failed to canonicalize target
          /tmp/r1.txt: No such file or directory (os error 2)","code":"INTERNAL_ERROR"}
GET after 30s: {"error":"agent operation failed: read file: failed to read /tmp/r1.txt in
          the workload container: open /tmp/r1.txt: No such file or directory (os error 2)",
          "code":"INTERNAL_ERROR"}
```

The upload reported success for a file that was never readable. The same sequence on macOS arm64
returned `ROUND1` both immediately and after 30 s, so a run that works proves nothing.

**3. "My create call returned 200 but the machine has the wrong settings."**

Verified on both hosts on v1.18.2: a body carrying an unknown field is accepted and the field is
dropped.

```
POST {"name":"...","image":"alpine","network":true,"memoryMb":2048,"bogusField":1}
-> 200 {"name":"...","state":"created","network":true,"memoryMb":2048,...}
```

On v1.22.2 the same mistake is refused before anything is created:

```
POST /api/v1/machines {"name":"...","image":"alpine","network":true,"memory":1024}
-> 422 Failed to deserialize the JSON body into the target type: memory: unknown field `memory`,
   expected one of `name`, `cpus`, `memoryMb`, `mounts`, `ports`, `network`, ... at line 1 column 63
```

and the runbook's `net`/`memory` shape was caught at create on both hosts, with a message that
names the remedy:

```
400 {"error":"config operation failed: create machine: image 'alpine' must be pulled from a
registry, but this machine has no network, so the pull can never succeed. Add --net ...",
"code":"BAD_REQUEST"}
```

A 404 on either host returns `{"error":"machine 'nope-does-not-exist' not found",
"code":"NOT_FOUND"}`, which is the diagnostic Windows does not give you.

## Re-verified on v1.22.2

Run 2026-10-03 PT against v1.22.2 from the published release, checksum checked, the installed
`smolvm-bin` identical to the tarball's, under an isolated `HOME` on macOS 27.0.1 arm64, twice: once
to write, once from a fresh `HOME` to verify. On Lima `linux-kvm` (Ubuntu 24.04 aarch64) the same
day, the release booted 2048 MiB and timed out at 4096 and 8192, and later in the day, with the Mac
paging, it timed out at 2048 too, so the Linux verify pass could not run; the Linux lines below are
from a single run and the Linux stamp stays on its earlier release.

macOS: `result=lifecycle_ok` over loopback TCP and the Unix socket, a `memory` and a `net` field
each refused with `422`, the upload race 0 of 3, and pause and resume over the API with the counter
at 11 before a 10 s pause and 15 three seconds after the resume. The spec still says
`info.version 0.5.2`. Mutual TLS and the second-server port are in `references/traps.md`.

Linux aarch64: both `422` refusals word for word and the upload race 0 of 3. The lifecycle failed
only at `machines_empty`, on two `image-seed-*` helpers an interrupted run had left in the list.

## Re-verified on v1.18.2

Run 2026-09-24 PT against v1.18.2 from the published release, under an isolated `HOME`, on macOS
26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04 aarch64), over the Unix socket.
**`result=lifecycle_ok` on both, all eleven checks green**, including
`failing_exec_exit_code=ok (3)`. `/health` said `"version":"1.18.2"` and the spec `0.5.2`.

What moved:

- **The upload trap is back on Linux.** A machine created with no `cmd`, started, then written to
  at once:
  ```
  PUT: {"path":"/tmp/r1.txt","size":6}
  GET now: {"error":"agent operation failed: read file: failed to canonicalize target /tmp/r1.txt: No such file or directory (os error 2)","code":"INTERNAL_ERROR"}
  GET +20s: {"error":"agent operation failed: read file: failed to read /tmp/r1.txt in the workload container: open /tmp/r1.txt: No such file or directory (os error 2)","code":"INTERNAL_ERROR"}
  ```
  The same sequence on macOS read `ROUND1` both times.
- **A directory path in the files route returns a listing** (#1330): `GET .../files/%2Fetc%2Fapk`
  gave `{"entries":[{"kind":"file","name":"arch","size":8},{"kind":"dir","name":"keys","size":0},...]}`
  on both hosts.
- **Pause and resume**, as in the section above.
- **Unchanged:** a body with `memory` for `memoryMb` and a `bogusField` was accepted and came back
  with `"memoryMb":8192`, the default.

## Re-verified on v1.14.6

Run 2026-09-10 PT against v1.14.6 on macOS 26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04
aarch64), over the Unix socket. **All eleven checks green on both**, including
`failing_exec_exit_code=ok (3)`, the case that proves a guest failure arrives on an HTTP 200.

## What was not run

- **The Unix socket form on Windows.** The 2026-09-11 v1.14.6 re-run there used loopback TCP, as
  every Windows run has.
- **Linux x86_64.**
- **Loopback TCP.** `serve-start.sh` accepts `--listen 127.0.0.1:8899` and the code path is the
  same, but every run here used the Unix socket.
- **A client of a mutual TLS server driving the lifecycle.** The handshake was checked on v1.22.2,
  a client without a certificate refused and one with a certificate answered on `/health`, but no
  machine was created over it.
- **The pool and rollout-executor routes** in the spec. They belong to the branch-pool feature.

## Related packets

- `install` for the boot this assumes, `teardown` for the cleanup script.
- `dev-env` for the same lifecycle through the CLI, and for the workload-container behaviour that
  the `cmd` field addresses here.

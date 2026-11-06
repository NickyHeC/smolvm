# Rewind traps

Each entry was hit on v1.33.0 on 2026-11-05 unless it says otherwise.

## Contents

- A restored machine takes no credential value from its environment
- A rewound machine that was stopped comes back cold, and without its values
- launchd cannot read under Documents, Desktop or Downloads
- launchd's StartInterval and systemd's AccuracySec both stretch a slot
- A coding agent's in-flight call after a rewind
- Codex reads CODEX_API_KEY and tries a WebSocket first
- A capture refused: the errors to expect
- The timer follows the old machine until you move it
- The window across a rewind has a seam
- A window can only get longer than you asked
- `lineage/` grows by one record per capture
- A capture refused: an exec that met a pause
- On Linux the first capture pauses for long, and the source's clock falls behind
- `--keep-identity` and two running machines
- smolvm keeps the last restored checkpoints
- `pkill -f` inside `machine exec` kills the exec

## A restored machine takes no credential value from its environment

Restored from a checkpoint, a binding's value "comes only from" the API. The record is marked
`credentials_supplied_by_api`, and the launcher points the binding at a private variable and removes
it, so the host variable of that name is never read: a checkpoint chose both the variable and the
destination, and honouring them would let it send a host secret anywhere. With the variable set in
the environment of `machine start`, the guest's request answers:

```
smolvm credentials: credential unavailable        (HTTP 502)
```

`--credential` on the restore is refused:

```
Error: config operation failed: create from .smolcheckpoint: a live checkpoint keeps the credential
bindings it was captured with; --credential applies only to a machine created from an image or a pack
```

The route that works is `PUT /api/v1/machines/<name>/credential-values` before `POST
/api/v1/machines/<name>/start`, on one server, since the values live in that server's memory.
`scripts/start-supplied.sh` runs a private server for exactly that, and the machine keeps running
and keeps its value after the server exits. On v1.33.0 the `PUT` holds values for the next boot only,
so it has to come before the first start, and a machine already started without them has to be
rewound again. Source after v1.33.0 at 6358d287 (#2072) also pushes a `PUT` to a running machine;
that was read, not run. An agent that runs into the 502 retries five times per call and fails its
turn; it spends nothing, since the request never leaves the host.

## A rewound machine that was stopped comes back cold, and without its values

`machine stop` ends the restored processes, as for any machine, and the next `machine start` is a cold
boot in which the restored record is still marked supplied-only: `/dev/shm` empty, and the same 502 with
the variable set. `scripts/start-supplied.sh --name <machine> --supply <BINDING>=<VAR>` starts it with
its values. Disks survive.

## launchd cannot read under Documents, Desktop or Downloads

A job whose script lives under `~/Documents`:

```
/bin/bash: /Users/you/Documents/.../p.sh: Operation not permitted
```

exit 126, nothing in `capture.log`, and no prompt. `timer.sh` copies `capture.sh` into the window
directory, so it is the window and the `smolvm` binary that have to live elsewhere, and `preflight.sh`
checks both.

## launchd's StartInterval and systemd's AccuracySec both stretch a slot

`StartInterval` counts from the end of the last run: at 30 s with a 5 s capture the slots came 35 s
apart, so a rewind could land 37 s from the moment asked for. `timer.sh` uses `KeepAlive` with
`ThrottleInterval`, which relaunches 30 s after the last start. Unified logging then says the job
"only ran for N seconds"; that is the mechanism working.

systemd's `AccuracySec` defaults to one minute, so `timer.sh` sets `AccuracySec=1s`, and it uses
`OnUnitActiveSec`, which also counts from the last start. Both forms keep one run at a time.

## A coding agent's in-flight call after a rewind

A rewound process is alive, under the same PID, and holds the connection it had, now to nothing. What
Codex CLI did, four times on macOS on v1.33.0: the driver loop and the `codex` process in flight both came
back under their PIDs, and the `codex` process finished its step with exit 0, 2 to 30 s after the
restore. Where a model call was in flight it logged one retry and carried on:

```
Reconnecting... 1/5 (stream disconnected before completion: Transport error: timeout)
Reconnecting... 1/5 (stream disconnected before completion: idle timeout waiting for SSE)
```

No step number was lost or repeated, and one restored run went on to finish its 50 steps with its 50
tests passing. The retry is the agent's own: smolvm does nothing here, so a client with no retry sees a
dead connection. A request the source had already sent reaches the server a second time when it is
retried, so anything with an effect outside the machine has to tolerate that.

## Codex reads CODEX_API_KEY and tries a WebSocket first

Codex CLI 0.167.0 with only `OPENAI_API_KEY` set answers `401 Missing bearer or basic authentication`.
Give the placeholder to `CODEX_API_KEY`. It then tries the Responses WebSocket, which the interceptor
refuses on a credential host, logs `failed to connect to Responses WebSocket` in its stderr, and falls
back to HTTP streaming, which works. It also asks `chatgpt.com` for its model list with the
placeholder, and that host answers 401: the placeholder travels there as a literal string and is
worth nothing to it. Neither stops the run.

## A capture refused: the errors to expect

Bound to this host:

```
Error: config operation failed: checkpoint machine: the initial portable checkpoint profile does not
support host mounts, host secret references, SSH agent forwarding; stop or detach these resources
before capture
```

`--host-mounts` takes `host mounts` off that list and leaves the others. A source frozen as a branch
base:

```
Error: agent operation failed: checkpoint machine: machine 'x' is frozen as a branch base; it can
only be captured as a full standalone checkpoint
```

The timer logs either as `result=FAILED` with the text, and deletes nothing.

## The timer follows the old machine until you move it

`timer.sh retarget` is the move, read by the next capture. Until then the window keeps following the
source, which may be the machine you rewound away from.

## The window across a rewind has a seam

After `retarget`, the chain runs through the generation you rewound to, so the history reads captures
of the new machine, then that generation, then what led to it. The stretch between that generation and
the rewind is on no chain of the new machine, and a rewind asking for a moment there lands before it,
further than one interval away, with `note=the nearest capture is ...`. Those generations stay
reachable only through the old machine's directory, until `timer.sh drop`.

## A window can only get longer than you asked

`--history` counts captures, not minutes, so a skipped slot stretches it. A host that sleeps stops the
timer, and the window then spans the nap: on waking `--ago 5m` may land much earlier, and
`distance_from_asked_s` says by how much.

## `lineage/` grows by one record per capture

One file of about 230 bytes per capture in `<dir>/store/lineage`, and prune does not remove them: 42
after 26 minutes. At 30 s that is 2,880 a day, about 11 MiB by 4 KiB block. `checkpoint-log --store` took
16 ms at 42 records. A window running for weeks was not measured. Removing the window removes them.

## A capture refused: an exec that met a pause

On Linux, a `machine exec` that cannot reach the guest agent during a capture's pause fails with

```
Error: agent operation failed: connect: machine 'x' is not running. Start it with 'smolvm machine start
--name x'; if a start is already in progress, retry once it finishes.
```

and marks the machine `unreachable` in smolvm's database. Nothing clears that mark while the machine
runs: `machine list` keeps saying `unreachable`, `machine status` says `running`, a later exec works, and
every capture from then on fails with

```
Error: agent operation failed: checkpoint machine: machine 'x' must be running
```

An exec waits 3 s for the agent, so a pause or a busy agent past that is what it takes. On nested KVM with
a 4 GiB machine, whose pauses ran 0.6 to 4.4 s, an exec a second hit it in about a minute and a single exec
hit it once. On a Mac, where pauses are about 0.1 s, 60 captures under a tight exec loop did not, and neither
did 25 at 1 GiB on Linux. A machine in this state is fine and its window stays good up to the last capture, so:
rewind to a new machine and `timer.sh retarget` to it. `machine stop` then `start` clears it too, and loses
RAM. An exec that was already connected before the pause is not what was seen failing.

The same `must be running` also comes once on its own, with no exec, in the slot right after a long first
capture on Linux, and clears by itself.

## On Linux the first capture pauses for long, and the source's clock falls behind

On nested KVM at 4 GiB the first capture paused the source for 22 s and 32 s in two runs, and took 36 s and
53 s. After that pauses ran 0.6 to 4.4 s, median 1.65 s. Why the first is so long was not established, and
a host that is not nested was not run.

The guest's clock does not catch up with those pauses: 80 s behind the host after 15 minutes, on the source.
A rewound machine starts within 3 s of the host, and its timers then run out early, so a line of work can land
a few seconds sooner than it did on the source: one rewound machine read counter 405 with 19 commits where
the source had 18 until counter 407. On a Mac the source's clock stayed with the host and the values matched
exactly.

## `--keep-identity` and two running machines

With it, the restored machine keeps the source's hostname and machine ID, which is what a replacement
wants and what a comparison beside the running source does not: the flag's own help says not to run
two machines from one checkpoint with it. Without it, the machine takes its own name as its hostname.

## smolvm keeps the last restored checkpoints

`vms/_restore-checkpoints` can hold recently restored checkpoints, RAM included, and outlives them. The
4 GiB runs left none on v1.33.0 and a 1 GiB run did, for a reason not worked out. `cleanup.sh --restore-base`
removes it either way.

## `pkill -f` inside `machine exec` kills the exec

`machine exec --name x -- sh -c 'pkill -f drive.sh'` matches its own shell, whose command line holds
the string, and the exec returns 143. Kill by PID.

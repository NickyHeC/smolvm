---
name: rewind
description: Keeps a rolling window of stored checkpoints of a running smolvm machine on a timer, and brings the machine back as it was at any capture in the past 10 minutes, with the processes in it still running, as a new machine. Use when an agent or a job works inside a machine and a bad step has to be undoable; when someone asks to go back a few minutes; when a project inside a machine was wrecked and the machine is still up; or when a timer has to capture every 30 seconds, which cron cannot do. Do not use it to keep state beyond the window or across hosts, which is branch-and-checkpoint and pack, or for a machine with a host secret reference, an SSH agent or a GPU, which a capture refuses.
---

# Rewinding a machine

Verified on **smolvm v1.33.0** on macOS arm64, 2026-11-05, with Codex CLI working in the machine, and
on Linux aarch64, 2026-11-06, with a scripted stand-in workload, not an agent. Done means `status.sh`
shows `oldest_age_s` at or above 600, and a rewound machine has the RAM token and the counter the
source held at that capture, and is still doing what it was doing.

`README.md` says what a window is. This file is how to run one, and the traps.

**Three facts shape everything here.**

- **It lands on a capture, not on any moment.** A rewind comes back at most one interval before the
  moment asked for, and says how far.
- **A rewind makes a new machine.** The source keeps running, and the timer keeps following it until
  you move the timer.
- **A restored machine takes no credential value from its environment.** `machine start` cannot give
  it one. `scripts/start-supplied.sh` can, and `rewind.sh --supply` calls it.

## Procedure

```
- [ ] 1. preflight.sh               the host, the timer, the room
- [ ] 2. start-machine.sh           a machine a capture will accept
- [ ] 3. timer.sh install           a capture every 30 s, 10 minutes kept
- [ ] 4. status.sh                  what the window holds
- [ ] 5. rewind.sh                  a new machine, from a moment in the window
- [ ] 6. timer.sh retarget          the timer follows the machine you kept
- [ ] 7. cleanup.sh                 timer, machines, window
```

**1. Preflight.** Read-only. `<dir>` is the window directory: it holds the store, the newest capture
and the log. The defaults are 30 s and 600 s; `--every` and `--window` change them.

```bash
scripts/preflight.sh --dir ~/rewind/agent
```

`result=ready` is the last line. `dir_readable_by_timer=no` blocks on a Mac: a launchd job gets
`Operation not permitted` under `~/Documents`, `~/Desktop` and `~/Downloads`, so the window and
smolvm itself have to live elsewhere. The basename of `<dir>` names the timer, so give each window
its own.

**2. A machine a capture will accept.**

```bash
export OPENAI_API_KEY=...   # however your secrets manager hands it over
scripts/start-machine.sh --dir ~/rewind/agent --name agent \
    --credential openai=OPENAI_API_KEY@api.openai.com \
    --install 'apt-get update -qq && apt-get install -yqq git python3 curl ca-certificates >/dev/null && npm install -g --silent @openai/codex'
```

Defaults: `node:22-bookworm-slim`, 4 CPUs, 4096 MiB, network on. It starts `--branchable`, and starts
a token and a one-second counter in `/dev/shm`, which is RAM, so step 5 can show memory came back.

**The `coding-agent` packet's machine as written is refused**, for its `-v`, its `--secret-env` and
its SSH agent:

```
Error: config operation failed: checkpoint machine: the initial portable checkpoint profile does not
support host mounts, host secret references, SSH agent forwarding; stop or detach these resources
before capture
```

So here the key is a `--credential`, which a capture carries (the guest holds only a placeholder),
and the project lives inside the machine. Published sockets, custom DNS, named networks, GPU and
Docker sockets are refused the same way. Your own machine works if it has none of those; name it in
step 3.

**Run the agent inside it detached, so the exec can return and the process outlives it.** Codex CLI
reads its key from `CODEX_API_KEY`, not `OPENAI_API_KEY`:

```bash
smolvm machine exec --name agent -- sh -c 'mkdir -p /root/proj && cd /root/proj && git init -q . &&
  CODEX_API_KEY="$OPENAI_API_KEY" nohup codex exec --json --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox "<your task>" </dev/null >/root/agent.jsonl 2>/root/agent.err &
  echo $! > /root/agent.pid'
```

**3. The timer.** launchd on a Mac, a systemd user timer on Linux. cron's floor is one minute.

```bash
scripts/timer.sh install --dir ~/rewind/agent --name agent --every 30 --window 600
```

```
timer=launchd label=smolvm-rewind-agent plist=.../LaunchAgents/smolvm-rewind-agent.plist
machine=agent every_s=30 window_s=600 history=20
result=installed
```

Each run is `scripts/capture.sh`, one capture, read back from `checkpoint-log` before anything older
is deleted, then a prune. It takes its settings from `<dir>/rewind.conf` every time, needs no key,
and a copy of it sits in `<dir>` because launchd may not read your checkout. Every run adds one line
to `<dir>/capture.log`. The window fills in the first 10 minutes.

**4. Status.** Read-only.

```bash
scripts/status.sh --dir ~/rewind/agent
```

`generations` should reach 21 (the capture and its 20 earlier), `oldest_age_s` should stay at or
above 600 after that, and `failed` should stay 0. `last=` carries the capture time, the source pause
and the store size, or the engine's error.

**5. Rewind.**

```bash
scripts/rewind.sh --dir ~/rewind/agent --ago 5m --name agent-b --supply openai=OPENAI_API_KEY
```

```
source=agent
asked_ago_s=300
generation=f259659132ae
generation_time=1793950311
generation_age_s=313
distance_from_asked_s=13
credentials_supplied=1
seconds_to_first_answer=5
ram_token=074ccb601e022e89
ram_counter=642
result=rewound
```

`--ago` takes `90`, `90s`, `5m`, `9m30s` or `1h`. It selects by id, since `~N` moves with every
capture, and holds the capture lock while it reads, so the timer cannot delete what it is reading;
a slot that falls there logs as `skipped`. `--supply <BINDING>=<VAR>` names the binding from step 2
and the variable in your environment that holds its value; a machine with no bindings needs none.
A restored machine takes its own name as its hostname; `--keep-identity` keeps the source's hostname
and machine ID, and is for a machine you are replacing, not one you are comparing.

Check values, not the exit code: `ram_token` must be the source's and `ram_counter` must be the value
it held at `generation_time`. Then check what the machine was doing, which is yours to name:

```bash
smolvm machine exec --name agent-b -- sh -c 'cat /root/agent.pid; [ -d /proc/$(cat /root/agent.pid) ] && echo alive; wc -l /root/proj/PROGRESS'
```

**6. Keep the rewound machine.** The timer still follows the source, so it has to move. Once the new
machine has a capture, the old machine and its last capture can go; dropping that directory is what
gives up the generations after the moment you rewound to.

```bash
scripts/timer.sh retarget --dir ~/rewind/agent --name agent-b
scripts/status.sh --dir ~/rewind/agent             # wait until generations is above 0
smolvm machine stop --name agent && smolvm machine delete --name agent --force
scripts/timer.sh drop --dir ~/rewind/agent --name agent
```

The new machine's first capture lists the generation it came from as its `~1`, and the window carries
on through it: a rewind across that seam says so with a `note=`, since the nearest capture can be
more than an interval away.

**7. Clean up.**

```bash
scripts/cleanup.sh --dir ~/rewind/agent --restore-base
```

It removes the timer, deletes the machines the scripts recorded, removes the window, and with
`--restore-base` removes smolvm's copies of restored checkpoints, which hold RAM and outlive
everything else. A machine you created yourself and only named to the timer stays.

## What came back, and what it cost

Measured on macOS 27.2 arm64, v1.33.0, 2026-11-05, in pass 2: Codex CLI 0.167.0 with `gpt-5.4-nano`
in a 4 GiB machine, building a small package one numbered step at a time, a commit and a line in
`PROGRESS` per step, under the launchd timer at 30 s for 18 minutes. The source's own record, written
inside the guest every 2 s, is what each value was checked against.

| asked | generation age | from the moment asked | RAM counter | commits | source's record at that counter | first answer | after |
|---|---|---|---|---|---|---|---|
| 1m | 83 s | 23 s | 855 | 38 | 855: 38 | 3.3 s | next step in 24 s; finished 50 of 50, tests passing |
| 5m | 313 s | 13 s | 642 | 30 | 641, 643: 30 | 4.5 s | next step in 13 s |
| 9m30s | 592 s | 22 s | 370 | 18 | 369: 17; 371: 18 | 4.8 s | next step in 2 s |
| 47s, after `rm -rf /root/proj` | 75 s | 28 s | 946 | 42 | 945, 947: 42 | 3.7 s | project back, tests passing; next step in 30 s, one retry |

The RAM token matched in all four, the agent's loop was alive under its PID, 3773, and the Codex process
in flight finished its step. `curl` with the placeholder answered 200 from the real API in all four,
through `--supply`. The guest's value hashed different from the real key.

| over 37 captures, none skipped, none failed | |
|---|---|
| window | fills at 10 minutes, then `oldest_age_s` 631 to 722 |
| source pause | 0.070 s min, 0.117 median, 0.447 max |
| capture | 2.8 s at 2 generations, 3.9 at 10, 4.7 at 15, 5.6 at 21, 7.5 at the most |
| written per capture | 1,098 MiB the first, then 160 MiB, which is about 460 GiB a day at 30 s |
| window on disk | levels at 4.2 to 4.4 GiB; 3.7 GiB in pass 1, at 130 MiB a capture |
| capture process | 88 MiB peak RSS, 7.5 CPU-seconds, so 24% of one core of ten; prune is negligible |
| the running VM | 2.3 GiB peak RSS, 18 MB physical footprint, since guest RAM is file-backed; 7.6% of one core |
| the machine's data | 2.7 GiB by `checkpoint-log`: guest RAM mostly page cache, 1.1 GiB of disk |

The agent felt none of this that could be measured: no API error before a rewind, every step exit 0,
the guest's own 2 s record never more than 3 s apart, and step rates at the same context size within
noise of machines with no timer (2.45 against 2.53 steps a minute at steps 30 to 34, 2.86 against 2.69
at steps 14 to 21).

Why capture time and bytes look like this: RAM is read for every capture, unchanged chunks are reused
rather than written, and each retained generation adds about 150 ms. A machine with more real data,
or that changes more of it, costs more; these numbers belong to this workload.

## Traps

Full detail in `references/traps.md`. The ones that cost the most:

- **`502 smolvm credentials: credential unavailable` on a rewound machine** means it was started
  without `--supply`. The variable being set does not help, and `--credential` on `machine create
  --from` is refused. A rewound machine that was stopped needs `scripts/start-supplied.sh` for the
  same reason, and it comes back as a cold boot, without the RAM.
- **A capture that fails names the reason in `capture.log`**, and deletes nothing. A frozen source
  fails every capture: `machine 'x' is frozen as a branch base; it can only be captured as a full
  standalone checkpoint`. So `machine branch --freeze-source` stops the window until the source is
  gone.
- **A timer that seems to do nothing on a Mac** is usually `Operation not permitted` in
  `<dir>/timer.out`: the window or smolvm lives under `~/Documents`, `~/Desktop` or `~/Downloads`.
- **On Linux a `machine exec` that meets a capture's pause can stop the window.** The exec fails with
  `connect: machine 'x' is not running`, smolvm records the machine as unreachable and keeps it so,
  though it runs and later execs work, and every capture then fails with `must be running`. A restart
  clears it and loses RAM, so rewind instead: the window still holds everything up to the last capture.
  It takes a pause past the exec's 3 s wait: hit in about a minute with an exec a second, at 4 GiB on
  nested KVM, where pauses are 0.6 to 4.4 s. Not hit on a Mac, in 60 captures under a tight exec loop.
- **`pkill -f drive.sh` inside `machine exec` kills the exec's own shell**, whose command line holds
  the string, and the exec returns 143.

## Security defaults, and why they are the defaults

- **A checkpoint is the machine's memory and disks.** Anything the workload held is in it, and the
  scripts set `umask 077`. Keep the window on a disk only you can read.
- **A credential value is in no checkpoint and no script's log.** `start-supplied.sh` sends it to a
  private server over a Unix socket in a mode-700 directory, in a request body on standard input,
  never on a command line, and the server exits once the machine has started.
- **Retention deletes only after the new capture is published.** A failed capture never leaves you
  with less than you had.
- **A window is local.** It protects against a bad step, not a lost host; `machine checkpoint
  --export-from` makes a file you can copy away.
- **Cleanup deletes only machines the scripts recorded.**

## Platform arms

`references/platforms.md`.

## Status

Written from pass 2 only.

| Surface | Status on v1.33.0 |
|---|---|
| macOS arm64, native, a real agent | **VERIFIED**: every step, Codex CLI through the credential interceptor |
| Linux aarch64 (Lima, nested KVM), a stand-in workload | **VERIFIED**: every step, a real systemd user timer, `--supply` with a throwaway value; see the exec trap, which ends a window here |
| An agent on Linux | not run |
| Linux x86_64 | not run |
| Windows | not run; `branch-and-checkpoint` records that `--store` is refused there |
| smol cloud | not run |

## What was not run

- **A window for hours or days.** 18 minutes on macOS and 15 on Linux; store growth past that is reasoned
  from a plateau.
- **Linux outside nested KVM**, so its pauses, its long first capture and the exec trap are this box's.
- **A host that sleeps**, with the timer stopped across it.
- **A long-lived single Codex turn.** Asked for 40 and 80 steps in one turn, `gpt-5.4-nano` stopped after
  3 steps each time, so a small loop handed it the next step with `codex exec resume --last`. Each `codex`
  process lived 15 to 25 s, and several were restored mid-call, so the restore path ran; one process
  living through many captures did not.
- **`machine branch` of a rewound machine**, and a rewound machine moved to another host.
- **The live credential push of #2072**, which is after v1.33.0 and was read, not run.

## Related packets

- `branch-and-checkpoint` for one-off captures, keeping a chosen history, pause and resume, branches.
- `credentials` for how a binding works and how to prove the value stayed out.
- `coding-agent` for an agent with your project mounted, which a capture refuses.
- `teardown` for the wider cleanup.

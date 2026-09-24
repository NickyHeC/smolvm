# Branching and checkpointing

Two ways to reuse a machine's state. A **branch** is a live fork: an independent copy-on-write
child that resumes with the source's running processes, memory and disk. A **checkpoint** is a file
you restore later.

`SKILL.md` is the agent procedure: scheduled captures with retention, restores of any generation,
pause and resume, and branch points kept as checkpoints, with the scripts that run them.
`references/incremental-checkpoints.md` and `references/pause-resume.md` are the engine's own
detail, and `references/scheduling.md` puts a capture under cron, systemd or launchd.

## Checkpoints keep a history

With `--store <dir>`, `machine checkpoint` writes a directory that shares unchanged chunks with
earlier captures in the same store and **retains** up to `--history` earlier generations, 32 by
default, so any of them restores from the newest directory alone, even after the older directories
are deleted. `machine checkpoint-log <checkpoint>` lists them as `~0`, `~1`, `~2`, and
`machine create --from <checkpoint> --at ~2` restores two back. `--export-from` writes one portable
file that carries the retained history.

**smolvm has no scheduler and no retention.** Periodic checkpoints are an external timer running
one capture at a time per machine, each to a new output name, with old directories deleted only
after the new one is published and `machine checkpoint-prune --store <dir>` run afterwards.
`--keep` on directories frees nothing that a kept checkpoint still retains, so bound `--history`
too.

## Restores are copy-on-write

A restored machine's disks are layered over the checkpoint's rather than copied: on macOS three
restores of one checkpoint cost about 29 MB of disk each while `du` reported five times that, and
on Linux each restored machine holds small `qcow2` layers over the checkpoint's disks. On macOS
smolvm also keeps a clone of the most recently restored checkpoint in its VM cache,
`vms/_restore-base`, so the next restore writes only what differs; it holds that checkpoint's
memory and outlives every machine and checkpoint file, so remove it when you remove them.

## Branchability is decided at start

```bash
smolvm machine start  --name source --branchable
smolvm machine branch --from source --name child
```

A machine started without `--branchable` refuses to branch, and the message says branchability is
decided at start time and cannot be turned on for a machine that is already running. There is no
`machine create --branchable`: it is a `start` flag. On macOS **`machine checkpoint` and `machine
pause` need the same thing**, and when the source was not started that way the error is
`guest RAM has no file-backed regions`, which names neither the flag nor the precondition. Linux
checkpoints and pauses without it.

## Fanning out many children

The source's workload marks the point to fork by running `smolvm-branch-ready` once its setup is
done, naming the program each child should run:

```bash
smolvm machine create --name source --image python:3.12-alpine --net -- sh -c '
  pip install -q requests
  python3 serve.py &
  exec smolvm-branch-ready -- python3 episode.py'

smolvm machine start  --name source --branchable
smolvm machine branch --from source --count 8 --name-prefix worker --parallel 8
```

The helper blocks in the source, which stays parked there, and hands off to the named program in
each child. That program starts with `SMOLVM_BRANCH_NAME`, `SMOLVM_BRANCH_INDEX`,
`SMOLVM_BRANCH_BATCH_ID` and `SMOLVM_BRANCH_BATCH_SIZE` in its environment, plus any `--env` the
branch command passed. A shell script that wants to continue inline runs
`eval "$(smolvm-branch-ready)"` instead, which is the same command printing those variables as
`export` lines. `machine exec` sessions in a child see them too.

## Pausing a machine

`machine pause` saves a machine's RAM, disks and running execution and stops it; `machine resume`
brings that execution back under the same name rather than booting a fresh guest. Use it to stop a
machine without losing what is running, and `checkpoint` when you want a separate artifact and the
source to keep running. The machine must support portable checkpoints, so on macOS it has to have
been started `--branchable`. `references/pause-resume.md` is the detail.

## Keeping the branch point

A branch's captured state stays on the host that made it and cannot be exported, so take a
checkpoint at the same point when the starting state has to outlive the children. For a batch,
that point is the source parked in `smolvm-branch-ready`: a checkpoint taken there holds exactly
what every child starts from. Restoring it does not give back a parked source, though: the helper
releases on start and runs the child program with an empty `SMOLVM_BRANCH_NAME`, so fan out from
a restored branch point with single `--name` branches.

## Restoring a checkpoint

The restore path is `machine create --from`. **There is no `machine restore` subcommand.** A
restored machine packs like any other, and carries its rootfs.

## Packing a branch

A branched machine packs from v1.16.1 on, and the artifact carries both the state it inherited and the
state written after the branch. It has to be stopped first. See `docs/pack/`.

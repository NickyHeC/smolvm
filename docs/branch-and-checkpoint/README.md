# Branching and checkpointing

Two ways to reuse a machine's state. A **branch** is a live fork: an independent copy-on-write
child that resumes with the source's running processes, memory and disk. A **checkpoint** is a file
you restore later.

There is no `SKILL.md` for this topic yet. The surface is still moving, and the agent procedure
follows as its own packet once it settles; `references/incremental-checkpoints.md` is the detail
that exists today.

## Branchability is decided at start

```bash
smolvm machine start  --name source --branchable
smolvm machine branch --from source --name child
```

A machine started without `--branchable` refuses to branch, and the message says branchability is
decided at start time and cannot be turned on for a machine that is already running. There is no
`machine create --branchable`: it is a `start` flag. On macOS **`machine checkpoint` needs the same
thing**, and when the source was not started that way the error is
`guest RAM has no file-backed regions`, which names neither the flag nor the precondition.

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

## Restoring a checkpoint

The restore path is `machine create --from`. **There is no `machine restore` subcommand.** A
restored machine packs like any other, and carries its rootfs.

## Packing a branch

A branched machine packs on v1.16.1 and the artifact carries both the state it inherited and the
state written after the branch. It has to be stopped first. See `docs/pack/`.

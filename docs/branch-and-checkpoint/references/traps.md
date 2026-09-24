# Checkpoint, restore, pause and branch traps

Each entry was hit on v1.18.2 on 2026-09-24 unless it says otherwise.

## Contents

- `--branchable` is decided at start, and macOS needs it for more than branching
- `--output` must end in `.smolcheckpoint`, even when it is a directory
- The exit code of a capture is not the proof
- `--keep` does not bound the store on its own
- A restored branch point is not a parked source
- Detecting a parked source: `pgrep -f` always matches
- `machine list | grep -q` under `pipefail`
- A paused machine refuses `stop` and `start`, and a failed resume can be retried
- A full disk leaves machines that `delete --force` will not remove
- `du` overstates what a restore costs
- smolvm keeps the last restored checkpoint after you delete it
- `machine stop` on a missing name leaves an empty directory
- Environment given to a restore reaches `exec`, not the resumed workload

## `--branchable` is decided at start, and macOS needs it for more than branching

`machine branch` against a machine started without it, on either host:

```
Error: agent operation failed: fork: machine 'smolskill-sfx' was not started as branchable, so it
has no copy-on-write memory to branch from. Restart it with `smolvm machine start --name
smolskill-sfx --branchable`; branchability is decided at start time and cannot be turned on for an
already-running machine.
```

That message is clear. The macOS one for `checkpoint` and `pause` is not:

```
Error: agent operation failed: checkpoint machine: libkrun save failed: ERR EIO capture VM: VM
snapshot/restore failed: retain COW guest-memory generation: guest RAM has no file-backed regions
```

`pause` prints the same text, because a pause is a checkpoint underneath, and the machine keeps
running. On Linux aarch64 both succeeded without the flag: a checkpoint of 55 MiB with a 1.242 s
pause, and a pause and resume. Start every machine you might checkpoint with `--branchable`.

## `--output` must end in `.smolcheckpoint`, even when it is a directory

```
Error: config operation failed: checkpoint machine: output must end in .smolcheckpoint
```

for `-o ./x.checkpoint`, and the same for `--store ./st -o ./inc1`, where the output is a directory
and the help calls it one.

## The exit code of a capture is not the proof

A capture is usable once it has been durably published, which `checkpoint-log <output>` shows as the
`~0` line ending `(this checkpoint)`. `scripts/checkpoint.sh` reads that back before it deletes any
older checkpoint. During this run the host disk filled and an export failed with `tar error: No
space left on device (os error 28)`; a scheduler that trusted a zero exit elsewhere and deleted the
previous checkpoint would have been left with none.

## `--keep` does not bound the store on its own

Each stored checkpoint retains up to `--history` earlier generations, 32 by default, and deleting
the directory of a generation that a kept checkpoint retains frees nothing. With `--keep 2
--history 2` the store grew 59, 76, 95, 114 MB over four captures. `references/scheduling.md` has
how to pick the two together.

## A restored branch point is not a parked source

A checkpoint taken while the source is parked in `smolvm-branch-ready` holds exactly the state its
children start from. Restoring it does not give you a parked source back: on start the helper
releases, and the workload runs the program after `--` with an empty `SMOLVM_BRANCH_NAME`, so
`/root/child.txt` in that test read `CHILD=`. A batch branch from the restored machine then waits
its full `--ready-timeout`, 10 minutes by default, and fails with

```
A batch branch checkpoints the source at a point its workload declares by running
`smolvm-branch-ready` after setup ... either add the call, raise --ready-timeout, or take single
`--name` branches, which checkpoint the source wherever it is.
```

A single `--name` branch from the restored machine worked and carried the source's state. To fan out
again from a kept branch point, branch it one child at a time or restore it once per worker, and
give each its identity some other way, since the branch variables are empty.

## Detecting a parked source: `pgrep -f` always matches

`smolvm machine exec --name src -- sh -c 'pgrep -f smolvm-branch-ready'` succeeds whether or not the
source is parked, because the `sh -c` running it has the string in its own command line. Read PID 1
instead, which is the workload:

```bash
smolvm machine exec --name src -- sh -c 'tr "\0" " " < /proc/1/cmdline' | grep -q '^smolvm-branch-ready'
```

A parked source shows `smolvm-branch-ready -- sh -c ...`; a released one shows the program after
`--`.

## `machine list | grep -q` under `pipefail`

`set -o pipefail` plus `smolvm machine list | grep -q name` can fail for a machine that exists:
`grep -q` exits on the first match, the list's next write hits a closed pipe, and the pipeline's
status is the list's failure. Two scripts in this packet reported `result=FAILED no machine was
created` for machines that were running before this was caught. Read the list into a variable, then
search it.

## A paused machine refuses `stop` and `start`, and a failed resume can be retried

```
Error: agent operation failed: stop: machine has saved execution; use resume or delete
Error: agent operation failed: start: machine has saved execution; use resume
```

A restored machine paused while the host disk was full failed its resume with `extract paused
checkpoint: failed to unpack ...`. After space was freed the same `machine resume` succeeded, and
the counter the workload keeps in RAM read 14 against 8 before the pause, then kept counting.

## A full disk leaves machines that `delete --force` will not remove

A machine restored and started while the disk was full came up with its overlay failing. Its
delete, later, with space available:

```
Error: agent operation failed: stop agent: guest did not confirm filesystem synchronization; left
the VM alive for retry: agent operation failed: shutdown ack: freeze /oldroot/mnt/overlay: I/O error
(os error 5)
```

exit 1, still `running`. `scripts/cleanup.sh --reap` killed its VM process, after which `delete
--force` removed it. **`--reap` kills every VM process under this `HOME`**, not only that one, so
use it when nothing else there should keep running. `scripts/preflight.sh` checks free space for
this reason.

## `du` overstates what a restore costs

Restores are copy-on-write over the checkpoint. On macOS three restores of one checkpoint moved the
volume's free space by 22 MB at create and 65 MB at start, about 29 MB a machine, while `du` on
each machine's directory said 150 to 190 MB. On Linux each restored machine's directory holds small
`qcow2` layers over `.smolcheckpoint-*.raw` bases, 29 MB by `du`. Measure a restore budget with
`df` before and after.

## smolvm keeps the last restored checkpoint after you delete it

On macOS `vms/_restore-base` under smolvm's cache is, in the source's words, a pristine clone of the
most recently restored checkpoint, kept so the next restore writes only the chunks that differ. It
was 243 MB here, with the checkpoint's `memory.bin` inside, and it stayed after every machine and
every checkpoint file was deleted. `smolvm serve start`'s reclaim did not touch it.
`scripts/cleanup.sh --restore-base` removes it. None was created on Linux aarch64.

## `machine stop` on a missing name leaves an empty directory

On v1.18.2, `smolvm machine stop --name <name>` for a machine that does not exist leaves an empty
directory under the VM cache. A cleanup that stops each recorded name after `--cascade` has already
deleted the children leaves one per child, which a leak check counting directories then reports.
This packet's cleanup stops only names still listed.

## Environment given to a restore reaches `exec`, not the resumed workload

`machine create --from <checkpoint> -e ROLE=seven`: `machine exec` saw `ROLE=seven`, and the resumed
workload's own environment did not have it. The workload is the process that was running when the
checkpoint was taken, and its environment came with it.

# Rewinding a machine

A rolling window of stored checkpoints: a timer captures a running machine every 30 seconds, keeps
the last 10 minutes of captures, and lets you bring the machine back as it was at any capture in
that window. [Incremental checkpoints](../incremental-checkpoints.md) is the reference for the
store underneath. `SKILL.md` is the agent procedure, with the scripts.

## Any capture, not any moment

A rewind lands on a capture, so it comes back at most one interval before the moment you asked
for. Between two captures there is nothing to land on.

## What a rewind makes

A new machine, from a generation the newest capture retains, with its own disks over the
checkpoint's. RAM comes back too, so a process that was running keeps running, under the same PID,
and a counter in `/dev/shm` carries on from the value it held. The machine you rewound from keeps
running until you stop it, and nothing moves the timer to the new machine until you do.

## Why it needs no scheduler in smolvm

smolvm has no checkpoint scheduler and no retention. The window is `machine checkpoint --store
<dir> --history N` under launchd or a systemd timer, `N` being the window divided by the interval,
then deleting the older directories and running `machine checkpoint-prune`. Each generation is a
complete index and every checkpoint directory holds hard links to the objects it needs, so nothing
has to be merged: a generation that falls out of the history is gone when nothing else references
its chunks.

## Credentials

A key given to the machine as a [credential binding](../credential-substitution.md) stays out of
the guest and out of every checkpoint, and the binding travels with the checkpoint. The value does
not, and a restored machine never reads one from the environment, because a checkpoint chose both
the variable and the destination. See `SKILL.md`, step 5, for how it gets one.

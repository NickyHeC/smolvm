---
name: teardown
description: "Stops every smolvm machine a session started, removes smolvm's state, and proves the host is clean. Use after any smolvm session; when a machine seems to have survived a Ctrl-C or a crash; when disk space has disappeared; when uninstalling smolvm; when tearing down the Kubernetes runtime from a node; or when a borrowed or shared host has to be handed back with nothing left behind. Also use it as the cleanup step for other smolvm work, because the obvious assertions here give false results. Do not use it to delete machines another session created: it removes only what a script recorded under its own name prefix."
---

# Leaving nothing running and nothing behind

Verified on **smolvm v1.18.2** on macOS arm64 and Linux aarch64, 2026-09-24. This packet exists on its own because **almost every cleanup fact
in smolvm is counterintuitive**: the obvious assertion gives a false failure, the obvious reaper
matches the wrong process or nothing at all, and the command a user reaches for when a run
misbehaves does not stop the machine. Anything that starts machines needs this more than it needs
any single feature.

Every other packet's cleanup script is this packet's `scripts/cleanup.sh` with one line changed.

## Procedure

**1. See what is there.** Read-only: deletes nothing, starts no VM.

```bash
scripts/preflight.sh
```

It reports each state directory with its size, whether a `--oci-cache` image store exists,
whether the launcher symlink and the `PATH` block are present, and whether state can be relocated
on this platform.

**2. Delete the machines your scripts created, and report the rest.**

```bash
scripts/cleanup.sh            # report leftover VM processes
scripts/cleanup.sh --reap     # and kill them
```

Only machines recorded in the state file are deleted, so a machine you or another session created
by hand is never touched. A script records what it creates with
`scripts/cleanup.sh --record <name>`, and names must carry the `smolskill-` prefix or the delete
is skipped. `--purge` removes the state file once the list is empty.

**When the user asks you to clean up machines they made themselves**, which is what "clean up
after me" usually means, nothing is recorded and the script reports them as `machines=remaining`
and leaves them. That is the guard working, not the end of the job. List them, confirm they are
the user's and not another session's, and delete each by name:

```bash
smolvm machine list
smolvm machine stop   --name <NAME>
smolvm machine delete --name <NAME> --force --cascade
```

Then run `scripts/cleanup.sh` again for the process check, and step 3.

The state file lives under `${XDG_STATE_HOME:-$HOME/.local/state}/smolvm-skills/`, outside
`~/.smolvm` and outside smolvm's own caches. Nothing here edits smolvm configuration.

**3. Prove it.**

```bash
scripts/verify-clean.sh
scripts/verify-clean.sh --protected "$HOME/.smolvm"   # after a run under an isolated HOME
```

**Every check here is scoped to the `HOME` it runs under**, and the `audited_home=` line says
which profile the result describes. Run it under a different `HOME` and it reports a clean host no
matter what is running elsewhere: an agent that hit `machines=FAIL` did exactly that, re-ran the
script under a fresh `mktemp -d`, got `result=clean`, and reported the host clean while a VM was
still running.

Each check prints `ok` or `FAIL expected=... actual=...`, and the script exits non-zero if any
failed. When the `HOME` you are auditing is the only installation, there is nothing to protect
and the flag is skipped. `--protected <dir>` asserts nothing under a real installation was written today, which is
how you show a test run under a scratch `HOME` did not reach it. Without it the check reports
`protected=not_checked` rather than passing silently.

**4. Reclaim space, or remove smolvm entirely.**

```bash
smolvm machine prune --name <NAME>   # one machine's unreferenced layers; --all drops its cached images
smolvm pack prune
curl -sSL https://smolmachines.com/install.sh | bash -s -- --uninstall
```

`references/locations.md` has the full layout, what the uninstaller removes, and the two things it
deliberately leaves. On v1.18.2 on macOS it also leaves `~/Library/Caches/smolvm-registry` without
saying so; remove that by hand after `--uninstall`.

## The four traps that make this a packet

Full detail with the observations behind each is in `references/traps.md`.

- **`Ctrl-C` does not stop the machine. On v1.14.x there was no CLI route to what it left; on
  v1.16.x there is.** The VM still outlives the CLI, and it still exits only when its own workload
  finishes, so a run that loops or hangs is unbounded exposure. What changed is visibility.
  Measured on macOS arm64 on v1.16.1, 2026-09-15: killing the **wrapper** and leaving the CLI
  reparented to PID 1 leaves the pair running and `machine list` shows it as
  `vm-12175b4a running (eph)`, and `smolvm machine stop --name vm-12175b4a` then stops it and both
  processes go. Killing the **CLI** itself took the VM with it: `No machines found`, no processes.
  **The reaper's remaining case is a VM process whose `machine list` entry is absent**, which
  neither of those two routes produced on v1.16.1; it is now a backstop rather than the only route.
  The transcripts recorded below are from v1.14.x, where the entry was never shown. On v1.18.2 the
  macOS result repeated, and on Linux aarch64 killing only the wrapper took the VM with it.
- **The two obvious reapers both fail, in opposite directions.** `pgrep -f _boot-vm` matches any
  shell whose text contains that string, including the cleanup script, and reports orphans that do
  not exist. `readlink /proc/<pid>/exe` reports none that do: the VM process is not dumpable, so
  its `/proc/<pid>/exe` is root-owned and `readlink` returns `Permission denied` to the user who
  started it. `cleanup.sh` matches `argv[1]` exactly instead, and scopes by the boot config's path.
- **Asserting "no machines" immediately after `machine run` fails on a healthy host.** The entry
  retires after the command returns, observed gone by 20 s.
- **`machine delete` needs `--force` in a script.** On v1.17.0 and later a delete that needs
  confirmation, with stdin not a terminal, exits 1 with `needs confirmation but stdin is not a
  terminal; pass --force to delete it`. Before that it printed `Cancelled`, exited 0 and left the
  machine, so a script on an older release carries on believing it cleaned up. A branched machine
  also needs `--cascade`.
- **A paused machine is state too, and `stop` will not touch it.** `machine pause` (v1.18.0 and
  later) leaves the machine listed as `paused` with its RAM saved on disk; `machine stop` refuses
  with `machine has saved execution; use resume or delete`, and `delete --force` removes the
  machine and the saved execution with it.

And one false alarm: **`ls ~/.cache/smolvm/vms/ | wc -l` is not a leak check.** Once `--oci-cache`
has run, `_shared` lives there holding the baked images. Both scripts exclude it. The opposite case
is real residue: **a boot that timed out leaves its VM directory**, `verify-clean.sh` reports
`vm_dirs=FAIL`, and running `smolvm serve start` once reclaims it. And one cache that is sensitive:
**on macOS smolvm keeps a clone of the last restored checkpoint**, memory included, in
`vms/_restore-base`, after every machine and checkpoint is gone. `verify-clean.sh` reports it as
`restore_base=present` rather than as a leak; remove it with `rm -rf` once no restore is running.

## Security defaults, and why they are the defaults

- **Cleanup deletes only what it was told it created.** A shared host can carry another session's
  machines, and during the runs behind this packet it did: a second VM under a different `HOME`
  was live throughout. `cleanup.sh` listed only the processes whose boot config sits under its own
  state tree and left the other one running. A cleanup script that kills every smolvm process is
  fine on your laptop and destructive on a build agent.
- **`--reap` is opt-in and prints what it is about to kill.** Killing a VM is not recoverable and
  the VM cannot be identified from `machine list`, so the default is to report.
- **Nothing here escalates privilege.** The one place teardown needs `sudo` is the Kubernetes
  runtime, which installs outside your home directory; those commands are in
  `references/kubernetes.md` for you to run and read, not wrapped in a script.
- **The uninstaller leaves `~/.config/smolvm` and your `PATH` line on purpose**, because those
  hold registry credentials and a change you made to your own shell profile.

## Platform arms

- **macOS arm64** and **Linux aarch64**: the scripts were run here.
- **Linux x86_64**: the procedure was verified in the material behind this packet, on hosts that
  no longer exist. The scripts themselves were not re-run there.
- **Windows x86_64**: `references/windows.md`, **not re-run**, including by the 2026-09-11 batch
  on v1.14.6, so that page stays a v1.14.2 record. The scripts are POSIX shell and do
  not run there at all. Windows is the platform where this matters most, because state cannot be
  relocated and one session left 30 GB in `%LOCALAPPDATA%\smolvm`.
- **Kubernetes nodes**: `references/kubernetes.md`. Verified on Ubuntu 22.04 x86_64 with k3s in
  the material behind this packet, not re-run here.

## Eval prompts, and what they produced

Run on 2026-09-07 PT against smolvm v1.14.2 from the published release, under an isolated `HOME`
on macOS 26.6.2 arm64 and on Lima `linux-kvm` (Ubuntu 24.04 aarch64). Output is verbatim.

**1. "I ran some smolvm machines. Clean up after me and show me the host is clean."**

A machine was created, started, recorded, then cleaned up. macOS:

```
  Cleaning up data directory for vm: smolskill-td
  Deleted machine: smolskill-td
machines=clean
vm_processes=none

machines=ok
vm_dirs=ok
vm_processes=ok
protected_untouched_since_2026-09-07=ok
result=clean
```

Linux gave the same, with `protected=not_checked` because no real installation was named.

**2. "Is anything still running that `smolvm machine list` cannot see?"**

**The expected answer changed with v1.16.x, and the transcripts below are v1.14.x.** On v1.16.1 an
interrupted run stays in `machine list` as `running (eph)`, so the honest answer to this question
is now "nothing that the list cannot see; here is what it does show, and `machine stop --name`
clears it". The reaper is still worth running, because it names the process pair and the boot
config path, and because a process whose list entry is absent would not be found any other way.
Re-measured on macOS arm64 on v1.16.1, 2026-09-15.

Run against a live machine on v1.14.x, so this is the answer when the host is not clean. Linux:

```
vm_process=51706 config=/home/<user>/skp/.cache/smolvm/vms/2ec3433ec42ca6de/boot-config.json
rerun with --reap to kill them
```

macOS:

```
vm_process=76032 config=/tmp/skp/Library/Caches/smolvm/vms/2ec3433ec42ca6de/boot-config.json
```

A second VM belonging to another session was live on the Linux host under a different `HOME`
throughout, and was correctly not listed. The same run through `readlink /proc/<pid>/exe`
returned nothing at all, which is the finding that changed this script.

**3. "Prove my test run did not touch my real smolvm install."**

```
machines=ok
vm_dirs=ok
vm_processes=ok
protected_untouched_since_2026-09-07=ok
result=clean
```

against `--protected $HOME/.smolvm` on the macOS host, where a real v0.5.20 installation sits
beside the isolated v1.14.2 one used for these runs.

## Re-verified on v1.14.6

Run 2026-09-10 PT against v1.14.6 on macOS 26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04
aarch64). `verify-clean.sh` returned `result=clean` on both, including
`protected_untouched_since_2026-09-10=ok` against the real installation on the Mac.

**The reaper changed on this release**, and the change is the reason to read
`references/traps.md` again: the pack-run path forks without execing, so its VM child carries no
`_boot-vm` in argv and the previous scanner could not see it. Measured on v1.14.6 before the fix,
`cleanup.sh` reported `vm_processes=none` and `result=clean` while two orphaned VMs held 234 MB
each. The scanner now matches both process shapes and was verified against a live orphan on both
hosts.

## Re-verified on v1.18.2

Run 2026-09-24 PT against v1.18.2 from the published release, under an isolated `HOME` on macOS
26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04 aarch64). Eval 1 and eval 3 gave the same lines as
above on both hosts, with `protected_untouched_since_2026-09-24=ok` against the real installation on
the Mac. What moved:

- **A delete without `--force` now fails loudly.** On both hosts, stdin redirected from
  `/dev/null`:
  ```
  Error: agent operation failed: delete: machine 'smolskill-del' needs confirmation but stdin is
  not a terminal; pass --force to delete it, or --cascade to remove it together with any machines
  branched from it
  delete_exit=1
  ```
- **A paused machine.** Created, started `--branchable`, paused: `machine list` showed
  `smolskill-pz paused`, `machine stop` exited 1 with `machine has saved execution; use resume or
  delete`, the machine's directory held 70 MB on macOS and 73 MB on Linux for a 1024 MiB alpine
  guest, and `cleanup.sh` deleted it and the directory, then `verify-clean.sh` said `result=clean`.
- **Killing only the wrapper.** macOS: `vm-1b950b87 running (eph)`, cleared by `machine stop`.
  Linux: `No machines found` and no process.
- **Timed-out boots leave directories.** On the Linux box, whose host could not boot guests above
  2048 MiB in time that day, seven failed ephemeral boots left seven directories of 0.4 to 4.9 MB
  each, holding `agent-startup-error.log`. `verify-clean.sh` reported `vm_dirs=FAIL expected=0
  actual=7`; one `smolvm serve start` printed `Reclaimed 7 dangling VM data dir(es)`, and the next
  `verify-clean.sh` said `result=clean`.
- **A machine whose guest disk failed will not delete.** On macOS a machine restored while the
  host disk was full later answered `delete --force` with `guest did not confirm filesystem
  synchronization; left the VM alive for retry`, exit 1, still running. `cleanup.sh --reap` killed
  its VM process and `delete --force` then removed it; `--reap` kills every VM process under this
  `HOME`, so use it when nothing else there should keep running.
- **The restore cache.** After a session of checkpoint restores on macOS, `vms/_restore-base` held
  243 MB, `memory.bin` included, with no machine left. `serve start`'s reclaim did not remove it.
  `verify-clean.sh` now reports it separately and does not count it.
- **Empty VM directories.** `machine stop --name` on a name that does not exist leaves an empty
  directory in the VM cache on v1.18.2, which a cleanup that stops names already removed by
  `--cascade` hits once per child. `verify-clean.sh` now reports them as `empty_vm_dirs=` and does
  not count them: they hold no state.
- **Two harmless messages.** Every delete on Linux prints `WARN unable to lock UID registry;
  retaining assignment` and still deletes. Pause and checkpoint leave zero-byte
  `.<name>.fork-operation*.lock` files in the `vms` directory after the machine is gone; they are
  files, not directories, and the leak check does not count them.

## What was not run

- **Windows.** `references/windows.md` records one run that was not repeated.
- **Kubernetes.** `references/kubernetes.md` records a verified sequence on a node that no longer
  exists.
- **Linux x86_64.**
- **The macOS `hdiutil` mount-point case.** `references/traps.md` records that `rm -rf` on the
  pack cache can fail with `Resource busy` and what the uninstaller does about it. No pack was
  created in these runs, so that path was not exercised here.
- **`--oci-cache`.** No `_shared` store existed on either host, so the exclusion these scripts
  carry was exercised only against its absence.

## Related packets

- `install` for what the install lays down, which is what you are removing.
- Every other packet's `scripts/cleanup.sh` is this one.

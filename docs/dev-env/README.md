# A development machine you come back to

A named machine keeps its disk across stop and start, so the packages you installed in the first
session are there in the second. That is the whole use case, and it turns on one fact that the CLI
gets wrong in its own help: **`init` runs once, not on every start.**

`SKILL.md` is the procedure. `assets/dev.smolfile` is a working starting point, and
`assets/python.smolfile` and `assets/node.smolfile` are the two the examples directory used to
carry.

## What persists, and what does not

| Mode | Persistence |
|---|---|
| `machine run` | ephemeral, every change discarded when the command exits |
| `machine exec` | changes persist across exec sessions, in an overlay on the machine's storage disk |
| `machine stop` then `start` | changes persist; the overlay is remounted |
| `machine create --from <artifact>.smolmachine` | a persistent machine from a packed artifact, boots from pre-extracted layers with no image pull |

`/tmp`, `/run` and `/dev/shm` are tmpfs whatever the mode. They keep their contents while the
machine runs, including across `exec` sessions, and are empty again after a stop and start. Write
anything that must outlive a restart to `/workspace` or elsewhere on the storage disk, including
credentials and configuration, which should not sit in `/tmp` or behind a symlink into it.

The storage disk defaults to 20 GiB and the rootfs overlay to 10 GiB; both are sparse, so they cost
what they hold.

## `init` runs once

A Smolfile's `init` is provisioning: it runs on the first start of a machine and is skipped on
every start after that. `smolvm machine create --help` still describes it as running on every VM
start, which is the wrong reading and the one that breaks a machine on its second boot. Anything
that must be true on every boot, a bind mount above all, belongs in the command the machine runs,
not in `init`.

## Working in it

```bash
scripts/preflight.sh                    # expect result=ready
scripts/create-dev-machine.sh           # name defaults to smolskill-dev
smolvm machine exec  --name smolskill-dev -- pip install --user requests
smolvm machine shell --name smolskill-dev
scripts/verify-persistence.sh           # expect result=persistent
scripts/cleanup.sh --purge
```

`machine shell` does not start a stopped machine, despite its own help text saying it does. Start
it first. `references/traps.md` has the rest, including what a host mount does to a non-root user
and why `create` succeeding proves nothing.

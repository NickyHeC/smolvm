# Per-platform arms

| | macOS arm64 | Linux aarch64 | Linux x86_64 | Windows x86_64 |
|---|---|---|---|---|
| run here on v1.18.2 | every step | every step | not run | not run |
| `checkpoint` without `--branchable` | refused | works | worked on v1.14.2 | refused |
| `pause` without `--branchable` | refused | works | not run | not run |
| `checkpoint --store` | works | works (refused on v1.16.1) | not run | not run |
| source after a batch branch | `running` | `running` (`frozen` on v1.16.1) | `running` on v1.14.2 | n/a |
| restored disks | `.raw` files, copy-on-write on APFS; `_restore-base` kept | `qcow2` layers over `.smolcheckpoint-*.raw` | not run | n/a |

## macOS arm64

macOS 26.6.2, Apple M4, v1.18.2, 2026-09-24. Every script here ran end to end. Captures of a 1 GiB
alpine machine took 1 to 5 s with a source pause of 0.027 to 0.048 s. `--branchable` is required
for `checkpoint`, `pause` and `branch`.

## Linux aarch64

Lima `linux-kvm`, Ubuntu 24.04, kernel 6.8.0-139-generic, nested virtualisation, v1.18.2,
2026-09-24. Every script here ran end to end at 1024 MiB. Two things changed from v1.16.1, both
for the better: `--store` works, where v1.16.1 refused it with `this machine's runtime does not
support incremental checkpoint streaming`, and a batch branch leaves the source running, where
v1.16.1 froze it (#1327). That box could not boot guests above 2048 MiB inside smolvm's 30 s
readiness window on the day, for host reasons the `install` packet records, which is why every
machine here is 1024 MiB.

## Linux x86_64

Not run on v1.18.2. The earlier runbook run on v1.14.2 on an A10 host checkpointed an ordinary
machine and left a branch source running.

## Windows x86_64

Checkpoint and branch were refused on Windows in the runs behind the earlier packets; the messages
are in the runbook material and were not re-checked on v1.18.2.

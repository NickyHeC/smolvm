# Per-platform arms

| | macOS arm64 | Linux aarch64 | Linux x86_64, Windows, smol cloud |
|---|---|---|---|
| run here | every step, v1.33.0, a real agent | every step, v1.33.0, a stand-in workload | not run |
| timer | launchd | systemd user timer | |
| window held, 21 generations | yes, `oldest_age_s` 631 to 722 | yes, 654 to 738 | |
| source pause | 0.070 to 0.447 s, median 0.117 | 0.8 to 31.9 s, median 1.65, the longest being the first capture | |
| capture at 21 generations | 5.6 s | 6.6 s | |
| first answer after a rewind | 3.3 to 4.8 s | 9 to 28 s | |
| exec during a pause | not hit | stops the window; `references/traps.md` | |

## macOS arm64

macOS 27.2, Apple M4, 16 GiB, 2026-11-05. The timer is a launchd agent in the `gui/<uid>` domain, which an SSH session without a console
login does not have, using `KeepAlive` and `ThrottleInterval` so slots count from the last start.

A stored capture of a machine started without `--branchable` also worked on v1.33.0, RAM included,
where `branch-and-checkpoint` records it refused on v1.22.2. These scripts still start with the flag, as
[incremental checkpoints](../../incremental-checkpoints.md) asks.

## Linux aarch64

Lima `linux-kvm`, Ubuntu 24.04, nested KVM on that Mac, 6 vCPU and 11 GiB, 2026-11-06. The machine was 4 GiB
and booted; its first start took about 7 minutes, with the image pull and the install. The workload was a
script, not an agent: a commit and a line every 15 s, and 64 MiB of RAM rewritten every 5 s. 27 of 29 runs
captured, one was skipped during a rewind and one failed as `references/traps.md` says. Rewinds came back at
counters 549, 405 and 227, with 24, 19 and 11 commits. The timer needs a systemd user instance: `preflight.sh`
checks it, and `timer.sh` prints the `loginctl enable-linger` line when it is off, since a user timer stops at
logout otherwise. With `HOME` moved elsewhere, as in these runs, point `XDG_CONFIG_HOME` at the real user's
config, where systemd looks for units.

## Linux x86_64, Windows, smol cloud

Not run. The scripts are bash and the timer forms are launchd and systemd.

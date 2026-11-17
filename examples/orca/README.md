# Orca workspaces on smol machines

[Orca](https://github.com/stablyai/orca) runs coding agents in workspaces, and
an *environment recipe* in the repository's `orca.yaml` decides where a
workspace runs: Orca calls the recipe's `create`, `suspend`, `resume` and
`destroy` commands on your computer, and `create` prints the SSH target Orca
connects to. These scripts make every workspace a smol machine on your Mac or
Linux host.

| Script | Orca step | What it does |
|---|---|---|
| `smolvm-create.sh` | `create` | creates and starts a machine with sshd on a free port on `127.0.0.1`, clones your checkout to `/workspace/<repo>`, prints the SSH target |
| `smolvm-suspend.sh` | `suspend` | `smolvm machine pause`: memory and processes are kept |
| `smolvm-resume.sh` | `resume` | resumes a paused machine, or starts a stopped one, and prints the same target again |
| `smolvm-destroy.sh` | `destroy` | deletes the machine and its `known_hosts` line |
| `build-base.sh`, `orca-base.smolfile` | once | builds the base image every workspace starts from |

## Set up

1. [Install smolvm](https://smolmachines.com). The scripts look for `smolvm`
   on `PATH`, then in `~/.local/bin`; set `SMOLVM` to use another binary.
2. Copy `smolvm-*.sh` and `build-base.sh` into your repository at
   `scripts/orca-vm/`, `orca-base.smolfile` beside them, and add the recipe in
   `orca.yaml` here to your own `orca.yaml`.
3. Build the base once:

   ```bash
   scripts/orca-vm/build-base.sh
   ```

   It boots Ubuntu 24.04, installs `openssh-server` and `git`, and packs the
   machine to `~/.orca-smolvm/orca-base.smolmachine`, where `create` looks for
   it. Without it, `create` installs them with `apt-get` in every new
   workspace instead.
4. In Orca, choose the `smolvm` recipe when you create a workspace.

`create` makes one SSH key for these workspaces in `~/.orca-smolvm/`, outside
`~/.ssh`, and trusts each machine's own host key, read through smolvm rather
than scanned over the network. Your checkout reaches the machine through a
read-only mount that is removed after the clone, so no git credential enters
it; `origin` is then set to your remote.

## Settings

Set these in the environment Orca runs the recipe with.

| Variable | Default |
|---|---|
| `SMOLVM` | `smolvm` on `PATH`, else `~/.local/bin/smolvm` |
| `SMOL_RECIPE_FROM` | `~/.orca-smolvm/orca-base.smolmachine` when it exists |
| `SMOL_RECIPE_IMAGE` | `ubuntu:24.04`, used without a base |
| `SMOL_RECIPE_CPUS`, `SMOL_RECIPE_MEM_MIB` | `2`, `2048` |
| `SMOL_RECIPE_DIR` | `~/.orca-smolvm` |
| `SMOL_RECIPE_PORT_MIN`, `SMOL_RECIPE_PORT_MAX` | `22000`, `22999` |

## Measured

smolvm 1.35.3 on an Apple M4 Mac, each step run the way Orca runs it (the
command from `orca.yaml`, from the repository, with Orca's environment and
the lifecycle JSON on stdin), timed until it exits.

| Step | Time |
|---|---|
| `create` without the base (`ubuntu:24.04` cached, `apt-get` in the machine), median of 5 | 18.1 s (13.0 to 42.2 s) |
| `create` from the base, median of 5 | 0.84 s (0.68 to 1.02 s) |
| `create` from the base, its first use | 1.7 s |
| `build-base.sh`, once | 11.6 s, a 65 MB `.smolmachine` |
| `suspend` | 1.3 s |
| `resume` of a paused machine, until sshd answers | 0.68 s |
| `resume` of a stopped machine, until sshd answers | 0.31 s |
| `destroy` | 0.13 s |

After `create`, SSH to the printed target landed in `/workspace/<repo>`, and
`git worktree add` and a commit in the worktree worked. A process started
over SSH was still running after `suspend` and `resume`, with the guest clock
matching the host's; after the machine was stopped and resumed, the
repository and the worktree were still there and the process was not, as a
stop clears memory. `destroy` run twice succeeded both times.

Orca's own `orca-ide vm recipe doctor` (Orca 1.4.261) accepted the recipe's
four command paths, and accepted the `create` output above, in schema 1 and in
schema 2 (`ORCA_RECIPE_RESULT_SCHEMA_VERSION=2` adds
`"checkoutMode":"provisioned-root"`), as a valid result.

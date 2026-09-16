# A Docker daemon inside a machine

smolvm boots OCI images without Docker. This topic is for software **inside** the machine that has
to call Docker itself: Testcontainers, Compose, an image build, or an agent that launches
containers of its own.

`SKILL.md` is the procedure, `assets/docker.smolfile` the machine definition its scripts use, and
`references/traps.md` the measurements behind each trap. `assets/docker-annotated.smolfile` is the
longer commented version that used to live under `examples/`, with the kernel requirements, a TCP
endpoint recipe, a K3d cluster and the managed-cloud variant where each exec has its own mount
namespace.

## Docker's data has to live on `/storage`

The machine's root filesystem is already an overlay, and Docker's `overlay2` driver cannot put its
upper layer there: the backing filesystem does not provide the file-handle support nested
overlayfs needs. `/storage` is the machine's ext4 disk, and Docker's data root belongs on it:

```bash
dockerd --data-root=/storage/docker --storage-driver=overlay2
```

The Smolfile here instead bind-mounts `/storage/docker` onto `/var/lib/docker`, which reads better
to a container tool that assumes the default path. Both work. **`docker info` will not tell you
which filesystem you ended up on**, so check the device, not the daemon.

## The bind mounts are gone on the second boot

`init` runs once, not on every start. The upstream example puts the mounts in `init` alone, which
is correct for exactly one boot: after a stop and start the mounts are absent and `dockerd` is
down. Re-run `scripts/start-dockerd.sh` after every start. The failure mode is a daemon that will
not start, or one running on the wrong filesystem, not lost data: the images are on `/storage` and
survive.

## Reaching the daemon from the host

Set `docker_socket = true` in the Smolfile, or pass `--docker-socket` at create. smolvm bridges the
guest's `/var/run/docker.sock` over vsock and prints the host socket path when the machine starts:

```bash
DOCKER_HOST=unix:///path/printed/by/smolvm/docker.sock docker ps
```

That exposes the daemon **inside** the guest to host clients, and containers stay inside the guest
kernel. It is not the same as mounting the host's own `/var/run/docker.sock` into the machine,
which hands guest code control of the host daemon and removes the isolation the machine is for. Do
not do the second with an untrusted guest, and do not expose an unauthenticated Docker TCP endpoint
on `0.0.0.0`: prefer the vsock-backed Unix socket, and if a client needs TCP, bind it to loopback
and add authentication.

## Ports

Declare host-to-guest ports at create time. Dynamic ports chosen later by Compose or Testcontainers
are not published through the outer VM boundary automatically, so pin the ones the host must reach.

## Platforms

This does not work on Windows, up to and including v1.16.1: the bundled guest kernel has neither
bridge networking nor POSIX message queues, so `dockerd` will not start and, forced past that,
containers still cannot be created. `references/windows.md` has the evidence and a kernel probe to
re-check it on a newer build.

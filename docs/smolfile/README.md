# The Smolfile

A Smolfile is declarative machine configuration: image, resources, network policy, mounts,
environment and what to run. It is the one reference for the format; it used to exist twice,
in `AGENTS.md` and in `examples/README.md`, and those copies had drifted.

Pass one with `-s`, or `--smolfile`, to `machine create` or `machine run`.


A Smolfile is a TOML file declaring a VM workload. Use with `--smolfile`/`-s`.

```toml
# Top-level: workload definition
image = "python:3.12-alpine"          # OCI image (omit for bare Alpine)
entrypoint = ["/app/run"]             # overrides image ENTRYPOINT
cmd = ["serve"]                       # overrides image CMD
env = ["PORT=8080", "DEBUG=1"]        # environment variables
workdir = "/app"                      # working directory

# Resources
cpus = 2                              # vCPUs (default: 4)
memory = 1024                         # MiB (default: 8192, elastic via balloon)
net = true                            # outbound networking (default: false)
gpu = true                            # GPU acceleration (default: false)
gpu_vram = 4096                       # GPU VRAM MiB (default: 4096, ignored unless gpu=true)
storage = 40                          # storage disk GiB (default: 20)
overlay = 4                           # overlay disk GiB (default: 10)

# Network policy , egress filtering by hostname and/or CIDR
[network]
allow_hosts = ["api.stripe.com"]      # resolved at VM start (implies net)
allow_cidrs = ["10.0.0.0/8"]         # IP/CIDR ranges (implies net)

# Dev profile (used by `machine run` and `machine create`)
[dev]
volumes = ["./src:/app"]              # host bind mounts
ports = ["8080:8080"]                 # port forwarding
init = ["pip install -r requirements.txt"]  # run on every VM start
env = ["APP_MODE=dev"]                # dev-only env (extends top-level)
workdir = "/app"                      # dev-only workdir

# Artifact profile (used by `pack create`)
[artifact]
cpus = 4                              # override resources for distribution
memory = 2048
entrypoint = ["/app/run"]             # override entrypoint for packed binary
oci_platform = "linux/amd64"          # target OCI platform

# Health check (used by `machine monitor`)
[health]
exec = ["curl", "-f", "http://127.0.0.1:8080/health"]
interval = "10s"
timeout = "2s"
retries = 3
startup_grace = "20s"

# Credential forwarding
[auth]
ssh_agent = true                      # forward host SSH agent into the VM

# Secrets , references to host sources, resolved at workload launch
[secrets]
DATABASE_URL   = { from_env   = "PROD_DB_URL" }      # host env var (at launch)
GCP_CREDS      = { from_file  = "/abs/creds.json" }  # host file (at launch)
```

## Merge Precedence

CLI flags override Smolfile values:

Neither `machine run` nor `machine create` has an `--entrypoint` flag; both reject it with
`unexpected argument`. `pack create` does have one. Set the entrypoint in the Smolfile.

```
image:      --image flag > Smolfile image > None (bare Alpine)
entrypoint: Smolfile entrypoint > image metadata
cmd:        trailing args (after --) > Smolfile cmd > image metadata
env:        top-level env + [dev].env + CLI -e (all merged)
volumes:    [dev].volumes + CLI -v (all merged)
ports:      [dev].ports + CLI -p (all merged)
init:       [dev].init + CLI --init (all merged)
cpus/mem:   CLI flag > Smolfile > defaults (4 CPU, 8192 MiB)
```


#!/usr/bin/env bash
# Orca `create`: one smol machine per workspace, sshd on a loopback port, the repository
# cloned at projectRoot. Prints the SSH recipe result on stdout.
source "$(dirname "$0")/smolvm-lib.sh"

name="$(machine_name)"
repo_path="${ORCA_REPO_PATH:-$PWD}"
project_root="/workspace/$(basename "$repo_path")"
t0=$(date +%s)

mkdir -p "$SMOL_RECIPE_DIR"; chmod 700 "$SMOL_RECIPE_DIR"
[ -f "$SMOL_RECIPE_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C orca-smolvm -f "$SMOL_RECIPE_KEY"
pub="$(cat "$SMOL_RECIPE_KEY.pub")"

# A free host port. smolvm publishes it on 127.0.0.1 and ::1 only.
port=""
for _ in $(seq 1 50); do
  p=$(( SMOL_RECIPE_PORT_MIN + RANDOM % (SMOL_RECIPE_PORT_MAX - SMOL_RECIPE_PORT_MIN + 1) ))
  if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then port=$p; break; fi
done
[ -n "$port" ] || { log "no free port in range"; exit 1; }

# First start: install sshd and git unless the base already has them, give this machine its
# own host keys, authorize the recipe key. /run is empty on every boot, so the workload
# recreates /run/sshd before it starts sshd.
init="set -e; if ! [ -x /usr/sbin/sshd ] || ! command -v git >/dev/null; then \
export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; \
apt-get install -y -qq --no-install-recommends openssh-server git ca-certificates >/dev/null; fi; \
rm -f /etc/ssh/ssh_host_*; ssh-keygen -A; mkdir -p /root/.ssh /workspace; chmod 700 /root/.ssh; \
printf '%s\n' '$pub' > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys"

from="$SMOL_RECIPE_FROM"
if [ -z "$from" ] && [ -f "$SMOL_RECIPE_DIR/orca-base.smolmachine" ]; then from="$SMOL_RECIPE_DIR/orca-base.smolmachine"; fi
if [ -n "$from" ]; then source_args=(--from "$from"); else source_args=(--image "$SMOL_RECIPE_IMAGE"); fi
log "creating $name from ${from:-$SMOL_RECIPE_IMAGE}, port $port"
"$SMOLVM" machine create --name "$name" "${source_args[@]}" --net \
  --cpus "$SMOL_RECIPE_CPUS" --mem "$SMOL_RECIPE_MEM_MIB" -p "$port:22" \
  --label orca-instance="${ORCA_VM_INSTANCE_ID}" --label orca-ssh-port="$port" --label orca-project-root="$project_root" \
  --init "$init" -- sh -c 'mkdir -p /run/sshd && exec /usr/sbin/sshd -D -e' >&2
"$SMOLVM" machine start --name "$name" >&2
log "started in $(( $(date +%s) - t0 ))s"

# Trust this machine's own host key, read through smolvm rather than scanned over the network.
hostkey="$("$SMOLVM" machine exec --name "$name" -- cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')"
touch "$SMOL_RECIPE_KNOWN_HOSTS"
ssh-keygen -R "[127.0.0.1]:$port" -f "$SMOL_RECIPE_KNOWN_HOSTS" >/dev/null 2>&1 || true
printf '[127.0.0.1]:%s %s\n' "$port" "$hostkey" >> "$SMOL_RECIPE_KNOWN_HOSTS"
wait_for_ssh "$port"

# Clone the desktop checkout through a temporary read-only mount, so no git credential
# enters the guest, then point origin at the real remote. The guest's root does not own the
# host's files, so the mount is marked safe for this one clone.
"$SMOLVM" machine mount add --name "$name" -v "$repo_path:/mnt/orca-src:ro" >&2
ssh_guest "$port" "set -e; rm -rf '$project_root'; \
  git config --global --add safe.directory /mnt/orca-src/.git; \
  git clone -q /mnt/orca-src '$project_root'; \
  git config --global --unset-all safe.directory; \
  cd '$project_root'; if [ -n '${ORCA_REPO_URL:-}' ]; then git remote set-url origin '${ORCA_REPO_URL:-}'; fi; \
  if [ -n '${ORCA_REPO_REF_HEAD:-}' ] && [ -n '${ORCA_REPO_BRANCH:-}' ]; then git checkout -q -B '${ORCA_REPO_BRANCH:-}' '${ORCA_REPO_REF_HEAD:-}'; fi" >&2
"$SMOLVM" machine mount remove --name "$name" --target /mnt/orca-src >&2
log "repo at $project_root, total $(( $(date +%s) - t0 ))s"

emit_result "$name" "$port" "$project_root"

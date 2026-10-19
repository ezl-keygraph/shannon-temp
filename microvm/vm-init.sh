#!/bin/bash
#
# PID 1 for running this image's filesystem directly as a Firecracker microVM
# (Firecracker-as-the-container: no Docker inside the guest).
#
# When the image is booted as a raw rootfs, none of the things Docker normally
# provides are present: the kernel pseudo-filesystems are not mounted and the
# Docker ENV directives are not applied. This init mounts those filesystems,
# restores the image's default environment, loads per-run configuration from
# /etc/vm.env (injected into the rootfs at deploy time), and execs the worker
# through the normal entrypoint.
#
# Boot with:  init=/sbin/vm-init  (plus ip=... for networking)
#
set +e

# --- kernel pseudo-filesystems (mount comes from util-linux) -----------------
# /proc is required: the Temporal SDK's native core reads total memory from
# /proc/meminfo and panics ("call refresh_memory before cgroup limits") if it
# cannot. cgroup2 lets it read memory limits cleanly.
mount -t proc     proc     /proc                    2>/dev/null
mount -t sysfs    sysfs    /sys                     2>/dev/null
mount -t cgroup2  cgroup2  /sys/fs/cgroup           2>/dev/null
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm
mount -t devpts   devpts   /dev/pts                 2>/dev/null
mount -t tmpfs    tmpfs    /dev/shm                 2>/dev/null
mount -t tmpfs    tmpfs    /run                     2>/dev/null

# --- image environment defaults (normally set by Docker ENV) -----------------
export NODE_ENV=production
export SHANNON_DOCKER=true
export HOME=/tmp
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PLAYWRIGHT_MCP_EXECUTABLE_PATH=/usr/bin/chromium-browser
export npm_config_cache=/tmp/.npm
export XDG_CACHE_HOME=/tmp/.cache
export XDG_CONFIG_HOME=/tmp/.config

# DNS fallback if the host (or kernel ip= config) did not supply one.
[ -s /etc/resolv.conf ] || echo "nameserver 8.8.8.8" > /etc/resolv.conf

# --- per-run configuration ---------------------------------------------------
# /etc/vm.env is written into the rootfs at deploy time. It carries the secrets
# and target for this run, e.g.:
#   TEMPORAL_ADDRESS=172.20.0.1:7233
#   SHANNON_AI_MODEL=anthropic:claude-sonnet-4-6
#   SHANNON_AI_API_KEY=sk-ant-...
#   VM_CMD="node apps/worker/dist/temporal/worker.js <url> <repo> --task-queue <q>"
if [ -f /etc/vm.env ]; then
  set -a
  . /etc/vm.env
  set +a
fi

cd /app
# VM_CMD is intentionally unquoted so it splits into the worker's arguments.
exec /app/entrypoint.sh ${VM_CMD:-node apps/worker/dist/temporal/worker.js}

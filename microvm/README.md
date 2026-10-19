# Running Shannon as a Firecracker microVM

This directory lets the Shannon worker image boot **directly as a Firecracker
microVM** — the microVM *is* the container, with no Docker running inside the
guest. The image's filesystem becomes the VM root filesystem, and `vm-init`
(PID 1) brings the environment up and launches the worker.

## What makes the image boot as a microVM

- `util-linux` is installed in the runtime image (the Wolfi `busybox` here has no
  `mount` applet), so the init can mount the kernel pseudo-filesystems.
- `/sbin/vm-init` is baked in as PID 1. It mounts `/proc`, `/sys`, `cgroup2`,
  `/dev/*`, `/run`; restores the image's default environment; loads per-run
  config from `/etc/vm.env`; and execs the worker through `entrypoint.sh`.
  Mounting `/proc` is essential — the Temporal SDK's native core reads total
  memory from `/proc/meminfo` and panics without it.

## End-to-end flow (x86_64 Linux host with docker, e2fsprogs, firecracker)

```bash
# 1. Build the image and export it to an ext4 rootfs
sudo ./microvm/build-rootfs.sh --build --out shannon-vm.ext4

# 2. Make sure a Temporal server is reachable from the guest's subnet gateway.
#    e.g. on the host:  docker run -d --network host temporalio/temporal:1.7.0 \
#                         server start-dev --ip 0.0.0.0

# 3. Boot the microVM and run a pentest
SHANNON_AI_API_KEY=sk-ant-... SHANNON_AI_MODEL=anthropic:claude-sonnet-4-6 \
sudo -E ./microvm/run-vm.sh \
    --rootfs shannon-vm.ext4 \
    --kernel /path/to/vmlinux \
    --target https://your-target.example.com \
    --repo /repo \
    --queue shannon-test
```

`run-vm.sh` puts the guest on a dedicated `172.20.0.0/30` (its own tap), NATs it
to the internet for the target and the model API, and writes the secrets +
worker invocation into `/etc/vm.env` inside the rootfs before boot.

To smoke-test connectivity + the AI key cheaply first, add `--extra --validate-model`.

## Per-run config (`/etc/vm.env`)

`run-vm.sh` generates this; it is just an env file the init sources:

```
TEMPORAL_ADDRESS=172.20.0.1:7233
SHANNON_AI_MODEL=anthropic:claude-sonnet-4-6
SHANNON_AI_API_KEY=sk-ant-...
VM_CMD="node apps/worker/dist/temporal/worker.js <url> <repo> --task-queue <q>"
```

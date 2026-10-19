#!/bin/bash
#
# Boot a Shannon microVM rootfs under Firecracker, with host networking (NAT) and
# the per-run configuration injected into /etc/vm.env. The guest runs the worker
# as PID 1 (init=/sbin/vm-init).
#
#   SHANNON_AI_API_KEY=sk-ant-... SHANNON_AI_MODEL=anthropic:claude-sonnet-4-6 \
#   sudo -E ./microvm/run-vm.sh \
#       --rootfs shannon-vm.ext4 --kernel /path/to/vmlinux \
#       --target https://app.example.com --repo /repo --queue shannon-test
#
# Networking: a dedicated /30 on its own tap (default 172.20.0.0/30) so it does
# not collide with any other microVM's subnet on the host. Temporal defaults to
# <subnet>.1:7233 (reachable over the tap); override with --temporal.
#
# AI config from the environment: SHANNON_AI_API_KEY (or ANTHROPIC_API_KEY),
# SHANNON_AI_MODEL, and optional SHANNON_AI_BASE_URL.
set -Eeuo pipefail

ROOTFS=""; KERNEL=""; TARGET=""; REPO="/repo"; QUEUE="shannon-test"; REPO_GIT=""
TAP="fc-shan"; SUBNET="172.20.0"; TEMPORAL=""; MEM=2048; VCPUS=2; TIMEOUT=0; EXTRA=""

while [ $# -gt 0 ]; do case "$1" in
  --rootfs)   ROOTFS="$2";   shift 2;;
  --kernel)   KERNEL="$2";   shift 2;;
  --target)   TARGET="$2";   shift 2;;
  --repo)     REPO="$2";     shift 2;;   # path inside the guest (default /repo)
  --repo-git) REPO_GIT="$2"; shift 2;;   # git URL to clone into the guest's /repo
  --queue)    QUEUE="$2";    shift 2;;
  --tap)      TAP="$2";      shift 2;;
  --subnet)   SUBNET="$2";   shift 2;;   # first three octets, e.g. 172.20.0
  --temporal) TEMPORAL="$2"; shift 2;;
  --mem)      MEM="$2";      shift 2;;
  --vcpus)    VCPUS="$2";    shift 2;;
  --timeout)  TIMEOUT="$2";  shift 2;;   # seconds; 0 = run until the VM exits
  --extra)    EXTRA="$2";    shift 2;;   # extra worker args (e.g. --validate-model)
  *) echo "unknown flag: $1" >&2; exit 2;;
esac; done

[ -n "$ROOTFS" ] && [ -n "$KERNEL" ] && [ -n "$TARGET" ] || {
  echo "required: --rootfs --kernel --target" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo (needs tap/nftables/firecracker)" >&2; exit 2; }

HOST_IP="${SUBNET}.1"; GUEST_IP="${SUBNET}.2"
TEMPORAL="${TEMPORAL:-${HOST_IP}:7233}"
IFACE="$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')"
AKEY="${SHANNON_AI_API_KEY:-${ANTHROPIC_API_KEY:-}}"
MODEL="${SHANNON_AI_MODEL:-anthropic:claude-sonnet-4-6}"
[ -n "$AKEY" ] || { echo "set SHANNON_AI_API_KEY or ANTHROPIC_API_KEY in the environment" >&2; exit 2; }

echo "[run-vm] tap $TAP ${HOST_IP}/30, guest ${GUEST_IP}, egress via $IFACE"
ip link del "$TAP" 2>/dev/null || true
ip tuntap add dev "$TAP" mode tap
ip addr add "${HOST_IP}/30" dev "$TAP"
ip link set "$TAP" up
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -C POSTROUTING -s "${SUBNET}.0/30" -o "$IFACE" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "${SUBNET}.0/30" -o "$IFACE" -j MASQUERADE
iptables -C FORWARD -i "$TAP" -o "$IFACE" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$TAP" -o "$IFACE" -j ACCEPT
iptables -C FORWARD -i "$IFACE" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$IFACE" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "[run-vm] injecting /etc/vm.env into the rootfs"
MNT="$(mktemp -d)"
mount -o loop "$ROOTFS" "$MNT"
if [ -n "$REPO_GIT" ]; then
  echo "[run-vm] cloning $REPO_GIT into guest ${REPO}"
  rm -rf "${MNT}${REPO}"
  git clone --depth 1 "$REPO_GIT" "${MNT}${REPO}"
fi
{
  echo "TEMPORAL_ADDRESS=${TEMPORAL}"
  echo "SHANNON_AI_MODEL=${MODEL}"
  echo "SHANNON_AI_API_KEY=${AKEY}"
  echo "ANTHROPIC_API_KEY=${AKEY}"
  [ -n "${SHANNON_AI_BASE_URL:-}" ] && echo "SHANNON_AI_BASE_URL=${SHANNON_AI_BASE_URL}"
  echo "VM_CMD=\"node apps/worker/dist/temporal/worker.js ${TARGET} ${REPO} --task-queue ${QUEUE} ${EXTRA}\""
} > "$MNT/etc/vm.env"
chmod 600 "$MNT/etc/vm.env"
umount "$MNT"; rmdir "$MNT"

CFG="$(mktemp --suffix=.json)"
cat > "$CFG" <<EOF
{
  "boot-source": {"kernel_image_path":"${KERNEL}","boot_args":"console=ttyS0 reboot=k panic=1 root=/dev/vda rw init=/sbin/vm-init ip=${GUEST_IP}::${HOST_IP}:255.255.255.252::eth0:off"},
  "drives":[{"drive_id":"rootfs","path_on_host":"${ROOTFS}","is_root_device":true,"is_read_only":false}],
  "machine-config":{"vcpu_count":${VCPUS},"mem_size_mib":${MEM},"smt":false},
  "network-interfaces":[{"iface_id":"eth0","guest_mac":"06:00:AC:14:00:02","host_dev_name":"${TAP}"}]
}
EOF

echo "[run-vm] booting: target ${TARGET}, temporal ${TEMPORAL}, model ${MODEL}"
if [ "$TIMEOUT" -gt 0 ]; then
  timeout "$TIMEOUT" firecracker --no-api --config-file "$CFG" || true
else
  firecracker --no-api --config-file "$CFG"
fi
rm -f "$CFG"

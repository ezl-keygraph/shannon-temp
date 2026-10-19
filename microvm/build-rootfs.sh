#!/bin/bash
#
# Build the Shannon worker image and export its filesystem as an ext4 rootfs that
# Firecracker boots directly (Firecracker-as-the-container, no Docker in guest).
#
#   sudo ./microvm/build-rootfs.sh --build            # build image from this repo, then export
#   sudo ./microvm/build-rootfs.sh --image keygraph/shannon:latest   # export an existing image
#
# Flags:
#   --build         docker build the image from this repo first
#   --image NAME    image ref to export            (default: shannon-microvm:latest)
#   --out FILE      output ext4 path               (default: shannon-vm.ext4)
#   --size SIZE     ext4 size                       (default: 6G)
#
# Run on an x86_64 Linux host with docker + e2fsprogs (mkfs.ext4).
set -Eeuo pipefail

IMAGE=shannon-microvm:latest
OUT=shannon-vm.ext4
SIZE=6G
BUILD=0
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do case "$1" in
  --image) IMAGE="$2"; shift 2;;
  --out)   OUT="$2";   shift 2;;
  --size)  SIZE="$2";  shift 2;;
  --build) BUILD=1;    shift;;
  *) echo "unknown flag: $1" >&2; exit 2;;
esac; done

if [ "$BUILD" = 1 ]; then
  echo "[build-rootfs] docker build -> $IMAGE"
  docker build --platform linux/amd64 -t "$IMAGE" "$REPO_DIR"
fi

echo "[build-rootfs] exporting filesystem of $IMAGE"
cid=$(docker create --platform linux/amd64 "$IMAGE")
work=$(mktemp -d)
docker export "$cid" | tar --numeric-owner -xpf - -C "$work"
docker rm "$cid" >/dev/null

echo "[build-rootfs] writing ext4 $OUT ($SIZE)"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
mkfs.ext4 -F -q -d "$work" "$OUT"
rm -rf "$work"
echo "[build-rootfs] done: $OUT"
echo "Boot it with: sudo ./microvm/run-vm.sh --rootfs $OUT --kernel <vmlinux> --target <url>"

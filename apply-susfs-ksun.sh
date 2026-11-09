#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SUSFS_SOURCE_BASE="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12"
KERNEL_PATCH_URL="$SUSFS_SOURCE_BASE/thesillyok-susfs-1.5.12-mod.patch"

test -d "$ROOT/fs"
test -d "$ROOT/KernelSU-Next/kernel"
test -s "$ROOT/KernelSU-Next/kernel/Kconfig"

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel-1.5.12.patch"

# Apply the Linux 4.14 kernel-side SUSFS backport once.
if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
  echo "[SUSFS] Kernel layer already has v1.5.12"
else
  if [[ -e "$ROOT/fs/susfs.c" || -e "$ROOT/include/linux/susfs.h" ]]; then
    echo "[SUSFS][FATAL] Existing SUSFS files found but version is not v1.5.12"
    exit 1
  fi
  patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-1.5.12.patch"
fi

mkdir -p "$ROOT/include/linux"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs.h" -o "$ROOT/include/linux/susfs.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs_def.h" -o "$ROOT/include/linux/susfs_def.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/fs/susfs.c" -o "$ROOT/fs/susfs.c"

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
test -s "$ROOT/include/linux/susfs_def.h"
test -s "$ROOT/fs/susfs.c"

for symbol in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_MAP KSU_SUSFS_ENABLE_LOG; do
  grep -q "config ${symbol}$" "$ROOT/KernelSU-Next/kernel/Kconfig" || {
    echo "[SUSFS][FATAL] Missing KernelSU Next config symbol: ${symbol}"
    exit 1
  }
done

echo "[SUSFS] Verified Linux 4.14 kernel layer + KernelSU Next SUSFS Kconfig"

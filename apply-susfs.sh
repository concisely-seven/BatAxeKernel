#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/ksu-src/ksun"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Pinned SUSFS v1.5.12 backport for Linux 4.14.113 and its KernelSU-Next bridge.
KERNEL_PATCH_URL="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12/thesillyok-susfs-1.5.12-mod.patch"
KSUN_PATCH_URL="https://raw.githubusercontent.com/TheSillyOk/kernel_ls_patches/7acc04583b63772baf8c1d88cbde778775895798/KSUN/KSUN-SUSFS-1.5.12.patch"

echo "[SUSFS] Checking Linux 4.14.113 and KernelSU-Next source trees"
test -d "$ROOT/fs" || { echo "[SUSFS][ERROR] kernel fs/ directory missing"; exit 1; }
test -f "$KSU_DIR/kernel/Kconfig" || { echo "[SUSFS][ERROR] ksu-src/ksun/kernel/Kconfig missing; prepare-ksu-variant.sh must run first"; exit 1; }
test -L "$ROOT/drivers/kernelsu" || { echo "[SUSFS][ERROR] drivers/kernelsu is not the prepared KernelSU-Next symlink"; exit 1; }
test "$(readlink "$ROOT/drivers/kernelsu")" = "../ksu-src/ksun/kernel" || { echo "[SUSFS][ERROR] unexpected KernelSU driver target"; exit 1; }

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel-1.5.12.patch"
curl -fL --retry 3 "$KSUN_PATCH_URL" -o "$TMP_DIR/susfs-ksun-1.5.12.patch"

if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
    echo "[SUSFS] Kernel layer already has v1.5.12"
else
    if test -e "$ROOT/fs/susfs.c" || test -e "$ROOT/include/linux/susfs.h"; then
        echo "[SUSFS][ERROR] Existing SUSFS files found with an unexpected version; refusing to overwrite"
        exit 1
    fi
    echo "[SUSFS] Applying Linux 4.14.113 backport"
    patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-1.5.12.patch"
fi

if grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"; then
    echo "[SUSFS] KernelSU-Next already exposes SUSFS Kconfig"
else
    echo "[SUSFS] Applying KernelSU-Next SUSFS 1.5.12 bridge"
    git -C "$KSU_DIR" apply --check "$TMP_DIR/susfs-ksun-1.5.12.patch"
    git -C "$KSU_DIR" apply "$TMP_DIR/susfs-ksun-1.5.12.patch"
fi

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
test -s "$ROOT/fs/susfs.c"
test -s "$KSU_DIR/kernel/core_hook.c"
grep -q 'CONFIG_KSU_SUSFS=y' "$ROOT/arch/arm64/configs/ksu.config"

echo "[SUSFS] Verified kernel SUSFS v1.5.12 + KernelSU-Next integration"

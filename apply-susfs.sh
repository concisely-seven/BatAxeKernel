#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/KernelSU"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Pinned patch revisions: RKSU integration and a 4.14-oriented SUSFS v1.5.12 backport.
KERNEL_PATCH_URL="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12/thesillyok-susfs-1.5.12-mod.patch"
RKSU_PATCH_URL="https://raw.githubusercontent.com/TheSillyOk/kernel_ls_patches/7acc04583b63772baf8c1d88cbde778775895798/RKSU/RKSU-SUSFS-1.5.12.patch"

echo "[SUSFS] Checking kernel and RKSU source trees"
test -d "$ROOT/fs" || { echo "[SUSFS][ERROR] kernel fs/ directory missing"; exit 1; }
test -f "$KSU_DIR/kernel/Kconfig" || { echo "[SUSFS][ERROR] KernelSU/kernel/Kconfig missing; submodule was not initialized"; exit 1; }

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel-1.5.12.patch"
curl -fL --retry 3 "$RKSU_PATCH_URL" -o "$TMP_DIR/susfs-rksu-1.5.12.patch"

# Never silently accept a different SUSFS release or a partially patched tree.
if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
    echo "[SUSFS] Kernel layer already has v1.5.12"
else
    if test -e "$ROOT/fs/susfs.c" || test -e "$ROOT/include/linux/susfs.h"; then
        echo "[SUSFS][ERROR] Existing SUSFS files found, but version is not v1.5.12; refusing to overwrite"
        exit 1
    fi
    echo "[SUSFS] Applying Linux 4.14 backport"
    patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-1.5.12.patch"
fi

if grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"; then
    echo "[SUSFS] RKSU integration already present"
else
    echo "[SUSFS] Applying RKSU integration patch"
    patch --batch --forward -p1 -F3 -d "$KSU_DIR" < "$TMP_DIR/susfs-rksu-1.5.12.patch"
fi

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
test -s "$ROOT/fs/susfs.c"

echo "[SUSFS] Verified kernel SUSFS v1.5.12 + RKSU Kconfig integration"

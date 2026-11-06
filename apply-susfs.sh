#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/KernelSU"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# This is the exact KernelSU submodule revision from the known-good kernelsu-next branch.
EXPECTED_KSU_COMMIT="88e37d606fc12758421c3e36b0f61499610cfe8d"
SUSFS_SOURCE_BASE="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12"
KERNEL_PATCH_URL="$SUSFS_SOURCE_BASE/thesillyok-susfs-1.5.12-mod.patch"
KSU_PATCH_URL="https://raw.githubusercontent.com/TheSillyOk/kernel_ls_patches/7acc04583b63772baf8c1d88cbde778775895798/RKSU/RKSU-SUSFS-1.5.12.patch"

test -d "$ROOT/fs"
test -f "$KSU_DIR/kernel/Kconfig"
ACTUAL_KSU_COMMIT="$(git -C "$KSU_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_KSU_COMMIT" != "$EXPECTED_KSU_COMMIT" ]]; then
  echo "[SUSFS][FATAL] KernelSU submodule changed: expected $EXPECTED_KSU_COMMIT, got $ACTUAL_KSU_COMMIT"
  exit 1
fi
echo "[KSU] Pinned known-good submodule: $ACTUAL_KSU_COMMIT"

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel-1.5.12.patch"
curl -fL --retry 3 "$KSU_PATCH_URL" -o "$TMP_DIR/susfs-ksu-1.5.12.patch"

# Apply the Linux 4.14 SUSFS backport only once.
if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
  echo "[SUSFS] Kernel layer already has v1.5.12"
else
  if [[ -e "$ROOT/fs/susfs.c" || -e "$ROOT/include/linux/susfs.h" ]]; then
    echo "[SUSFS][FATAL] Existing SUSFS files found but version is not v1.5.12"
    exit 1
  fi
  patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-1.5.12.patch"
fi

# The Linux 4.14 backport patch wires SUSFS into VFS but intentionally
# keeps the three SUSFS implementation/header files as separate source files.
# Fetch them from the same immutable upstream revision before Kconfig checks.
mkdir -p "$ROOT/include/linux"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs.h" -o "$ROOT/include/linux/susfs.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs_def.h" -o "$ROOT/include/linux/susfs_def.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/fs/susfs.c" -o "$ROOT/fs/susfs.c"

# Integrate SUSFS with the pinned KernelSU source, not a moving remote branch.
if grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"; then
  echo "[SUSFS] KernelSU integration already present"
else
  patch --batch --forward -p1 -F3 -d "$KSU_DIR" < "$TMP_DIR/susfs-ksu-1.5.12.patch"
fi

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
test -s "$ROOT/fs/susfs.c"
for symbol in KSU_SUSFS KSU_SUSFS_HAS_MAGIC_MOUNT KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_MAP; do
  grep -q "^config ${symbol}$" "$KSU_DIR/kernel/Kconfig" || {
    echo "[SUSFS][FATAL] Missing KernelSU config symbol: ${symbol}"
    exit 1
  }
done

echo "[SUSFS] Verified kernel SUSFS v1.5.12 + KernelSU integration"

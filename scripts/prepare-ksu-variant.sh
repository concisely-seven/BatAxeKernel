#!/usr/bin/env bash
set -euo pipefail

VARIANT="${1:-ksun}"
KERNEL_REF="${2:-b933b1f728116a456fbebf27b6a8772a640cdf23}"
MANAGER_REF="${3:-b2c1ad00b755afe0db74d889b67a137f56e71fcc}"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ "$VARIANT" != "ksun" ]]; then
  echo "This N971N workflow prepares only the KernelSU Next Legacy variant." >&2
  exit 2
fi

KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
KERNEL_SRC="ksu-src/ksun"
MANAGER_SRC="ksu-manager-src"
CONFIG="ci/ksu-configs/ksu-ksun.config"

rm -rf "$KERNEL_SRC" "$MANAGER_SRC"
mkdir -p ksu-src "$KERNEL_SRC" "$MANAGER_SRC"

# Full history is required: Legacy Kbuild derives KSU_VERSION from git commit count.
git -C "$KERNEL_SRC" init -q
git -C "$KERNEL_SRC" remote add origin "$KSU_REPO"
git -C "$KERNEL_SRC" fetch --tags origin "$KERNEL_REF"
git -C "$KERNEL_SRC" checkout --detach -q FETCH_HEAD
KERNEL_SHA="$(git -C "$KERNEL_SRC" rev-parse HEAD)"

# Legacy contains the built-in kernel driver only. Manager and userspace live on Dev.
# Keep full history because manager/build.gradle.kts uses git rev-list --count HEAD.
git -C "$MANAGER_SRC" init -q
git -C "$MANAGER_SRC" remote add origin "$KSU_REPO"
git -C "$MANAGER_SRC" fetch --tags origin "$MANAGER_REF"
git -C "$MANAGER_SRC" checkout --detach -q FETCH_HEAD
MANAGER_SHA="$(git -C "$MANAGER_SRC" rev-parse HEAD)"

for required in \
  "$KERNEL_SRC/kernel/Kconfig" \
  "$KERNEL_SRC/kernel/Makefile" \
  "$KERNEL_SRC/uapi/supercall.h" \
  "$MANAGER_SRC/manager/build.gradle.kts" \
  "$MANAGER_SRC/userspace/ksud/Cargo.toml" \
  "$MANAGER_SRC/userspace/ksuinit/Cargo.toml" \
  "$MANAGER_SRC/uapi/supercall.h" \
  "$CONFIG"; do
  if [[ ! -s "$required" ]]; then
    echo "Required KernelSU Next file missing: $required" >&2
    exit 3
  fi
done

grep -q '^config KSU_KPROBES_HOOK$' "$KERNEL_SRC/kernel/Kconfig" || {
  echo "Selected source does not expose CONFIG_KSU_KPROBES_HOOK" >&2
  exit 4
}
grep -q '^config KSU_MANUAL_HOOK$' "$KERNEL_SRC/kernel/Kconfig" || {
  echo "Selected source does not expose CONFIG_KSU_MANUAL_HOOK" >&2
  exit 4
}
grep -q '^CONFIG_KSU_KPROBES_HOOK=y$' "$CONFIG" || {
  echo "KSU config does not enable the actual Legacy Kprobes hook symbol" >&2
  exit 4
}

# Both source snapshots must expose the same ioctl ABI generation.
grep -Eq 'KERNEL_SU_UAPI_VERSION[[:space:]]+6|KERNEL_SU_UAPI_VERSION[[:space:]]*=[[:space:]]*6' "$KERNEL_SRC/uapi/supercall.h"
grep -Eq 'KERNEL_SU_UAPI_VERSION[[:space:]]+6|KERNEL_SU_UAPI_VERSION[[:space:]]*=[[:space:]]*6' "$MANAGER_SRC/uapi/supercall.h"

# BatAxeKernel already has Kbuild/Kconfig entries for drivers/kernelsu.
grep -q 'obj-$(CONFIG_KSU).*kernelsu/' drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig

if [[ -e drivers/kernelsu && ! -L drivers/kernelsu ]]; then
  echo "drivers/kernelsu exists and is not a symlink; refusing to overwrite it" >&2
  exit 5
fi
rm -f drivers/kernelsu
ln -s "../$KERNEL_SRC/kernel" drivers/kernelsu

cp "$CONFIG" arch/arm64/configs/ksu.config

mkdir -p build
{
  echo "variant=ksun"
  echo "kernel_repo=$KSU_REPO"
  echo "kernel_ref=$KERNEL_REF"
  echo "kernel_commit=$KERNEL_SHA"
  echo "manager_repo=$KSU_REPO"
  echo "manager_ref=$MANAGER_REF"
  echo "manager_commit=$MANAGER_SHA"
  echo "kernel_hook=CONFIG_KSU_KPROBES_HOOK"
  echo "kernel_uapi=6"
  echo "manager_uapi=6"
  echo "kernel_history=full"
  echo "manager_history=full"
} | tee build/ksu-source-info.txt

echo "Prepared KernelSU Next Legacy kernel $KERNEL_SHA"
echo "Prepared matching Dev manager/userspace $MANAGER_SHA"

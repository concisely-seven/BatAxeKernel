#!/usr/bin/env bash
set -euo pipefail

VARIANT="${1:-ksun}"
KERNEL_REF="${2:-b933b1f728116a456fbebf27b6a8772a640cdf23}"
MANAGER_REF="${3:-v3.4.2}"
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

# Fetch the exact Legacy driver revision used by the known-booting N971N build.
git -C "$KERNEL_SRC" init -q
git -C "$KERNEL_SRC" remote add origin "$KSU_REPO"
git -C "$KERNEL_SRC" fetch --tags origin "$KERNEL_REF"
git -C "$KERNEL_SRC" checkout --detach -q FETCH_HEAD
KERNEL_SHA="$(git -C "$KERNEL_SRC" rev-parse HEAD)"

# Fetch the official released Manager source only for ABI validation.
git -C "$MANAGER_SRC" init -q
git -C "$MANAGER_SRC" remote add origin "$KSU_REPO"
git -C "$MANAGER_SRC" fetch --tags origin "$MANAGER_REF"
git -C "$MANAGER_SRC" checkout --detach -q FETCH_HEAD
MANAGER_SHA="$(git -C "$MANAGER_SRC" rev-parse HEAD)"

for required in \
  "$KERNEL_SRC/kernel/Kconfig" \
  "$KERNEL_SRC/kernel/Makefile" \
  "$KERNEL_SRC/kernel/Kbuild" \
  "$KERNEL_SRC/uapi/supercall.h" \
  "$KERNEL_SRC/uapi/app_profile.h" \
  "$MANAGER_SRC/manager/app/src/main/java/com/rifsxd/ksunext/Natives.kt" \
  "$MANAGER_SRC/uapi/supercall.h" \
  "$MANAGER_SRC/uapi/app_profile.h" \
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
  echo "KSU config does not enable CONFIG_KSU_KPROBES_HOOK" >&2
  exit 4
}

# v3.4.2 expects kernel version >= 33188, UAPI v5 and App Profile v4.
grep -q 'MINIMAL_SUPPORTED_KERNEL = 33188' \
  "$MANAGER_SRC/manager/app/src/main/java/com/rifsxd/ksunext/Natives.kt" || {
  echo "Selected Manager source is not the expected v3.4.2 compatibility target" >&2
  exit 6
}
grep -q 'static const __u32 KERNEL_SU_UAPI_VERSION = 5;' "$MANAGER_SRC/uapi/supercall.h" || {
  echo "Selected Manager source does not expose UAPI v5" >&2
  exit 6
}
grep -q '^#define KERNEL_SU_UAPI_VERSION 6$' "$KERNEL_SRC/uapi/supercall.h" || {
  echo "Legacy kernel UAPI changed; review compatibility before patching" >&2
  exit 6
}
grep -q '^#define KSU_APP_PROFILE_VER 4$' "$KERNEL_SRC/uapi/app_profile.h"
grep -q '^#define KSU_APP_PROFILE_VER 4$' "$MANAGER_SRC/uapi/app_profile.h"
cmp -s "$KERNEL_SRC/uapi/app_profile.h" "$MANAGER_SRC/uapi/app_profile.h" || {
  echo "Kernel and v3.4.2 Manager App Profile ABI differs" >&2
  exit 6
}

# The Legacy driver is UAPI v6. v3.4.2 uses the complete v5 ABI; v6 only
# adds PREINIT reporting and LOOKUP_SYMBOLS, neither of which this Manager uses.
# Keep those driver implementations, but advertise the compatible v5 contract.
sed -i 's/^#define KERNEL_SU_UAPI_VERSION 6$/#define KERNEL_SU_UAPI_VERSION 5/' \
  "$KERNEL_SRC/uapi/supercall.h"
grep -q '^#define KERNEL_SU_UAPI_VERSION 5$' "$KERNEL_SRC/uapi/supercall.h" || {
  echo "Failed to apply the UAPI v5 compatibility declaration" >&2
  exit 6
}

# Keep the official Manager signing identity baked into the upstream Legacy Kbuild.
grep -q '^KSU_NEXT_MANAGER_SIZE := 0x3e6$' "$KERNEL_SRC/kernel/Kbuild" || {
  echo "Unexpected official Manager signature size in Legacy Kbuild" >&2
  exit 7
}
grep -q '^KSU_NEXT_MANAGER_HASH := 79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7$' \
  "$KERNEL_SRC/kernel/Kbuild" || {
  echo "Unexpected official Manager certificate hash in Legacy Kbuild" >&2
  exit 7
}

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
  echo "variant=ksun-legacy-official-manager"
  echo "kernel_repo=$KSU_REPO"
  echo "kernel_ref=$KERNEL_REF"
  echo "kernel_commit=$KERNEL_SHA"
  echo "manager_repo=$KSU_REPO"
  echo "manager_ref=$MANAGER_REF"
  echo "manager_commit=$MANAGER_SHA"
  echo "kernel_hook=CONFIG_KSU_KPROBES_HOOK"
  echo "kernel_uapi_implemented=6"
  echo "kernel_uapi_advertised=5"
  echo "manager_uapi=5"
  echo "app_profile_abi=4"
  echo "manager_version=v3.4.2"
  echo "manager_version_code=33355"
  echo "manager_signature_source=upstream-kernel-kbuild-default"
} | tee build/ksu-source-info.txt

echo "Prepared KernelSU Next Legacy kernel $KERNEL_SHA"
echo "Validated official KernelSU Next Manager source $MANAGER_SHA"
echo "Advertised UAPI v5 to the official v3.4.2 Manager; retained the driver's v6 additions."

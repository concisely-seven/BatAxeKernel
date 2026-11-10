#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/KernelSU"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

if ! grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
  if [[ -e "$ROOT/fs/susfs.c" || -e "$ROOT/include/linux/susfs.h" ]]; then
    echo "[SUSFS][FATAL] Existing SUSFS files found but version is not v1.5.12"
    exit 1
  fi

  # This upstream 1.5.12 patch is close to the device's 4.14 tree, but three
  # context hunks differ in the Samsung vendor sources. Accept only those
  # known rejects; every other rejected hunk is a hard failure.
  set +e
  patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-1.5.12.patch"
  PATCH_STATUS=$?
  set -e
  if [[ "$PATCH_STATUS" -gt 1 ]]; then
    echo "[SUSFS][FATAL] Kernel patch command failed with status $PATCH_STATUS"
    exit 1
  fi

  mapfile -t REJECTS < <(find "$ROOT" -name '*.rej' -type f | sort)
  EXPECTED_REJECTS=(
    "$ROOT/fs/namespace.c.rej"
    "$ROOT/fs/proc/cmdline.c.rej"
    "$ROOT/fs/proc/task_mmu.c.rej"
  )
  if [[ "${#REJECTS[@]}" -ne 3 ]]; then
    printf '[SUSFS][FATAL] Expected exactly 3 known vendor-context rejects; found %s\n' "${#REJECTS[@]}"
    printf '%s\n' "${REJECTS[@]}"
    exit 1
  fi
  for expected in "${EXPECTED_REJECTS[@]}"; do
    if [[ ! -f "$expected" ]]; then
      echo "[SUSFS][FATAL] Unexpected reject set; missing $expected"
      printf '%s\n' "${REJECTS[@]}"
      exit 1
    fi
  done

  # Manually port the three known context differences for this Samsung tree.
  # SUS_MAP is intentionally disabled in ksu.config because this vendor tree's
  # show_smap() layout differs; all other patched interfaces remain enabled.
  python3 - "$ROOT" <<'PY'
import pathlib, sys

root = pathlib.Path(sys.argv[1])

def replace_once(path, old, new, label):
    p = root / path
    data = p.read_text()
    if new.strip() in data:
        return
    count = data.count(old)
    if count != 1:
        raise SystemExit(f"[SUSFS][FATAL] {label}: expected one anchor in {path}, found {count}")
    p.write_text(data.replace(old, new, 1))

namespace_block = """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_zygote_domain(void);
extern bool susfs_is_boot_completed_triggered;

static DEFINE_IDA(susfs_mnt_id_ida);
static DEFINE_IDA(susfs_mnt_group_ida);
static int susfs_mnt_id_start = DEFAULT_SUS_MNT_ID;
static int susfs_mnt_group_start = DEFAULT_SUS_MNT_GROUP_ID;

#define CL_ZYGOTE_COPY_MNT_NS BIT(24)
#define CL_COPY_MNT_NS BIT(25)
#endif

#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);
bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
extern int susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);
bool susfs_is_auto_add_sus_bind_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);
bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;
#endif

"""
replace_once(
    "fs/namespace.c",
    '#include <linux/sched/task.h>\n',
    '#include <linux/sched/task.h>\n#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n#include <linux/susfs_def.h>\n#endif\n',
    "namespace susfs_def include"
)
replace_once("fs/namespace.c", '#include "internal.h"\n', '#include "internal.h"\n\n' + namespace_block, "namespace SUSFS declarations")

replace_once(
    "fs/proc/cmdline.c",
    '#include <asm/setup.h>\n',
    '#include <asm/setup.h>\n\n#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\nextern int susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);\n#endif\n',
    "cmdline SUSFS declaration"
)
replace_once(
    "fs/proc/cmdline.c",
    'static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n',
    'static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {\n\t\tseq_putc(m, \'\\n\');\n\t\treturn 0;\n\t}\n#endif\n',
    "cmdline SUSFS hook"
)
print("[SUSFS] Applied Samsung 4.14 namespace/cmdline compatibility hunks")
PY

  rm -f "${EXPECTED_REJECTS[@]}"
fi

mkdir -p "$ROOT/include/linux"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs.h" -o "$ROOT/include/linux/susfs.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs_def.h" -o "$ROOT/include/linux/susfs_def.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/fs/susfs.c" -o "$ROOT/fs/susfs.c"

if grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"; then
  echo "[SUSFS] KernelSU integration already present"
else
  patch --batch --forward -p1 -F3 -d "$KSU_DIR" < "$TMP_DIR/susfs-ksu-1.5.12.patch"
fi

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
test -s "$ROOT/fs/susfs.c"
for symbol in KSU_SUSFS KSU_SUSFS_HAS_MAGIC_MOUNT KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT KSU_SUSFS_TRY_UMOUNT KSU_SUSFS_SUS_MAP; do
  grep -q "^config ${symbol}$" "$KSU_DIR/kernel/Kconfig" || {
    echo "[SUSFS][FATAL] Missing KernelSU config symbol: ${symbol}"
    exit 1
  }
done

if find "$ROOT" -name '*.rej' -type f | grep -q .; then
  echo "[SUSFS][FATAL] Unresolved patch rejects remain"
  find "$ROOT" -name '*.rej' -type f
  exit 1
fi

echo "[SUSFS] Verified SUSFS v1.5.12 kernel layer + KernelSU integration"

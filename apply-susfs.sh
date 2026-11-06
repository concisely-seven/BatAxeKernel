#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/KernelSU"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# This is the exact KernelSU submodule revision from the known-good kernelsu-next branch.
EXPECTED_KSU_COMMIT="d4b7ffbbe19d6bffcafad9962439427727b74b05"
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

# Apply the Linux 4.14 SUSFS backport only once. This vendor 4.14 tree has
# three known context differences from the backport source; apply the remaining
# hunks, then add the equivalent missing code with guarded, exact replacements.
if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
  echo "[SUSFS] Kernel layer already has v1.5.12"
else
  if [[ -e "$ROOT/fs/susfs.c" || -e "$ROOT/include/linux/susfs.h" ]]; then
    echo "[SUSFS][FATAL] Existing SUSFS files found but version is not v1.5.12"
    exit 1
  fi

  PATCH_STATUS=0
  patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-1.5.12.patch" || PATCH_STATUS=$?

  if [[ "$PATCH_STATUS" -ne 0 ]]; then
    echo "[SUSFS] Backport returned status $PATCH_STATUS; checking known vendor-context rejects"
    for reject in fs/namespace.c.rej fs/proc/cmdline.c.rej fs/proc/task_mmu.c.rej; do
      test -s "$ROOT/$reject" || {
        echo "[SUSFS][FATAL] Unexpected patch failure; missing expected reject: $reject"
        exit 1
      }
    done
    REJECT_COUNT="$(find "$ROOT" -name '*.rej' -type f | wc -l)"
    test "$REJECT_COUNT" -eq 3 || {
      echo "[SUSFS][FATAL] Unexpected number of rejected patch files: $REJECT_COUNT"
      find "$ROOT" -name '*.rej' -type f
      exit 1
    }

    python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def replace_once(rel, old, new, description):
    path = root / rel
    data = path.read_text()
    if new in data:
        print(f"[SUSFS] Already applied: {description}")
        return
    if old not in data:
        raise SystemExit(f"[SUSFS][FATAL] Cannot adapt vendor context for {description} in {rel}")
    path.write_text(data.replace(old, new, 1))
    print(f"[SUSFS] Applied vendor-context adaptation: {description}")

replace_once(
    "fs/namespace.c",
    "#include <linux/sched/task.h>\n",
    "#include <linux/sched/task.h>\n"
    "#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n"
    "#include <linux/susfs_def.h>\n"
    "#endif\n",
    "namespace SUSFS definitions include"
)
replace_once(
    "fs/namespace.c",
    '#include "internal.h"\n',
    '#include "internal.h"\n\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    'extern bool susfs_is_current_ksu_domain(void);\n'
    'extern bool susfs_is_current_zygote_domain(void);\n'
    'extern bool susfs_is_boot_completed_triggered;\n'
    'static DEFINE_IDA(susfs_mnt_id_ida);\n'
    'static DEFINE_IDA(susfs_mnt_group_ida);\n'
    'static int susfs_mnt_id_start = DEFAULT_SUS_MNT_ID;\n'
    'static int susfs_mnt_group_start = DEFAULT_SUS_MNT_GROUP_ID;\n'
    '#define CL_ZYGOTE_COPY_MNT_NS BIT(24)\n'
    '#define CL_COPY_MNT_NS BIT(25)\n'
    '#endif\n'
    '#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT\n'
    'extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);\n'
    'bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;\n'
    '#endif\n'
    '#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT\n'
    'extern int susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);\n'
    'bool susfs_is_auto_add_sus_bind_mount_enabled = true;\n'
    '#endif\n'
    '#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT\n'
    'extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);\n'
    'bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;\n'
    '#endif\n',
    "namespace SUSFS mount declarations"
)
replace_once(
    "fs/proc/cmdline.c",
    "#include <asm/setup.h>\n",
    "#include <asm/setup.h>\n"
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
    "extern int susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);\n"
    "#endif\n",
    "proc cmdline SUSFS declaration"
)
replace_once(
    "fs/proc/cmdline.c",
    "static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n\tseq_puts(m, new_command_line);",
    "static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n"
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
    "\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {\n"
    "\t\tseq_putc(m, '\\n');\n"
    "\t\treturn 0;\n"
    "\t}\n"
    "#endif\n"
    "\tseq_puts(m, new_command_line);",
    "proc cmdline SUSFS spoof hook"
)
replace_once(
    "fs/proc/task_mmu.c",
    "vma_mmu_pagesize(vma) >> 10);\n",
    "vma_mmu_pagesize(vma) >> 10);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "bypass_orig_flow:\n"
    "#endif\n",
    "smaps SUSFS map bypass label"
)
replace_once(
    "fs/proc/task_mmu.c",
    "\tif (!rollup_mode) {\n\t\tarch_show_smap(m, vma);\n\t\tshow_smap_vma_flags(m, vma);\n\t}\n\tm_cache_vma(m, vma);",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\tif (vma->vm_file &&\n"
    "\t    unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&\n"
    "\t    susfs_is_current_non_root_user_app_proc()) {\n"
    "\t\tseq_puts(m, \"VmFlags: mr mw me\");\n"
    "\t\tseq_putc(m, '\\n');\n"
    "\t\tgoto bypass_orig_flow2;\n"
    "\t}\n"
    "#endif\n"
    "\tif (!rollup_mode) {\n\t\tarch_show_smap(m, vma);\n\t\tshow_smap_vma_flags(m, vma);\n\t}\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "bypass_orig_flow2:\n"
    "#endif\n"
    "\tm_cache_vma(m, vma);",
    "smaps SUSFS VmFlags spoof path"
)

for rel in ("fs/namespace.c.rej", "fs/proc/cmdline.c.rej", "fs/proc/task_mmu.c.rej"):
    (root / rel).unlink()
PY
  fi
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

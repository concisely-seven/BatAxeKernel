#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/ksu-src/ksun"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

KERNEL_PATCH_URL="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12/thesillyok-susfs-1.5.12-mod.patch"
KSUN_PATCH_URL="https://raw.githubusercontent.com/TheSillyOk/kernel_ls_patches/7acc04583b63772baf8c1d88cbde778775895798/KSUN/KSUN-SUSFS-1.5.12.patch"

test -d "$ROOT/fs"
test -f "$KSU_DIR/kernel/Kconfig"
test -L "$ROOT/drivers/kernelsu"
test "$(readlink "$ROOT/drivers/kernelsu")" = "../ksu-src/ksun/kernel"

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel.patch"
curl -fL --retry 3 "$KSUN_PATCH_URL" -o "$TMP_DIR/susfs-ksun.patch"

if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
  echo "[SUSFS] Kernel layer already patched"
else
  if test -e "$ROOT/fs/susfs.c" || test -e "$ROOT/include/linux/susfs.h"; then
    echo "[SUSFS][ERROR] SUSFS files exist but version is not v1.5.12"; exit 1
  fi

  # This backport is close to Exynos 4.14.113 but three contexts differ
  # in Samsung's namespace/cmdline/task_mmu files. Apply the matching hunks,
  # then port those three sites explicitly below.
  set +e
  patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel.patch"
  PATCH_STATUS=$?
  set -e
  echo "[SUSFS] Generic backport patch status=$PATCH_STATUS; porting Samsung-specific contexts"

  python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])

# namespace.c: Samsung adds fslog.h between sched/task.h and pnode.h.
p = root / "fs/namespace.c"
s = p.read_text()
if "#include <linux/susfs_def.h>" not in s:
    needle = "#include <linux/fslog.h>\n"
    assert needle in s, "namespace.c Samsung fslog.h anchor not found"
    s = s.replace(needle, needle + "#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n#include <linux/susfs_def.h>\n#endif\n", 1)
p.write_text(s)

# cmdline.c: preserve Samsung's new_command_line path and call SUSFS before it.
p = root / "fs/proc/cmdline.c"
s = p.read_text()
decl = "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\nextern int susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);\n#endif\n"
if "susfs_spoof_cmdline_or_bootconfig" not in s:
    anchor = "#include <asm/setup.h>\n"
    assert anchor in s, "cmdline.c include anchor not found"
    s = s.replace(anchor, anchor + decl, 1)
    anchor = "static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n"
    insert = anchor + "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {\n\t\tseq_putc(m, '\\n');\n\t\treturn 0;\n\t}\n#endif\n"
    assert anchor in s, "cmdline_proc_show anchor not found"
    s = s.replace(anchor, insert, 1)
p.write_text(s)

# task_mmu.c: Samsung's smaps code prints counters inline (no __show_smap helper).
p = root / "fs/proc/task_mmu.c"
s = p.read_text()
# Remove the upstream backport's first SUS_MAP block; replace the Samsung
# size-output site with an equivalent conditional, keeping rollup behavior.
block = """#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (vma->vm_file &&
			unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
			susfs_is_current_non_root_user_app_proc())
		{
			seq_printf(m,
				"Size:           %8lu kB\\n"
				"KernelPageSize: %8lu kB\\n"
				"MMUPageSize:    %8lu kB\\n",
				(vma->vm_end - vma->vm_start) >> 10,
				4, 4);
			goto bypass_orig_flow;
		}
#endif
"""
if block in s:
    s = s.replace(block, "", 1)
size_old = """	if (!rollup_mode)
		seq_printf(m,
			   "Size:           %8lu kB\\n"
			   "KernelPageSize: %8lu kB\\n"
			   "MMUPageSize:    %8lu kB\\n",
			   (vma->vm_end - vma->vm_start) >> 10,
			   vma_kernel_pagesize(vma) >> 10,
			   vma_mmu_pagesize(vma) >> 10);
"""
size_new = """	if (!rollup_mode) {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (vma->vm_file &&
		    unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
		    susfs_is_current_non_root_user_app_proc()) {
			seq_printf(m,
				   "Size:           %8lu kB\\n"
				   "KernelPageSize: %8lu kB\\n"
				   "MMUPageSize:    %8lu kB\\n",
				   (vma->vm_end - vma->vm_start) >> 10, 4, 4);
		} else
#endif
		seq_printf(m,
			   "Size:           %8lu kB\\n"
			   "KernelPageSize: %8lu kB\\n"
			   "MMUPageSize:    %8lu kB\\n",
			   (vma->vm_end - vma->vm_start) >> 10,
			   vma_kernel_pagesize(vma) >> 10,
			   vma_mmu_pagesize(vma) >> 10);
	}
"""
if size_old in s:
    s = s.replace(size_old, size_new, 1)
elif size_new not in s:
    raise SystemExit("task_mmu.c Samsung size-output anchor not found")

flags_old = """	if (!rollup_mode) {
		arch_show_smap(m, vma);
		show_smap_vma_flags(m, vma);
	}
"""
flags_new = """	if (!rollup_mode) {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (vma->vm_file &&
		    unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
		    susfs_is_current_non_root_user_app_proc()) {
			seq_puts(m, "VmFlags: mr mw me");
			seq_putc(m, '\\n');
		} else
#endif
		{
			arch_show_smap(m, vma);
			show_smap_vma_flags(m, vma);
		}
	}
"""
if flags_old in s:
    s = s.replace(flags_old, flags_new, 1)
elif flags_new not in s:
    raise SystemExit("task_mmu.c Samsung VmFlags anchor not found")
p.write_text(s)
PY

  rm -f "$ROOT"/fs/*.rej "$ROOT"/fs/proc/*.rej "$ROOT"/fs/*.orig "$ROOT"/fs/proc/*.orig
fi

# GoRhanHee's pinned revision already carries the SUSFS bridge in its
# KSU sources. Do not apply the generic bridge patch a second time.
if grep -q '^config KSU_SUSFS
grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
grep -q 'susfs_spoof_cmdline_or_bootconfig' "$ROOT/fs/proc/cmdline.c"
grep -q 'BIT_SUS_MAPS' "$ROOT/fs/proc/task_mmu.c"
grep -q 'CONFIG_KSU_SUSFS=y' "$ROOT/arch/arm64/configs/ksu.config"

echo "[SUSFS] Kernel v1.5.12 + KernelSU-Next bridge and Samsung smaps/cmdline/namespace ports verified"
 "$KSU_DIR/kernel/Kconfig" &&
   grep -q 'susfs_init();' "$KSU_DIR/kernel/ksu.c" &&
   grep -q 'susfs_zygote_sid' "$KSU_DIR/kernel/core_hook.c" &&
   grep -q 'susfs_set_ksu_sid' "$KSU_DIR/kernel/selinux/rules.c"; then
  echo "[SUSFS] KernelSU-Next already contains the SUSFS bridge; skipping duplicate KSUN patch"
else
  git -C "$KSU_DIR" apply --check "$TMP_DIR/susfs-ksun.patch"
  git -C "$KSU_DIR" apply "$TMP_DIR/susfs-ksun.patch"
fi

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
grep -q 'susfs_spoof_cmdline_or_bootconfig' "$ROOT/fs/proc/cmdline.c"
grep -q 'BIT_SUS_MAPS' "$ROOT/fs/proc/task_mmu.c"
grep -q 'CONFIG_KSU_SUSFS=y' "$ROOT/arch/arm64/configs/ksu.config"

echo "[SUSFS] Kernel v1.5.12 + KernelSU-Next bridge and Samsung smaps/cmdline/namespace ports verified"

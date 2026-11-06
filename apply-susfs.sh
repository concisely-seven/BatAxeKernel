#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/ksu-src/ksun"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

KERNEL_PATCH_URL="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12/thesillyok-susfs-1.5.12-mod.patch"
KSUN_PATCH_URL="https://raw.githubusercontent.com/concisely-seven/BatAxeKernel/test-ksun-susfs-bridge/patches/ksun-susfs-bridge.patch"

test -d "$ROOT/fs"
test -f "$KSU_DIR/kernel/Kconfig"
test -L "$ROOT/drivers/kernelsu"
test "$(readlink "$ROOT/drivers/kernelsu")" = "../ksu-src/ksun/kernel"

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel.patch"
curl -fL --retry 3 "$KSUN_PATCH_URL" -o "$TMP_DIR/susfs-ksun.patch"

# The backport diff only modifies existing kernel call sites; it does NOT
# create the SUSFS implementation files. Fetch the matching v1.5.12 sources.
SUSFS_BASE="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12"
mkdir -p "$ROOT/include/linux"
curl -fL --retry 3 "$SUSFS_BASE/fs/susfs.c" -o "$ROOT/fs/susfs.c"
curl -fL --retry 3 "$SUSFS_BASE/include/linux/susfs.h" -o "$ROOT/include/linux/susfs.h"
curl -fL --retry 3 "$SUSFS_BASE/include/linux/susfs_def.h" -o "$ROOT/include/linux/susfs_def.h"

# Linux 4.14 has linux/bitops.h; linux/bits.h was introduced later.
sed -i 's|#include <linux/bits.h>|#include <linux/bitops.h>|' "$ROOT/include/linux/susfs_def.h"
grep -q '#include <linux/bitops.h>' "$ROOT/include/linux/susfs_def.h"
grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"

if grep -q 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' "$ROOT/fs/Makefile" && grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"; then
  echo "[SUSFS] Kernel layer already patched"
else

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

# namespace.c: Samsung's 4.14 tree has fslog.h; locate includes by lines,
# and use a fallback include anchor if downstream changes remove that header.
p = root / "fs/namespace.c"
s = p.read_text()
if "#include <linux/susfs.h>" not in s:
    lines = s.splitlines(True)
    candidates = ("#include <linux/fslog.h>", "#include <linux/sched/task.h>", "#include <linux/idr.h>")
    idx = next((i for i, line in enumerate(lines) if any(line.startswith(x) for x in candidates)), None)
    assert idx is not None, "namespace.c: no stable Linux include anchor found"
    lines.insert(idx + 1, "#include <linux/susfs.h>\\n")
    s = "".join(lines)

if "static DEFINE_IDA(susfs_mnt_id_ida);" not in s:
    lines = s.splitlines(True)
    idx = next((i for i, line in enumerate(lines) if line.startswith("#include <linux/susfs.h>")), None)
    assert idx is not None, "namespace.c SUSFS include insertion failed"
    block = """#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT)
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
#if defined(CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT)
bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;
#endif
#if defined(CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT)
bool susfs_is_auto_add_sus_bind_mount_enabled = true;
#endif
#if defined(CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT)
bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;
#endif
"""
    lines.insert(idx + 1, block)
    s = "".join(lines)
p.write_text(s)

# avc.c: the upstream hunk targets a newer avc_dump_query signature and
# fuzz can place the body in the wrong function on this 4.14 tree.
p = root / "security/selinux/avc.c"
s = p.read_text()
bad = """#ifdef CONFIG_KSU_SUSFS
	if (unlikely(tsid == susfs_ksu_sid && susfs_is_avc_log_spoofing_enabled)) {
		if (rc)
			audit_log_format(ab, " tsid=%d", susfs_kernel_sid);
		else
			audit_log_format(ab, " tcontext=%s", "u:r:kernel:s0");
		goto bypass_orig_flow;
	}
#endif
"""
s = s.replace(bad, "")
s = s.replace("""	BUG_ON(!tclass || tclass >= ARRAY_SIZE(secclass_map));
	audit_log_format(ab, " tclass=%s", secclass_map[tclass-1].name);
}""", """#ifdef CONFIG_KSU_SUSFS
	if (unlikely(tsid == susfs_ksu_sid && susfs_is_avc_log_spoofing_enabled)) {
		if (rc)
			audit_log_format(ab, " tsid=%d", susfs_kernel_sid);
		else
			audit_log_format(ab, " tcontext=%s", "u:r:kernel:s0");
		goto bypass_orig_flow;
	}
#endif
	if (rc)
		audit_log_format(ab, " tsid=%d", tsid);
	else {
		audit_log_format(ab, " tcontext=%s", scontext);
		kfree(scontext);
	}
#ifdef CONFIG_KSU_SUSFS
bypass_orig_flow:
#endif
	BUG_ON(!tclass || tclass >= ARRAY_SIZE(secclass_map));
	audit_log_format(ab, " tclass=%s", secclass_map[tclass-1].name);
}""", 1)
p.write_text(s)

# fdinfo.c: the 4.14 inotify callback uses a C89 declaration after a label;
# make the label target an empty statement and avoid a newer helper unavailable here.
p = root / "fs/notify/fdinfo.c"
s = p.read_text()
s = s.replace("out_seq_printf:\\n#endif", "out_seq_printf:\\n\\t;\\n#endif")
s = s.replace("inotify_mark_user_mask(mark)", "(mark->mask & IN_ALL_EVENTS)")
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

# Apply the matching KernelSU-Next bridge; never substitute the RKSU tree.
git -C "$KSU_DIR" apply --check "$TMP_DIR/susfs-ksun.patch"
git -C "$KSU_DIR" apply "$TMP_DIR/susfs-ksun.patch"

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
grep -q 'susfs_spoof_cmdline_or_bootconfig' "$ROOT/fs/proc/cmdline.c"
grep -q 'BIT_SUS_MAPS' "$ROOT/fs/proc/task_mmu.c"
grep -q 'CONFIG_KSU_SUSFS=y' "$ROOT/arch/arm64/configs/ksu.config"

echo "[SUSFS] Kernel v1.5.12 + KernelSU-Next bridge and Samsung smaps/cmdline/namespace ports verified"

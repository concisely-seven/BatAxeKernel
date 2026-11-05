#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/ksu-src/ksun"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

KERNEL_PATCH_URL="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12/thesillyok-susfs-1.5.12-mod.patch"

test -d "$ROOT/fs"
test -f "$KSU_DIR/kernel/Kconfig"
test -L "$ROOT/drivers/kernelsu"
test "$(readlink "$ROOT/drivers/kernelsu")" = "../ksu-src/ksun/kernel"

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel.patch"
SUSFS_CORE_BASE="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12"
if ! test -f "$ROOT/fs/susfs.c" || ! test -f "$ROOT/include/linux/susfs.h" || ! test -f "$ROOT/include/linux/susfs_def.h"; then
  mkdir -p "$ROOT/fs" "$ROOT/include/linux"
  curl -fL --retry 3 "$SUSFS_CORE_BASE/fs/susfs.c" -o "$ROOT/fs/susfs.c"
  curl -fL --retry 3 "$SUSFS_CORE_BASE/include/linux/susfs.h" -o "$ROOT/include/linux/susfs.h"
  curl -fL --retry 3 "$SUSFS_CORE_BASE/include/linux/susfs_def.h" -o "$ROOT/include/linux/susfs_def.h"
fi
grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" || {
  echo "[SUSFS][ERROR] SUSFS core source is not v1.5.12"; exit 1;
}
# Linux 4.14 predates linux/bits.h; bitops.h provides the BIT() macros used here.
sed -i 's|#include <linux/bits.h>|#include <linux/bitops.h>|' "$ROOT/include/linux/susfs_def.h"


if grep -q 'susfs_is_mnt_devname_ksu' "$ROOT/fs/namespace.c" 2>/dev/null; then
  echo "[SUSFS] Kernel hooks already patched"
else
  grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" || {
    echo "[SUSFS][ERROR] SUSFS core source is not v1.5.12"; exit 1;
  }

  # This backport is close to Exynos 4.14.113 but three contexts differ
  # in Samsung's namespace/cmdline/task_mmu files. Apply the matching hunks,
  # then port those three sites explicitly below.
  python3 - "$TMP_DIR/susfs-kernel.patch" "$TMP_DIR/susfs-kernel-no-avc.patch" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
blocks = re.split(r'(?=^diff --git )', source, flags=re.M)
filtered = [block for block in blocks
            if not block.startswith("diff --git a/security/selinux/avc.c ")]
pathlib.Path(sys.argv[2]).write_text("".join(filtered))
PY
  set +e
  patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-no-avc.patch"
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

# namespace.c: the first upstream hunk does not match Samsung's fslog.h block.
decl = """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
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
if "static DEFINE_IDA(susfs_mnt_id_ida)" not in s:
    anchor = '#include "internal.h"\n'
    assert anchor in s, "namespace.c internal.h anchor not found"
    s = s.replace(anchor, anchor + decl, 1)
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

# avc.c: upstream hunk assumes the newer SELinux-state signature; Samsung 4.14
# uses security_sid_to_context(sid, ...), so port the same spoof at this callsite.
# fdinfo.c: the SUSFS hunk adds a label before the legacy C89 declaration.
p = root / "fs/notify/fdinfo.c"
s = p.read_text()
if "out_seq_printf:" in s:
    anchor = "\tif (inode) {\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
    if anchor not in s:
        raise SystemExit("fdinfo inotify SUSFS block anchor not found")
    s = s.replace(anchor, "\tif (inode) {\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT", 1)
    s = s.replace("\t\tu32 mask = mark->mask & IN_ALL_EVENTS;\n\t\tseq_printf", "\t\tseq_printf", 1)
    s = s.replace("inotify_mark_user_mask(mark)", "mask")
    fanotify = "static void fanotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark)"
    if fanotify in s:
        s = s.replace(fanotify, "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nstatic void fanotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark, struct file *file)\n#else\n" + fanotify + "\n#endif", 1)
        s = s.replace("\tunsigned int mflags = 0;\n", "\tunsigned int mflags = 0;\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\t(void)file;\n#endif\n", 1)
    p.write_text(s)

p = root / "security/selinux/avc.c"
s = p.read_text()
if "bool susfs_is_avc_log_spoofing_enabled" not in s:
    anchor = "#endif\n\nstruct avc_entry {"
    decl = """#endif

#ifdef CONFIG_KSU_SUSFS
extern u32 susfs_ksu_sid;
extern u32 susfs_kernel_sid;
bool susfs_is_avc_log_spoofing_enabled = false;
#endif

struct avc_entry {"""
    assert anchor in s, "avc.c AVC stats declaration anchor not found"
    s = s.replace(anchor, decl, 1)
if "bypass_susfs_avc_spoof" not in s:
    func_start = s.index("static void avc_dump_query(")
    func_end = s.index("\n}\n", func_start) + 3
    body = s[func_start:func_end]
    anchor = "rc = security_sid_to_context(tsid, &scontext, &scontext_len);\n"
    insert = anchor + """#ifdef CONFIG_KSU_SUSFS
	if (unlikely(tsid == susfs_ksu_sid && susfs_is_avc_log_spoofing_enabled)) {
		if (rc)
			audit_log_format(ab, " tsid=%d", susfs_kernel_sid);
		else {
			audit_log_format(ab, " tcontext=%s", "u:r:kernel:s0");
			kfree(scontext);
		}
		goto bypass_susfs_avc_spoof;
	}
#endif
"""
    assert anchor in body, "avc_dump_query target SID conversion anchor not found"
    body = body.replace(anchor, insert, 1)
    anchor = "\tBUG_ON(!tclass || tclass >= ARRAY_SIZE(secclass_map));"
    insert = "#ifdef CONFIG_KSU_SUSFS\nbypass_susfs_avc_spoof:\n#endif\n" + anchor
    assert anchor in body, "avc_dump_query tclass anchor not found"
    body = body.replace(anchor, insert, 1)
    s = s[:func_start] + body + s[func_end:]
p.write_text(s)
PY

  rm -f "$ROOT"/fs/*.rej "$ROOT"/fs/proc/*.rej "$ROOT"/fs/*.orig "$ROOT"/fs/proc/*.orig
fi

# Apply the modern bridge against the pinned KernelSU-Next legacy layout.
python3 -m py_compile "$ROOT/scripts/apply-ksun-susfs-modern.py"
test -s "$ROOT/fs/susfs.c"
test -s "$ROOT/include/linux/susfs_def.h"
python3 "$ROOT/scripts/apply-ksun-susfs-modern.py" "$KSU_DIR" "$ROOT"

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
grep -q 'susfs_spoof_cmdline_or_bootconfig' "$ROOT/fs/proc/cmdline.c"
grep -q 'susfs_handle_prctl' "$ROOT/kernel/sys.c"
grep -q 'susfs_prctl.o' "$ROOT/fs/Makefile"
grep -q 'BIT_SUS_MAPS' "$ROOT/fs/proc/task_mmu.c"
grep -q 'CONFIG_KSU_SUSFS=y' "$ROOT/arch/arm64/configs/ksu.config"

echo "[SUSFS] Kernel v1.5.12 + KernelSU-Next bridge and Samsung smaps/cmdline/namespace ports verified"

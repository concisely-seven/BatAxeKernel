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

# The upstream avc.c hunk targets a newer SELinux function signature and
# fuzzily lands inside avc_init() on this 4.14 tree. Port that hunk below.
python3 - "$TMP_DIR/susfs-kernel.patch" <<'PYFILTER'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
parts = p.read_text().split("diff --git ")
kept = [x for x in parts if not x.startswith("a/security/selinux/avc.c ") and not x.startswith("a/fs/notify/fdinfo.c ") and not x.startswith("a/fs/proc/task_mmu.c ")]
p.write_text("".join("diff --git " + x for x in kept))
PYFILTER

if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
  echo "[SUSFS] Kernel layer already patched"
else
  if test -e "$ROOT/fs/susfs.c" || test -e "$ROOT/include/linux/susfs.h"; then
    echo "[SUSFS][ERROR] SUSFS files exist but version is not v1.5.12"; exit 1
  fi

  # Import the exact v1.5.12 core files paired with the kernel patch.
  # The patch modifies call sites; it does not create these three source files.
  SUSFS_FILES_BASE="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12"
  curl -fL --retry 3 "$SUSFS_FILES_BASE/fs/susfs.c" -o "$ROOT/fs/susfs.c"
  curl -fL --retry 3 "$SUSFS_FILES_BASE/include/linux/susfs.h" -o "$ROOT/include/linux/susfs.h"
  curl -fL --retry 3 "$SUSFS_FILES_BASE/include/linux/susfs_def.h" -o "$ROOT/include/linux/susfs_def.h"

  # Linux 4.14.113 does not provide <linux/bits.h>; its BIT()/GENMASK()
  # definitions are provided by <linux/bitops.h>. Keep SUSFS 1.5.12
  # definitions intact while using the 4.14-compatible header.
  sed -i 's|#include <linux/bits.h>|#include <linux/bitops.h>|' "$ROOT/include/linux/susfs_def.h"

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
# The upstream first namespace hunk does not match Samsung's fslog.h
# include block. Install its declarations explicitly before SUSFS call sites.
ns_decl = '''\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
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
'''
if "extern bool susfs_is_current_ksu_domain(void);" not in s:
    anchor = "#include <linux/susfs_def.h>\n#endif\n"
    assert anchor in s, "namespace.c SUSFS header anchor not found"
    s = s.replace(anchor, anchor + ns_decl, 1)
p.write_text(s)

# avc.c: the 4.14 signature is avc_dump_query(ab, ssid, tsid, tclass),
# and security_sid_to_context() has no selinux_state argument.
p = root / "security/selinux/avc.c"
s = p.read_text()
if "susfs_is_avc_log_spoofing_enabled" not in s:
    anchor = "struct avc_entry {\n"
    decl = """#ifdef CONFIG_KSU_SUSFS
extern u32 susfs_ksu_sid;
extern u32 susfs_kernel_sid;
bool susfs_is_avc_log_spoofing_enabled = false;
#endif

"""
    assert anchor in s, "avc.c struct avc_entry anchor not found"
    s = s.replace(anchor, decl + anchor, 1)
needle = """\trc = security_sid_to_context(tsid, &scontext, &scontext_len);\n\tif (rc)\n\t\taudit_log_format(ab, " tsid=%d", tsid);"""
insert = """\trc = security_sid_to_context(tsid, &scontext, &scontext_len);\n#ifdef CONFIG_KSU_SUSFS
\tif (unlikely(tsid == susfs_ksu_sid && susfs_is_avc_log_spoofing_enabled)) {
\t\tif (!rc)
\t\t\tkfree(scontext);
\t\tif (rc)
\t\t\taudit_log_format(ab, " tsid=%d", susfs_kernel_sid);
\t\telse
\t\t\taudit_log_format(ab, " tcontext=%s", "u:r:kernel:s0");
\t\tgoto bypass_orig_flow;
\t}
#endif
\tif (rc)
\t\taudit_log_format(ab, " tsid=%d", tsid);"""
if "goto bypass_orig_flow;" not in s:
    assert needle in s, "avc.c target SID conversion anchor not found"
    s = s.replace(needle, insert, 1)
# Place the label inside avc_dump_query(), not avc_dump_av().
if "bypass_orig_flow:" not in s:
    fn = s.index("static void avc_dump_query(")
    pos = s.index("\tBUG_ON(!tclass || tclass >= ARRAY_SIZE(secclass_map));", fn)
    s = s[:pos] + "#ifdef CONFIG_KSU_SUSFS\nbypass_orig_flow:\n#endif\n" + s[pos:]
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
    insert = anchor + "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {\n\t\tseq_putc(m, '\n');\n\t\treturn 0;\n\t}\n#endif\n"
    assert anchor in s, "cmdline_proc_show anchor not found"
    s = s.replace(anchor, insert, 1)
p.write_text(s)

# task_mmu.c: Samsung 4.14 source is patched below using structural anchors.
p = root / "fs/proc/task_mmu.c"
s = p.read_text()
if "#include <linux/susfs.h>" not in s:
    anchor = "#include <linux/freezer.h>\\n"
    assert anchor in s, "task_mmu.c include anchor not found"
    s = s.replace(anchor, anchor + "#include <linux/susfs.h>\\n", 1)
p.write_text(s)

# Remove the upstream backport's first SUS_MAP block; replace the Samsung
# size-output site with an equivalent conditional, keeping rollup behavior.
block = """#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (vma->vm_file &&
			unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
			susfs_is_current_non_root_user_app_proc())
		{
			seq_printf(m,
				"Size:           %8lu kB\n"
				"KernelPageSize: %8lu kB\n"
				"MMUPageSize:    %8lu kB\n",
				(vma->vm_end - vma->vm_start) >> 10,
				4, 4);
			goto bypass_orig_flow;
		}
#endif
"""
if block in s:
    s = s.replace(block, "", 1)
# Locate the complete Samsung Size block by its semantic markers, not
# whitespace-sensitive copied source text. This is the original 4.14 show_smap block.
size_start = s.find("\\tif (!rollup_mode)\\n\\t\\tseq_printf(m,")
if size_start < 0 or '"Size:' not in s[size_start:size_start + 500]:
    raise SystemExit("task_mmu.c Samsung show_smap Size block not found")
size_end_marker = "\\t\\t\\t   vma_mmu_pagesize(vma) >> 10);"
size_end = s.find(size_end_marker, size_start)
if size_end < 0:
    raise SystemExit("task_mmu.c Samsung Size block terminator not found")
size_end += len(size_end_marker)
size_new = """\\tif (!rollup_mode) {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\\t\\tif (vma->vm_file &&
\\t\\t    unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
\\t\\t    susfs_is_current_non_root_user_app_proc()) {
\\t\\t\\tseq_printf(m,
\\t\\t\\t\\t   \\"Size:           %8lu kB\\\\n\\"
\\t\\t\\t\\t   \\"KernelPageSize: %8lu kB\\\\n\\"
\\t\\t\\t\\t   \\"MMUPageSize:    %8lu kB\\\\n\\",
\\t\\t\\t\\t   (vma->vm_end - vma->vm_start) >> 10, 4, 4);
\\t\\t} else
#endif
\\t\\tseq_printf(m,
\\t\\t\\t   \\"Size:           %8lu kB\\\\n\\"
\\t\\t\\t   \\"KernelPageSize: %8lu kB\\\\n\\"
\\t\\t\\t   \\"MMUPageSize:    %8lu kB\\\\n\\",
\\t\\t\\t   (vma->vm_end - vma->vm_start) >> 10,
\\t\\t\\t   vma_kernel_pagesize(vma) >> 10,
\\t\\t\\t   vma_mmu_pagesize(vma) >> 10);
\\t}
"""
s = s[:size_start] + size_new + s[size_end:]

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
			seq_putc(m, '\n');
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

# GoRhanHee KSUN test refs already contain the SUSFS bridge.
if [[ "${SKIP_KSUN_PATCH:-0}" != "1" ]]; then
  git -C "$KSU_DIR" apply --check "$TMP_DIR/susfs-ksun.patch"
  git -C "$KSU_DIR" apply "$TMP_DIR/susfs-ksun.patch"
else
  echo "[SUSFS] Skipping duplicate GoRhanHee KSUN bridge patch"
fi

grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
grep -q 'susfs_spoof_cmdline_or_bootconfig' "$ROOT/fs/proc/cmdline.c"
grep -q 'BIT_SUS_MAPS' "$ROOT/fs/proc/task_mmu.c"
grep -q 'CONFIG_KSU_SUSFS=y' "$ROOT/arch/arm64/configs/ksu.config"

echo "[SUSFS] Kernel v1.5.12 + KernelSU-Next bridge and Samsung smaps/cmdline/namespace ports verified"

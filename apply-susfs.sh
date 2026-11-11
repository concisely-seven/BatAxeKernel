#!/usr/bin/env bash
# Run #8-derived RKSU + SUSFS v2.4.0 integration for Samsung Exynos 9825 / Linux 4.14.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/KernelSU"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EXPECTED_KSU_COMMIT="9b28326af4145974560122644e87fc9a021a2cce"
SUSFS_PATCH_URL="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/4b0766bdf5d568b695dfbb19994788f14c636f2b/Patches/Patch/susfs_patch_to_4.14.patch"

test -d "$ROOT/fs"
test -f "$KSU_DIR/kernel/supercalls.c"
ACTUAL_KSU_COMMIT="$(git -C "$KSU_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_KSU_COMMIT" != "$EXPECTED_KSU_COMMIT" ]]; then
  echo "[SUSFS][FATAL] KernelSU submodule changed: expected $EXPECTED_KSU_COMMIT, got $ACTUAL_KSU_COMMIT"
  exit 1
fi
echo "[KSU] Pinned Run #8 RKSU source verified: $ACTUAL_KSU_COMMIT"

# Do not mix any files from the older v1.5.12 kernel-side backport.
if [[ -e "$ROOT/fs/susfs.c" || -e "$ROOT/include/linux/susfs.h" || -e "$ROOT/include/linux/susfs_def.h" ]]; then
  echo "[SUSFS][FATAL] Existing SUSFS implementation found before v2.4.0 application"
  exit 1
fi

curl -fL --retry 3 "$SUSFS_PATCH_URL" -o "$TMP_DIR/susfs-v2.4.0-4.14.patch"
# The generic 4.14 patch has a malformed AVC hunk for this Samsung tree.
# Drop only that file's hunk and apply the compatible AVC spoofing logic below.
python3 - "$TMP_DIR/susfs-v2.4.0-4.14.patch" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
out = []
skip = False
for line in lines:
    if line.startswith("diff --git "):
        skip = " b/security/selinux/avc.c" in line
    if not skip:
        out.append(line)
p.write_text("".join(out))
print("[SUSFS] Excluded generic avc.c hunk; Samsung 4.14 AVC port will be applied explicitly")
PY
grep -q '+#define SUSFS_VERSION "v2.4.0"' "$TMP_DIR/susfs-v2.4.0-4.14.patch"
grep -q '+#define SUSFS_MAGIC 0xFAFAFAFA' "$TMP_DIR/susfs-v2.4.0-4.14.patch"

# Apply all upstream hunks. Fuzz is deliberately bounded; all rejects are
# printed and retained in the build log so the Samsung-specific port can be
# corrected from concrete source context, rather than silently discarded.
set +e
patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-v2.4.0-4.14.patch"
PATCH_STATUS=$?
set -e
if [[ "$PATCH_STATUS" -gt 1 ]]; then
  echo "[SUSFS][FATAL] patch utility failed with status $PATCH_STATUS"
  exit "$PATCH_STATUS"
fi
REJECTS="$(find "$ROOT" -type f -name '*.rej' -print | sort || true)"
if [[ -n "$REJECTS" ]]; then
  echo "[SUSFS][PORT-REQUIRED] v2.4.0 has context rejects on this Samsung 4.14.113 tree:"
  printf '%s\n' "$REJECTS"
else
  echo "[SUSFS] Upstream v2.4.0 patch applied without rejects"
fi

# Linux 4.14 has BIT() in bitops.h, not linux/bits.h.
if [[ -f "$ROOT/include/linux/susfs_def.h" ]]; then
  sed -i 's|#include <linux/bits.h>|#include <linux/bitops.h>|' "$ROOT/include/linux/susfs_def.h"
  grep -q '#include <linux/bitops.h>' "$ROOT/include/linux/susfs_def.h"
fi

# This Samsung tree exposes new_command_line rather than saved_command_line.
# Provide the v2.4.0 /proc/cmdline hook in the existing proc_cmdline formatter.
python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])

cmd = root / "fs/proc/cmdline.c"
s = cmd.read_text()
if "susfs_spoof_cmdline_or_bootconfig" not in s:
    anchor = "#include <asm/setup.h>\n"
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] cmdline.c asm/setup.h include anchor missing")
    decl = """#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
extern struct static_key_false susfs_is_fake_cmdline_or_bootconfig_buffer_set;
extern void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);
#endif

"""
    s = s.replace(anchor, anchor + decl, 1)

if "static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)" not in s:
    pattern = r"(static int cmdline_proc_show\(struct seq_file \*m, void \*v\)\n\{\n)"
    repl = r"""\1#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	if (static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)) {
		susfs_spoof_cmdline_or_bootconfig(m);
		seq_putc(m, '\n');
		return 0;
	}
#endif
"""
    s2, count = re.subn(pattern, repl, s, count=1)
    if count != 1:
        raise SystemExit("[SUSFS][FATAL] cmdline_proc_show insertion point missing")
    s = s2
cmd.write_text(s)

# The 4.14 Samsung inotify header lacks inotify_mark_user_mask(). Its
# historical implementation is exactly (mark->mask & IN_ALL_EVENTS).
ih = root / "fs/notify/inotify/inotify.h"
s = ih.read_text()
if "inotify_mark_user_mask(" not in s:
    helper = """
#ifdef CONFIG_KSU_SUSFS
static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark)
{
	return mark->mask & IN_ALL_EVENTS;
}
#endif
"""
    # Put the compatibility helper after the includes and before structures.
    anchor = "#include <linux/slab.h> /* struct kmem_cache */\n"
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] inotify.h include anchor missing")
    s = s.replace(anchor, anchor + helper, 1)
    ih.write_text(s)

# Manually adapt the two known context-only rejects against this Samsung 4.14.113 tree.
# The functional namespace/readdir hunks have applied; these rejects are the
# Samsung include placement and a local filldir declaration layout difference.
ns = root / "fs/namespace.c"
s = ns.read_text()
if "#include <linux/susfs_def.h>" not in s:
    anchor = "#include <linux/sched/task.h>\n"
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] namespace.c sched/task include anchor missing")
    s = s.replace(anchor, anchor + "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n#include <linux/jump_label.h>\n", 1)
if "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;" not in s:
    anchor = '#include "internal.h"\n'
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] namespace.c internal.h anchor missing")
    block = """\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif // CONFIG_KSU_SUSFS_SUS_MOUNT
"""
    s = s.replace(anchor, anchor + block, 1)
ns.write_text(s)

# Keep the LSPosed/Vector Dex2Oat wrapper visible to its root KSU-domain
# stat() check even when SUSFS marks that task as umounted. Do not lower the
# fake mount ID: the wrapper mount must remain hidden from ordinary app views.
python3 - "$ROOT" <<'PY'
import pathlib, sys

root = pathlib.Path(sys.argv[1])
ns = root / "fs/namespace.c"
s = ns.read_text()

for header in ("#include <linux/string.h>\\n", "#include <linux/printk.h>\\n"):
    if header not in s:
        anchor = "#include <linux/sched/task.h>\\n"
        if anchor not in s:
            raise SystemExit("[SUSFS][DEX2OAT][FATAL] namespace.c sched/task include anchor missing")
        s = s.replace(anchor, anchor + header, 1)

helper = """\\nstatic inline bool susfs_is_dex2oat_target_dentry(const struct dentry *dentry)
{
    const char *name;

    if (!dentry)
        return false;

    name = dentry->d_name.name;
    return !strcmp(name, "dex2oat") ||
           !strcmp(name, "dex2oat32") ||
           !strcmp(name, "dex2oat64") ||
           !strcmp(name, "dex2oatd") ||
           !strcmp(name, "dex2oatd32") ||
           !strcmp(name, "dex2oatd64");
}
"""
if "susfs_is_dex2oat_target_dentry" not in s:
    anchor = "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\\n"
    if s.count(anchor) != 1:
        raise SystemExit("[SUSFS][DEX2OAT][FATAL] namespace.c CL_COPY_MNT_NS anchor mismatch")
    s = s.replace(anchor, anchor + helper, 1)

old = """\\tif (susfs_is_current_proc_umounted()) {
\\t\\thlist_for_each_entry_rcu(p, head, mnt_hash)
\\t\\t\\tif (p->mnt_id < DEFAULT_KSU_MNT_ID && &p->mnt_parent->mnt == mnt && p->mnt_mountpoint == dentry)
\\t\\t\\t\\treturn p;
\\t\\treturn NULL;
\\t}"""
new = """\\tif (susfs_is_current_proc_umounted()) {
\\t\\thlist_for_each_entry_rcu(p, head, mnt_hash) {
\\t\\t\\tif (&p->mnt_parent->mnt == mnt && p->mnt_mountpoint == dentry) {
\\t\\t\\t\\tif (p->mnt_id < DEFAULT_KSU_MNT_ID)
\\t\\t\\t\\t\\treturn p;
\\t\\t\\t\\t/*
\\t\\t\\t\\t * LSPosed/Vector checks its ART bind mounts with stat()
\\t\\t\\t\\t * through /proc/1/root. Let only the root KSU domain resolve
\\t\\t\\t\\t * these exact wrapper mountpoints; keep their high SUSFS IDs
\\t\\t\\t\\t * so normal app mount views continue hiding them.
\\t\\t\\t\\t */
\\t\\t\\t\\tif (susfs_is_current_ksu_domain() &&
\\t\\t\\t\\t    susfs_is_dex2oat_target_dentry(dentry)) {
\\t\\t\\t\\t\\tpr_info_ratelimited("[SUSFS][DEX2OAT] allow KSU wrapper lookup: %s mnt_id=%d\\n",
\\t\\t\\t\\t\\t\\tdentry->d_name.name, p->mnt_id);
\\t\\t\\t\\t\\treturn p;
\\t\\t\\t\\t}
\\t\\t\\t}
\\t\\t}
\\t\\treturn NULL;
\\t}"""
if "SUSFS][DEX2OAT] allow KSU wrapper lookup" not in s:
    if s.count(old) != 1:
        raise SystemExit("[SUSFS][DEX2OAT][FATAL] __lookup_mnt umounted-filter anchor mismatch")
    s = s.replace(old, new, 1)

if "susfs_is_dex2oat_target_dentry(dentry)" not in s:
    raise SystemExit("[SUSFS][DEX2OAT][FATAL] wrapper lookup exception verification failed")
ns.write_text(s)
print("[SUSFS][DEX2OAT] KSU-domain wrapper path lookup exception applied; fake mount IDs retained")
PY

rd = root / "fs/readdir.c"
s = rd.read_text()
if "static int filldir(" not in s:
    raise SystemExit("[SUSFS][FATAL] readdir.c filldir() function missing")
fill_start = s.index("static int filldir(")
fill_end = s.index("\n}", fill_start)
fill = s[fill_start:fill_end]
decl = "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct inode *inode;\n#endif\n"
if "struct inode *inode;" not in fill:
    anchor = "\tint reclen = ALIGN(offsetof(struct linux_dirent, d_name) + namlen + 2,\n\t\tsizeof(long));\n"
    if anchor not in fill:
        raise SystemExit("[SUSFS][FATAL] readdir.c filldir() reclen declaration context missing")
    fill = fill.replace(anchor, anchor + "\n" + decl, 1)
    s = s[:fill_start] + fill + s[fill_end:]
    rd.write_text(s)

# Apply the Samsung 4.14.113 AVC and inotify adaptations explicitly.
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])

# KSTAT's fs/stat.c hunk calls helpers and STATX_SUS_KSTAT flags from
# susfs_def.h. The generic 4.14 patch does not add this include, which caused
# the Run #46 undeclared-identifier / implicit-declaration errors.
stat = root / "fs/stat.c"
s = stat.read_text()
if '#include <linux/susfs_def.h>' not in s:
    anchor = '#include <linux/compat.h>\n'
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] fs/stat.c compat.h include anchor missing")
    s = s.replace(anchor, anchor + "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n", 1)
stat.write_text(s)
if '#define STATX_SUS_KSTAT 0x10000000U' not in (root / "include/linux/susfs_def.h").read_text():
    raise SystemExit("[SUSFS][FATAL] STATX_SUS_KSTAT definitions missing from susfs_def.h")
if 'susfs_is_current_app_uid' not in stat.read_text():
    raise SystemExit("[SUSFS][FATAL] KSTAT call site missing from fs/stat.c after patch")
if '#include <linux/susfs_def.h>' not in stat.read_text():
    raise SystemExit("[SUSFS][FATAL] fs/stat.c does not include SUSFS KSTAT definitions")
print("[SUSFS] fs/stat.c KSTAT declarations and STATX flags include verified")

# AVC: preserve the original if/else pair. The generic patch placed a goto
# between them, which is invalid C and also omitted the target label.
avc = root / "security/selinux/avc.c"
s = avc.read_text()
for inc in ("#include <linux/jump_label.h>\n",):
    if inc not in s:
        anchor = '#include <linux/ipv6.h>\n'
        if anchor not in s:
            raise SystemExit("[SUSFS][FATAL] avc.c include anchor missing")
        s = s.replace(anchor, anchor + inc, 1)
decls = """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_false susfs_is_avc_log_spoofing_enabled;
extern u32 susfs_ksu_sid;
extern u32 susfs_priv_app_sid;
#endif

"""
if "extern struct static_key_false susfs_is_avc_log_spoofing_enabled;" not in s:
    anchor = '#include "classmap.h"\n'
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] avc.c classmap include anchor missing")
    s = s.replace(anchor, anchor + decls, 1)
needle = "\trc = security_sid_to_context(tsid, &scontext, &scontext_len);\n\tif (rc)"
block = """\trc = security_sid_to_context(tsid, &scontext, &scontext_len);
#ifdef CONFIG_KSU_SUSFS
\tif (static_branch_likely(&susfs_is_avc_log_spoofing_enabled)) {
\t\tif (unlikely(tsid == susfs_ksu_sid)) {
\t\t\tif (rc)
\t\t\t\taudit_log_format(ab, " tsid=%d", susfs_priv_app_sid);
\t\t\telse
\t\t\t\taudit_log_format(ab, " tcontext=%s", "u:r:priv_app:s0:c512,c768");
\t\t\tgoto bypass_orig_flow;
\t\t}
\t}
#endif
\tif (rc)"""
if "goto bypass_orig_flow;" not in s:
    if needle not in s:
        raise SystemExit("[SUSFS][FATAL] avc.c second security_sid_to_context anchor missing")
    s = s.replace(needle, block, 1)
else:
    # If a previous patch fragment remains, fail closed rather than compile malformed flow.
    raise SystemExit("[SUSFS][FATAL] unexpected generic AVC bypass fragment remains")
end = '\t\tkfree(scontext);\n\t}\n\n\tBUG_ON(!tclass'
replacement = '\t\tkfree(scontext);\n\t}\n#ifdef CONFIG_KSU_SUSFS\nbypass_orig_flow:\n#endif\n\n\tBUG_ON(!tclass'
if "bypass_orig_flow:" not in s:
    if end not in s:
        raise SystemExit("[SUSFS][FATAL] avc.c bypass label insertion anchor missing")
    s = s.replace(end, replacement, 1)
avc.write_text(s)

# fdinfo: Linux 4.14 is built as GNU89; keep mask in the function's
# declaration block rather than introducing it after executable statements.
fd = root / "fs/notify/fdinfo.c"
s = fd.read_text()
m = re.search(r"(static void inotify_fdinfo\([^\n]*\n(?:[^\n]*\n)*?\{)(.*?)(\n\})", s, re.S)
if not m:
    raise SystemExit("[SUSFS][FATAL] inotify_fdinfo function not found")
head, body, tail = m.groups()
body = body.replace("u32 mask = mark->mask & IN_ALL_EVENTS;", "mask = mark->mask & IN_ALL_EVENTS;")
if "mask = mark->mask & IN_ALL_EVENTS;" in body and not re.search(r"^\s*u32 mask;", body, re.M):
    if "struct inode *inode;" not in body:
        raise SystemExit("[SUSFS][FATAL] fdinfo inode declaration anchor missing")
    body = body.replace("struct inode *inode;", "struct inode *inode;\n\tu32 mask;", 1)
s = s[:m.start()] + head + body + tail + s[m.end():]
fd.write_text(s)

# The v2.4.0 source uses its rate-limited logging macro from susfs_def.h.
sus = root / "fs/susfs.c"
ss = sus.read_text()
if '#include <linux/susfs_def.h>' not in ss:
    anchor = '#include <linux/susfs.h>\n'
    if anchor not in ss:
        ss = '#include <linux/susfs_def.h>\n' + ss
    else:
        ss = ss.replace(anchor, anchor + '#include <linux/susfs_def.h>\n', 1)
sus.write_text(ss)
print("[SUSFS] Samsung AVC flow, GNU89 inotify declaration, and logging header adapted")

# Reject files are removed only after the equivalent source edits above succeed.
(root / "fs/namespace.c.rej").unlink(missing_ok=True)
(root / "fs/readdir.c.rej").unlink(missing_ok=True)
print("[SUSFS] Samsung namespace include/declaration and readdir filldir declaration adapted")
# Synchronize the old Run #8 RKSU supercall dispatcher with the v2.4.0 ABI.
sc = root / "KernelSU/kernel/supercalls.c"
s = sc.read_text()
start = s.find("\t// If magic2 is susfs and current process is root")
end = s.find("\t// Check if this is a request to install KSU fd", start)
if start < 0 or end < 0:
    raise SystemExit("[SUSFS][FATAL] RKSU supercalls SUSFS dispatch block not found")
dispatch = r"""
	// v2.4.0 SUSFS commands use the new non-SU mount-hide API and
	// void __user ** ABI. Deprecated 1.x commands are intentionally
	// not mapped to removed kernel functions.
	if (magic2 == SUSFS_MAGIC && only_root()) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
		if (cmd == CMD_SUSFS_ADD_SUS_PATH) {
			susfs_add_sus_path(arg);
			return 0;
		}
		if (cmd == CMD_SUSFS_ADD_SUS_PATH_LOOP) {
			susfs_add_sus_path_loop(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
		if (cmd == CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS) {
			susfs_set_hide_sus_mnts_for_non_su_procs(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
		if (cmd == CMD_SUSFS_ADD_SUS_KSTAT ||
		    cmd == CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY) {
			susfs_add_sus_kstat(arg);
			return 0;
		}
		if (cmd == CMD_SUSFS_UPDATE_SUS_KSTAT) {
			susfs_update_sus_kstat(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
		if (cmd == CMD_SUSFS_SET_UNAME) {
			susfs_set_uname(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
		if (cmd == CMD_SUSFS_ENABLE_LOG) {
			susfs_enable_log(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
		if (cmd == CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG) {
			susfs_set_cmdline_or_bootconfig(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
		if (cmd == CMD_SUSFS_ADD_OPEN_REDIRECT) {
			susfs_add_open_redirect(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (cmd == CMD_SUSFS_ADD_SUS_MAP) {
			susfs_add_sus_map(arg);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
		if (cmd == CMD_SUSFS_SET_PRIORITY_UID_FILTER) {
			susfs_set_priority_uid_filter(arg);
			return 0;
		}
#endif
		if (cmd == CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING) {
			susfs_set_avc_log_spoofing(arg);
			return 0;
		}
		if (cmd == CMD_SUSFS_SHOW_ENABLED_FEATURES) {
			susfs_get_enabled_features(arg);
			return 0;
		}
		if (cmd == CMD_SUSFS_SHOW_VARIANT) {
			susfs_show_variant(arg);
			return 0;
		}
		if (cmd == CMD_SUSFS_SHOW_VERSION) {
			susfs_show_version(arg);
			return 0;
		}
		// Old Android-data-root, sdcard-root and try_umount commands
		// are deprecated in v2.4.0; return success as a compatibility no-op.
		return 0;
	}

"""
s = s[:start] + dispatch + s[end:]
sc.write_text(s)

# Reconcile the pinned Run #8 RKSU hooks with the v2.4.0 SUSFS ABI.
# This SUSFS backport has no mount-id reorder routine: v2.4.0 handles mount IDs
# in namespace.c itself, so remove the obsolete RKSU call rather than stub it.
# Its path-loop worker takes no uid argument in this version.
susfs = root / "fs/susfs.c"
s = susfs.read_text()
old = "static void susfs_run_sus_path_loop(void)"
new = "void susfs_run_sus_path_loop(void)"
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit("[SUSFS][FATAL] v2.4.0 sus_path_loop implementation not found")
susfs.write_text(s)

hdr = root / "include/linux/susfs.h"
s = hdr.read_text()
proto = "void susfs_run_sus_path_loop(void);\n"
if proto not in s:
    anchor = "void susfs_add_sus_path_loop(void __user **user_info);\n"
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] susfs.h SUS_PATH declaration anchor missing")
    s = s.replace(anchor, anchor + proto, 1)
hdr.write_text(s)

# The rate-limited macros are local to fs/susfs.c, not susfs_def.h.
# Define no-op forms in the disabled-logging branch so logging can remain off.
susfs = root / "fs/susfs.c"
s = susfs.read_text()
pattern = r'(#else\n#define SUSFS_LOGI\(fmt, \.\.\.\)[ \t]*\n#define SUSFS_LOGE\(fmt, \.\.\.\)[ \t]*\n)(#endif)'
m = re.search(pattern, s)
if not m:
    raise SystemExit("[SUSFS][FATAL] fs/susfs.c disabled-logging macro block missing")
else_block = m.group(1)
if "#define SUSFS_LOGI_RL(fmt, ...)" not in else_block:
    block = else_block + "#define SUSFS_LOGI_RL(fmt, ...)\n#define SUSFS_LOGE_RL(fmt, ...)\n" + m.group(2)
    s = s[:m.start()] + block + s[m.end():]
susfs.write_text(s)

hook = root / "KernelSU/kernel/setuid_hook.c"
s = hook.read_text()
s = s.replace("extern void susfs_run_sus_path_loop(uid_t uid);", "extern void susfs_run_sus_path_loop(void);")
s = s.replace("extern void susfs_reorder_mnt_id(void);\n", "")
s = s.replace("\tsusfs_reorder_mnt_id();\n", "")
s = s.replace("\tsusfs_run_sus_path_loop(new_uid);", "\tsusfs_run_sus_path_loop();")
if "susfs_reorder_mnt_id" in s or "susfs_run_sus_path_loop(new_uid)" in s:
    raise SystemExit("[SUSFS][FATAL] legacy RKSU SUSFS hook ABI remains")
if "susfs_run_sus_path_loop(void)" not in s:
    raise SystemExit("[SUSFS][FATAL] RKSU path-loop hook declaration was not adapted")
hook.write_text(s)
print("[SUSFS] RKSU setuid hooks reconciled with v2.4.0 API; obsolete mount-id reorder hook removed")

# Pin the intended feature/config ABI and ensure stale v1.x dispatcher calls
# are gone from the checked-out RKSU source.
def require(path, needle, label):
    data = pathlib.Path(path).read_text()
    if needle not in data:
        raise SystemExit(f"[SUSFS][FATAL] missing {label}: {needle}")
require(root / "include/linux/susfs_def.h", "#define SUSFS_MAGIC 0xFAFAFAFA", "v2.4 SUSFS magic")
require(susfs, "#define SUSFS_LOGI_RL", "disabled-logging rate-limited macro")
require(susfs, "void susfs_run_sus_path_loop(void)", "exported SUSFS path-loop hook")
require(hook, "susfs_run_sus_path_loop(void)", "RKSU path-loop ABI")
if "susfs_reorder_mnt_id" in hook.read_text():
    raise SystemExit("[SUSFS][FATAL] obsolete RKSU mount-id reorder hook remains")
require(sc, "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS", "v2.4 mount-hide command")
if "susfs_set_hide_sus_mnts_for_all_procs" in sc.read_text():
    raise SystemExit("[SUSFS][FATAL] legacy hide-mount API still referenced")
if "susfs_set_i_state_on_external_dir" in sc.read_text():
    raise SystemExit("[SUSFS][FATAL] removed external-dir API still referenced")
if "susfs_add_try_umount(arg)" in sc.read_text():
    raise SystemExit("[SUSFS][FATAL] deprecated try_umount API still referenced")
print("[SUSFS] v2.4.0 RKSU supercall ABI migration applied")
PY

# SUSFS v2.4 compatibility adjustment:
# Keep system/framework services (including ART/dex2oat) on the real mount view.
# The upstream non-SU filter also catches Android system UIDs; scope the filtered
# mount view to application UIDs while preserving SUS_MOUNT for app-level hiding.
python3 - "$ROOT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "fs/proc_namespace.c"
s = p.read_text()
anchor = "extern struct static_key_false susfs_is_hide_sus_mnts_for_non_su_procs_enabled;\n"
helper = """
/*
 * System services such as ART/dex2oat must retain the genuine mount view.
 * Apply SUSFS mount-list filtering only to third-party/application UIDs.
 */
static inline bool susfs_should_hide_sus_mnts_for_current(void)
{
	return static_branch_likely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled) &&
		likely(!susfs_is_current_ksu_domain()) &&
		susfs_is_current_app_uid();
}
"""
if "susfs_should_hide_sus_mnts_for_current" not in s:
    if s.count(anchor) != 1:
        raise SystemExit("[SUSFS][FATAL] proc_namespace hide-key declaration anchor mismatch")
    s = s.replace(anchor, anchor + helper, 1)
replacements = [
("""if (static_branch_likely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled)) {
		if (likely(!susfs_is_current_ksu_domain()))
			return mounts_open_common(inode, file, susfs_show_vfsmnt);
	}""",
 """if (susfs_should_hide_sus_mnts_for_current())
		return mounts_open_common(inode, file, susfs_show_vfsmnt);"""),
("""if (static_branch_likely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled)) {
		if (likely(!susfs_is_current_ksu_domain()))
			return mounts_open_common(inode, file, susfs_show_mountinfo);
	}""",
 """if (susfs_should_hide_sus_mnts_for_current())
		return mounts_open_common(inode, file, susfs_show_mountinfo);"""),
("""if (static_branch_likely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled)) {
		if (likely(!susfs_is_current_ksu_domain()))
			return mounts_open_common(inode, file, susfs_show_vfsstat);
	}""",
 """if (susfs_should_hide_sus_mnts_for_current())
		return mounts_open_common(inode, file, susfs_show_vfsstat);""")
]
for old, new in replacements:
    count = s.count(old)
    if count != 1:
        raise SystemExit("[SUSFS][FATAL] expected exactly one SUSFS mount-view hook; got %d" % count)
    s = s.replace(old, new, 1)
if s.count("susfs_should_hide_sus_mnts_for_current()") != 3:
    raise SystemExit("[SUSFS][FATAL] app-only mount-view guard verification failed")
if "if (likely(!susfs_is_current_ksu_domain()))" in s:
    raise SystemExit("[SUSFS][FATAL] unscoped non-SU mount-view filter remains")
p.write_text(s)
print("[SUSFS] mount hiding scoped to application UIDs; system/ART mount view preserved")
PY


# Re-evaluate rejects after explicitly adapting the two known Samsung context mismatches.
REJECTS="$(find "$ROOT" -type f -name '*.rej' -print | sort || true)"

# The 2.4.0 backport supplies susfs.c and the VFS hooks. The manager's
# deprecated 1.x try_umount API is disabled in this build.
grep -q 'SUSFS_VERSION "v2.4.0"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
test -s "$ROOT/fs/susfs.c"
grep -q 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' "$ROOT/fs/Makefile"

echo "[SUSFS] v2.4.0 integration source and build wiring verified"
if [[ -n "$REJECTS" ]]; then
  echo "[SUSFS][FATAL] Port still has rejected upstream hunks; inspect *.rej before kernel compilation"
  exit 1
fi

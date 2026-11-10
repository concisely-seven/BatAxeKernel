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

# Pin the intended feature/config ABI and ensure stale v1.x dispatcher calls
# are gone from the checked-out RKSU source.
def require(path, needle, label):
    data = pathlib.Path(path).read_text()
    if needle not in data:
        raise SystemExit(f"[SUSFS][FATAL] missing {label}: {needle}")
require(root / "include/linux/susfs_def.h", "#define SUSFS_MAGIC 0xFAFAFAFA", "v2.4 SUSFS magic")
require(sc, "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS", "v2.4 mount-hide command")
if "susfs_set_hide_sus_mnts_for_all_procs" in sc.read_text():
    raise SystemExit("[SUSFS][FATAL] legacy hide-mount API still referenced")
if "susfs_set_i_state_on_external_dir" in sc.read_text():
    raise SystemExit("[SUSFS][FATAL] removed external-dir API still referenced")
if "susfs_add_try_umount(arg)" in sc.read_text():
    raise SystemExit("[SUSFS][FATAL] deprecated try_umount API still referenced")
print("[SUSFS] v2.4.0 RKSU supercall ABI migration applied")
PY

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

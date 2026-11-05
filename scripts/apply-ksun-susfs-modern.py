#!/usr/bin/env python3
import pathlib
import re
import sys

ksu = pathlib.Path(sys.argv[1]).resolve()
kernel = pathlib.Path(sys.argv[2]).resolve()

def read(path):
    return path.read_text()

def write(path, value):
    path.write_text(value)

def once(path, old, new, label):
    s = read(path)
    if new in s:
        return
    if old not in s:
        raise SystemExit("anchor missing: " + label + " in " + str(path))
    write(path, s.replace(old, new, 1))

# KernelSU-Next Kconfig: keep the 33318 legacy source and add the SUSFS 1.5.12 options.
p = ksu / "kernel/Kconfig"
s = read(p)
if "config KSU_SUSFS" not in s:
    block = r'''
menu "KernelSU - SUSFS"
config KSU_SUSFS
	bool "KernelSU addon - SUSFS"
	depends on KSU
	default y

config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool "KernelSU has Magic Mount support"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_PATH
	bool "Hide suspicious paths"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MOUNT
	bool "Hide suspicious mounts"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
	bool "Automatically hide KernelSU default mounts"
	depends on KSU_SUSFS_SUS_MOUNT
	default y

config KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
	bool "Automatically hide suspicious bind mounts"
	depends on KSU_SUSFS_SUS_MOUNT
	default y

config KSU_SUSFS_SUS_KSTAT
	bool "Spoof suspicious kstat data"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_TRY_UMOUNT
	bool "Enable SUSFS try-umount support"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
	bool "Automatically add bind mounts to try-umount"
	depends on KSU_SUSFS_TRY_UMOUNT
	default y

config KSU_SUSFS_SPOOF_UNAME
	bool "Spoof uname"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_ENABLE_LOG
	bool "Enable SUSFS logging"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "Hide KernelSU and SUSFS symbols"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "Spoof proc cmdline or bootconfig"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_OPEN_REDIRECT
	bool "Redirect selected open paths"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_SU
	bool "Enable SUS-SU"
	depends on KSU_SUSFS && KPROBES && HAVE_KPROBES && KPROBE_EVENTS && KSU_KPROBES_HOOK
	default y

config KSU_SUSFS_SUS_MAP
	bool "Hide selected mapped files"
	depends on KSU_SUSFS
	default y
endmenu

'''
    idx = s.rfind("endmenu")
    if idx < 0:
        raise SystemExit("KSU Kconfig endmenu not found")
    s = s[:idx] + block + s[idx:]
    write(p, s)

# Initialize the SUSFS core exactly once during the built-in KernelSU init.
p = ksu / "kernel/core/init.c"
once(p, '#include <linux/workqueue.h>\n',
     '#include <linux/workqueue.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif\n',
     "KSUN init SUSFS include")
once(p, '\tksu_feature_init();\n',
     '\tksu_feature_init();\n#ifdef CONFIG_KSU_SUSFS\n\tsusfs_init();\n#endif\n',
     "KSUN susfs_init call")

# SUSFS core asks whether the current task is in the KSU SELinux domain.
p = ksu / "kernel/selinux/selinux.c"
if "bool susfs_is_current_ksu_domain(void)" not in read(p):
    with p.open("a") as f:
        f.write('\n#ifdef CONFIG_KSU_SUSFS\nbool susfs_is_current_ksu_domain(void)\n{\n\treturn is_ksu_domain();\n}\n\nbool susfs_is_current_zygote_domain(void)\n{\n\treturn is_zygote(current_cred());\n}\n#endif\n')

# Wire SUSFS try-umount and per-app state into the existing legacy setuid path.
p = ksu / "kernel/feature/kernel_umount.c"
s = read(p)
if "SUSFS 1.5.12 integration" not in s:
    s = s.replace('#include <linux/types.h>\n',
        '#include <linux/types.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#include <linux/susfs_def.h>\n#endif\n', 1)

    old_try = re.search(r'static void try_umount\(const char \*mnt, int flags\)\n\{.*?\n\}\n\nstruct umount_tw \{\n\tstruct callback_head cb;\n\};', s, re.S)
    if not old_try:
        raise SystemExit("KSUN kernel_umount try_umount block not found")
    new_try = r'''static void ksu_try_umount(const char *mnt, int flags)
{
	struct path path;
	int err = kern_path(mnt, 0, &path);
	if (err)
		return;
	if (path.dentry != path.mnt->mnt_root) {
		path_put(&path);
		return;
	}
	ksu_umount_mnt(mnt, &path, flags);
}

#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
extern bool susfs_is_mnt_devname_ksu(struct path *path);
void try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)
{
	struct path path;
	int err = kern_path(mnt, 0, &path);
	(void)uid;
	if (err)
		return;
	if (path.dentry != path.mnt->mnt_root) {
		path_put(&path);
		return;
	}
	if (check_mnt && !susfs_is_mnt_devname_ksu(&path)) {
		path_put(&path);
		return;
	}
	ksu_umount_mnt(mnt, &path, flags);
}
#endif

struct umount_tw {
	struct callback_head cb;
	uid_t uid;
};'''
    s = s[:old_try.start()] + new_try + s[old_try.end():]

    old_cb = re.search(r'static void umount_tw_func\(struct callback_head \*cb\)\n\{.*?\n\}\n\nint ksu_handle_umount', s, re.S)
    if not old_cb:
        raise SystemExit("KSUN umount task-work block not found")
    new_cb = r'''static void umount_tw_func(struct callback_head *cb)
{
	struct umount_tw *tw = container_of(cb, struct umount_tw, cb);
	const struct cred *saved = override_creds(ksu_cred);

#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
	susfs_try_umount(tw->uid);
#endif
	if (ksu_module_mounted && ksu_kernel_umount_enabled) {
		struct mount_entry *entry;
		down_read(&mount_list_lock);
		list_for_each_entry(entry, &mount_list, list) {
			pr_info("%s: unmounting: %s flags: 0x%x\n",
				__func__, entry->umountable, entry->flags);
			ksu_try_umount(entry->umountable, entry->flags);
		}
		up_read(&mount_list_lock);
	}
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	extern void susfs_run_sus_path_loop(uid_t uid);
	susfs_run_sus_path_loop(tw->uid);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	extern void susfs_reorder_mnt_id(void);
	susfs_reorder_mnt_id();
#endif

	revert_creds(saved);
	kfree(tw);
}

int ksu_handle_umount'''
    s = s[:old_cb.start()] + new_cb + s[old_cb.end():]

    old_early = '''	// if there isn't any module mounted, just ignore it!
	if (!ksu_module_mounted) {
		return 0;
	}

	if (!ksu_kernel_umount_enabled) {
		return 0;
	}

	if (!ksu_cred) {
		return 0;
	}
'''
    if old_early not in s:
        raise SystemExit("KSUN umount early-return block not found")
    s = s.replace(old_early, '''	// SUSFS also needs this path when no KernelSU module is mounted.
	if (!ksu_cred) {
		return 0;
	}
''', 1)

    anchor = '''	if (!is_zygote_child) {
		pr_info("handle umount ignore non zygote child: %d\\n", current->pid);
		return 0;
	}
'''
    if anchor not in s:
        raise SystemExit("KSUN zygote child check not found")
    s = s.replace(anchor, anchor + '''#ifdef CONFIG_KSU_SUSFS
	susfs_set_current_non_root_user_app_proc();
#endif
''', 1)

    anchor = '\ttw->cb.func = umount_tw_func;\n'
    if anchor not in s:
        raise SystemExit("KSUN task-work callback anchor not found")
    s = s.replace(anchor, '\ttw->uid = new_uid;\n' + anchor, 1)
    s = s.replace('static bool ksu_kernel_umount_enabled = true;\n',
        'static bool ksu_kernel_umount_enabled = true;\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nbool susfs_is_umount_for_zygote_iso_service_enabled;\n#endif\n', 1)
    s = s.replace('/* SUSFS 1.5.12 integration */', '/* SUSFS 1.5.12 integration */') if '/* SUSFS 1.5.12 integration */' in s else s.replace('#include "compat/kernel_compat.h"\n', '#include "compat/kernel_compat.h"\n\n/* SUSFS 1.5.12 integration */\n', 1)
    write(p, s)

# Keep the SUSFS prctl protocol in the kernel tree, not in the legacy KSU syscall hook.
header = kernel / "include/linux/susfs.h"
h = read(header)
proto = 'bool susfs_handle_prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5, long *result);\n'
if "susfs_handle_prctl" not in h:
    idx = h.rfind("\n#endif")
    if idx < 0:
        raise SystemExit("SUSFS header final #endif not found")
    h = h[:idx] + "\n" + proto + h[idx:]
    write(header, h)

prctl_file = kernel / "fs/susfs_prctl.c"
if not prctl_file.exists():
    prctl_file.write_text(r'''// SPDX-License-Identifier: GPL-2.0
/* SUSFS v1.5.12 userspace command bridge for KernelSU-Next legacy. */
#include <linux/cred.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/susfs.h>
#include <linux/uaccess.h>

#define KERNEL_SU_OPTION 0xDEADBEEF

extern int susfs_add_sus_path_loop(struct st_susfs_sus_path __user *user_info);
extern bool susfs_hide_sus_mnts_for_all_procs;
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_umount_for_zygote_iso_service_enabled;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_SU
extern bool susfs_is_sus_su_ready;
#endif

static bool susfs_access_ok(const void __user *addr, unsigned long size)
{
	return access_ok(VERIFY_READ, addr, size);
}

static bool susfs_access_ok_write(void __user *addr, unsigned long size)
{
	return access_ok(VERIFY_WRITE, addr, size);
}

static void susfs_copy_error(unsigned long arg5, int error)
{
	if (!arg5)
		return;
	if (susfs_access_ok_write((void __user *)arg5, sizeof(error)) &&
	    copy_to_user((void __user *)arg5, &error, sizeof(error)))
		pr_info("susfs: failed to copy command result\n");
}

bool susfs_handle_prctl(int option, unsigned long arg2, unsigned long arg3,
			unsigned long arg4, unsigned long arg5, long *result)
{
	int error = 0;
	int value = 0;

	if ((u32)option != KERNEL_SU_OPTION)
		return false;
	*result = 0;
	if (current_uid().val != 0)
		return false;

	switch (arg2) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	case CMD_SUSFS_ADD_SUS_PATH:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_sus_path)))
			error = -EFAULT;
		else
			error = susfs_add_sus_path((struct st_susfs_sus_path __user *)arg3);
		break;
	case CMD_SUSFS_ADD_SUS_PATH_LOOP:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_sus_path)))
			error = -EFAULT;
		else
			error = susfs_add_sus_path_loop((struct st_susfs_sus_path __user *)arg3);
		break;
	case CMD_SUSFS_SET_ANDROID_DATA_ROOT_PATH:
	case CMD_SUSFS_SET_SDCARD_ROOT_PATH:
		if (!susfs_access_ok((void __user *)arg3, SUSFS_MAX_LEN_PATHNAME))
			error = -EFAULT;
		else
			error = susfs_set_i_state_on_external_dir((char __user *)arg3, arg2);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	case CMD_SUSFS_ADD_SUS_MOUNT:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_sus_mount)))
			error = -EFAULT;
		else
			error = susfs_add_sus_mount((struct st_susfs_sus_mount __user *)arg3);
		break;
	case CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS:
		if (arg3 > 1)
			error = -EINVAL;
		else
			susfs_hide_sus_mnts_for_all_procs = !!arg3;
		break;
	case CMD_SUSFS_UMOUNT_FOR_ZYGOTE_ISO_SERVICE:
		if (arg3 > 1)
			error = -EINVAL;
		else
			susfs_is_umount_for_zygote_iso_service_enabled = !!arg3;
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	case CMD_SUSFS_ADD_SUS_KSTAT:
	case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_sus_kstat)))
			error = -EFAULT;
		else
			error = susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
		break;
	case CMD_SUSFS_UPDATE_SUS_KSTAT:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_sus_kstat)))
			error = -EFAULT;
		else
			error = susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
	case CMD_SUSFS_ADD_TRY_UMOUNT:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_try_umount)))
			error = -EFAULT;
		else
			error = susfs_add_try_umount((struct st_susfs_try_umount __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	case CMD_SUSFS_SET_UNAME:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_uname)))
			error = -EFAULT;
		else
			error = susfs_set_uname((struct st_susfs_uname __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	case CMD_SUSFS_ENABLE_LOG:
		if (arg3 > 1)
			error = -EINVAL;
		else
			susfs_set_log(!!arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
		if (!susfs_access_ok((void __user *)arg3, SUSFS_FAKE_CMDLINE_OR_BOOTCONFIG_SIZE))
			error = -EFAULT;
		else
			error = susfs_set_cmdline_or_bootconfig((char __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	case CMD_SUSFS_ADD_OPEN_REDIRECT:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_open_redirect)))
			error = -EFAULT;
		else
			error = susfs_add_open_redirect((struct st_susfs_open_redirect __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	case CMD_SUSFS_ADD_SUS_MAP:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_susfs_sus_map)))
			error = -EFAULT;
		else
			error = susfs_add_sus_map((struct st_susfs_sus_map __user *)arg3);
		break;
#endif
	case CMD_SUSFS_SHOW_VERSION:
		if (!susfs_access_ok_write((void __user *)arg3, sizeof(SUSFS_VERSION)) ||
		    copy_to_user((void __user *)arg3, SUSFS_VERSION, sizeof(SUSFS_VERSION)))
			error = -EFAULT;
		break;
	case CMD_SUSFS_SHOW_VARIANT:
		if (!susfs_access_ok_write((void __user *)arg3, sizeof(SUSFS_VARIANT)) ||
		    copy_to_user((void __user *)arg3, SUSFS_VARIANT, sizeof(SUSFS_VARIANT)))
			error = -EFAULT;
		break;
	case CMD_SUSFS_SHOW_ENABLED_FEATURES:
		if (!arg4 || !susfs_access_ok_write((void __user *)arg3, arg4))
			error = -EFAULT;
		else
			error = susfs_get_enabled_features((char __user *)arg3, arg4);
		break;
	case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:
		if (arg3 > 1)
			error = -EINVAL;
		else
			susfs_set_avc_log_spoofing(!!arg3);
		break;
#ifdef CONFIG_KSU_SUSFS_SUS_SU
	case CMD_SUSFS_SHOW_SUS_SU_WORKING_MODE:
		value = susfs_get_sus_su_working_mode();
		if (!susfs_access_ok_write((void __user *)arg3, sizeof(value)) ||
		    copy_to_user((void __user *)arg3, &value, sizeof(value)))
			error = -EFAULT;
		break;
	case CMD_SUSFS_IS_SUS_SU_READY:
		value = susfs_is_sus_su_ready ? 1 : 0;
		if (!susfs_access_ok((void __user *)arg3, sizeof(value)) ||
		    copy_to_user((void __user *)arg3, &value, sizeof(value)))
			error = -EFAULT;
		break;
	case CMD_SUSFS_SUS_SU:
		if (!susfs_access_ok((void __user *)arg3, sizeof(struct st_sus_su)))
			error = -EFAULT;
		else
			error = susfs_sus_su((struct st_sus_su __user *)arg3);
		break;
#else
	case CMD_SUSFS_SHOW_SUS_SU_WORKING_MODE:
	case CMD_SUSFS_IS_SUS_SU_READY:
		value = 0;
		if (!susfs_access_ok((void __user *)arg3, sizeof(value)) ||
		    copy_to_user((void __user *)arg3, &value, sizeof(value)))
			error = -EFAULT;
		break;
	case CMD_SUSFS_SUS_SU:
		error = -EOPNOTSUPP;
		break;
#endif
	default:
		error = -EINVAL;
		break;
	}

	susfs_copy_error(arg5, error);
	return true;
}
''')

# Build the command bridge and route PR_SET_NAME-compatible SUSFS prctl calls.
p = kernel / "fs/Makefile"
once(p, 'obj-$(CONFIG_KSU_SUSFS) += susfs.o\n',
     'obj-$(CONFIG_KSU_SUSFS) += susfs.o susfs_prctl.o\n',
     "SUSFS prctl object")

p = kernel / "kernel/sys.c"
s = read(p)
if '#include <linux/susfs.h>' not in s:
    anchor = '#include <linux/security.h>\n'
    if anchor not in s:
        raise SystemExit("kernel/sys.c security include anchor missing")
    s = s.replace(anchor, anchor + '#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif\n', 1)
if 'susfs_handle_prctl(option, arg2, arg3, arg4, arg5, &error)' not in s:
    anchor = '\tlong error;\n\n\terror = security_task_prctl(option, arg2, arg3, arg4, arg5);\n'
    repl = '\tlong error;\n\n#ifdef CONFIG_KSU_SUSFS\n\tif (susfs_handle_prctl(option, arg2, arg3, arg4, arg5, &error))\n\t\treturn error;\n#endif\n\n\terror = security_task_prctl(option, arg2, arg3, arg4, arg5);\n'
    if anchor not in s:
        raise SystemExit("kernel/sys.c prctl dispatch anchor missing")
    s = s.replace(anchor, repl, 1)
    write(p, s)

# Final source-level assertions; fail before compiling if any integration is absent.
checks = [
    (ksu / "kernel/Kconfig", "config KSU_SUSFS"),
    (ksu / "kernel/core/init.c", "susfs_init();"),
    (ksu / "kernel/feature/kernel_umount.c", "susfs_try_umount(tw->uid);"),
    (ksu / "kernel/selinux/selinux.c", "susfs_is_current_ksu_domain"),
    (kernel / "fs/susfs_prctl.c", "CMD_SUSFS_SHOW_VERSION"),
    (kernel / "kernel/sys.c", "susfs_handle_prctl(option, arg2, arg3, arg4, arg5, &error)"),
]
for path, marker in checks:
    if marker not in read(path):
        raise SystemExit("integration assertion failed: " + marker + " in " + str(path))

print("KernelSU-Next legacy SUSFS 1.5.12 bridge applied and source assertions passed")

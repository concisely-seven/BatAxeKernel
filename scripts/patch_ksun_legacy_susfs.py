#!/usr/bin/env python3
"""Bridge KernelSU-Next v3.x to the kernel tree's legacy SUSFS v1.5.12 prctl ABI."""
from pathlib import Path

ksu = Path("KernelSU-Next/kernel")
sc = ksu / "supercalls.c"
lsm = ksu / "lsm_hooks.c"

s = sc.read_text()
start_marker = "// If magic2 is susfs and current process is root"
end_marker = "\n\t// Check if this is a request to install KSU fd"
start = s.find(start_marker)
end = s.find(end_marker, start + len(start_marker)) if start >= 0 else -1
if start < 0 or end < 0:
    raise SystemExit("legacy-SUSFS bridge: expected v2 SUSFS reboot block not found")
if "ksu_handle_susfs_prctl" not in s:
    s = s[:start] + s[end:]
    fn = r'''
#ifdef CONFIG_KSU_SUSFS
/* Kernel tree carries SUSFS v1.5.12, whose userspace ABI is prctl(). */
extern int susfs_add_sus_path_loop(struct st_susfs_sus_path __user *user_info);

int ksu_handle_susfs_prctl(int option, unsigned long cmd,
                           unsigned long arg3, unsigned long arg4,
                           unsigned long arg5)
{
    int err = 0;

    if (option != KSU_INSTALL_MAGIC1)
        return -ENOSYS;
    if (current_uid().val != 0 && !is_manager())
        return -ENOSYS;
    if (susfs_is_current_proc_umounted())
        return -ENOSYS;

    switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
    case CMD_SUSFS_ADD_SUS_PATH:
        err = susfs_add_sus_path((struct st_susfs_sus_path __user *)arg3);
        break;
    case CMD_SUSFS_ADD_SUS_PATH_LOOP:
        err = susfs_add_sus_path_loop((struct st_susfs_sus_path __user *)arg3);
        break;
    case CMD_SUSFS_SET_ANDROID_DATA_ROOT_PATH:
    case CMD_SUSFS_SET_SDCARD_ROOT_PATH:
        err = susfs_set_i_state_on_external_dir((char __user *)arg3, cmd);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
    case CMD_SUSFS_ADD_SUS_MOUNT:
        err = susfs_add_sus_mount((struct st_susfs_sus_mount __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
    case CMD_SUSFS_ADD_SUS_KSTAT:
    case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
        err = susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
        break;
    case CMD_SUSFS_UPDATE_SUS_KSTAT:
        err = susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
    case CMD_SUSFS_ADD_TRY_UMOUNT:
        err = susfs_add_try_umount((struct st_susfs_try_umount __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
    case CMD_SUSFS_SET_UNAME:
        err = susfs_set_uname((struct st_susfs_uname __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
    case CMD_SUSFS_ENABLE_LOG:
        if (arg3 > 1)
            err = -EINVAL;
        else
            susfs_set_log(arg3 != 0);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
        err = susfs_set_cmdline_or_bootconfig((char __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
    case CMD_SUSFS_ADD_OPEN_REDIRECT:
        err = susfs_add_open_redirect((struct st_susfs_open_redirect __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
    case CMD_SUSFS_ADD_SUS_MAP:
        err = susfs_add_sus_map((struct st_susfs_sus_map __user *)arg3);
        break;
#endif
    case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:
        if (arg3 > 1)
            err = -EINVAL;
        else
            susfs_set_avc_log_spoofing(arg3 != 0);
        break;
    case CMD_SUSFS_SHOW_VERSION:
        err = copy_to_user((void __user *)arg3, SUSFS_VERSION,
                           sizeof(SUSFS_VERSION));
        break;
    case CMD_SUSFS_SHOW_VARIANT:
        err = copy_to_user((void __user *)arg3, SUSFS_VARIANT,
                           sizeof(SUSFS_VARIANT));
        break;
    case CMD_SUSFS_SHOW_ENABLED_FEATURES:
        if (!arg4)
            err = -EINVAL;
        else
            err = susfs_get_enabled_features((char __user *)arg3,
                                              (size_t)arg4);
        break;
    default:
        return -ENOSYS;
    }

    if (arg5 && copy_to_user((void __user *)arg5, &err, sizeof(err)))
        pr_warn("susfs: failed to copy prctl result for command 0x%lx\\n", cmd);

    /* Let sys_prctl() continue; the legacy ABI reports status through arg5. */
    return -ENOSYS;
}
#endif /* CONFIG_KSU_SUSFS */

'''
    marker = "int ksu_handle_sys_reboot("
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("legacy-SUSFS bridge: ksu_handle_sys_reboot insertion point missing")
    s = s[:pos] + fn + s[pos:]
    sc.write_text(s)

l = lsm.read_text()
if "ksu_task_prctl" not in l:
    include_marker = '#include "throne_tracker.h"'
    if include_marker not in l:
        raise SystemExit("legacy-SUSFS bridge: LSM include marker missing")
    l = l.replace(include_marker, include_marker + '''
#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_susfs_prctl(int option, unsigned long cmd,
                                  unsigned long arg3, unsigned long arg4,
                                  unsigned long arg5);
#endif
''', 1)
    hook_marker = "#ifndef DEVPTS_SUPER_MAGIC"
    task_fn = '''
#ifdef CONFIG_KSU_SUSFS
static int ksu_task_prctl(int option, unsigned long arg2, unsigned long arg3,
                          unsigned long arg4, unsigned long arg5)
{
    return ksu_handle_susfs_prctl(option, arg2, arg3, arg4, arg5);
}
#endif

'''
    if hook_marker not in l:
        raise SystemExit("legacy-SUSFS bridge: LSM function insertion point missing")
    l = l.replace(hook_marker, task_fn + hook_marker, 1)
    list_marker = '\tLSM_HOOK_INIT(task_fix_setuid, ksu_task_fix_setuid)\n};'
    list_replacement = '''\tLSM_HOOK_INIT(task_fix_setuid, ksu_task_fix_setuid),
#ifdef CONFIG_KSU_SUSFS
\tLSM_HOOK_INIT(task_prctl, ksu_task_prctl),
#endif
};'''
    if list_marker not in l:
        raise SystemExit("legacy-SUSFS bridge: LSM hook list marker missing")
    l = l.replace(list_marker, list_replacement, 1)
    lsm.write_text(l)

# Linux 4.14 predates selinux_state (introduced in 4.19). Do not let
# an upstream compatibility override force the newer API onto this kernel.
selinux_h = ksu / "selinux" / "selinux.h"
h = selinux_h.read_text()
state_guard = "#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)) || defined(KSU_COMPAT_HAS_SELINUX_STATE)"
legacy_guard = "#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)) || (defined(KSU_COMPAT_HAS_SELINUX_STATE) && LINUX_VERSION_CODE >= KERNEL_VERSION(4, 19, 0))"
if state_guard in h:
    h = h.replace(state_guard, legacy_guard, 1)
    selinux_h.write_text(h)
elif legacy_guard not in h:
    raise SystemExit("legacy-SUSFS bridge: SELinux state compatibility guard not found")

# Use the legacy SELinux globals exported by the 4.14 kernel headers.
selinux = ksu / "selinux" / "selinux.c"
t = selinux.read_text()
if "selinux_enforcing = enforce;" not in t:
    t = t.replace(
        '#include "selinux.h"\\n',
        '#include "selinux.h"\\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0)\\n#include "avc.h"\\n#include "security.h"\\n#endif\\n',
        1
    )
    t = t.replace(
        '    selinux_state.enforcing = enforce;',
        '#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0)\\n    selinux_enforcing = enforce;\\n#else\\n    selinux_state.enforcing = enforce;\\n#endif',
        1
    )
    t = t.replace(
        '    if (selinux_state.disabled) {\\n        return false;\\n    }',
        '#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0)\\n    if (!selinux_enabled)\\n        return false;\\n#else\\n    if (selinux_state.disabled) {\\n        return false;\\n    }\\n#endif',
        1
    )
    t = t.replace(
        '    return selinux_state.enforcing;',
        '#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0)\\n    return selinux_enforcing;\\n#else\\n    return selinux_state.enforcing;\\n#endif',
        1
    )
    selinux.write_text(t)

print("Applied KernelSU-Next <-> SUSFS v1.5.12 legacy prctl bridge")

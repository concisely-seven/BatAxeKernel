#!/usr/bin/env python3
"""Repair three known context mismatches in the SUSFS 1.5.12 Linux 4.14 backport."""
from pathlib import Path

def replace_once(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    if new in s:
        return
    if old not in s:
        raise SystemExit(f"[SUSFS][FATAL] Cannot apply Linux 4.14 compatibility repair: {label}")
    p.write_text(s.replace(old, new, 1))
    print(f"[SUSFS] Repaired {label}")

# Samsung's kernel has an extra fslog include between the upstream include
# context and the following block; insert the SUSFS header without moving vendor code.
replace_once(
    "fs/namespace.c",
    "#include <linux/sched/task.h>\n",
    "#include <linux/sched/task.h>\n#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n#include <linux/susfs_def.h>\n#endif\n",
    "fs/namespace.c SUSFS header"
)

# This vendor tree's proc/cmdline.c is a different implementation from the
# upstream file used to generate the patch, so apply the same hook semantically.
replace_once(
    "fs/proc/cmdline.c",
    "#include <asm/setup.h>\n",
    "#include <asm/setup.h>\n#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\nextern int susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);\n#endif\n",
    "proc/cmdline SUSFS declaration"
)
replace_once(
    "fs/proc/cmdline.c",
    "static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n\tseq_puts(m, new_command_line);",
    "static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {\n\t\tseq_putc(m, '\\n');\n\t\treturn 0;\n\t}\n#endif\n\tseq_puts(m, new_command_line);",
    "proc/cmdline SUSFS spoof hook"
)

# Preserve this vendor tree's rollup-aware smaps implementation while applying
# SUS_MAP output masking to the equivalent size and VmFlags sections.
replace_once(
    "fs/proc/task_mmu.c",
    """\tif (!rollup_mode)
\t\tseq_printf(m,
\t\t\t   "Size:           %8lu kB\\n"
\t\t\t   "KernelPageSize: %8lu kB\\n"
\t\t\t   "MMUPageSize:    %8lu kB\\n",
\t\t\t   (vma->vm_end - vma->vm_start) >> 10,
\t\t\t   vma_kernel_pagesize(vma) >> 10,
\t\t\t   vma_mmu_pagesize(vma) >> 10);""",
    """\tif (!rollup_mode) {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tif (vma->vm_file &&
\t\t    unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
\t\t    susfs_is_current_non_root_user_app_proc()) {
\t\t\tseq_printf(m,
\t\t\t\t   "Size:           %8lu kB\\n"
\t\t\t\t   "KernelPageSize: %8lu kB\\n"
\t\t\t\t   "MMUPageSize:    %8lu kB\\n",
\t\t\t\t   (vma->vm_end - vma->vm_start) >> 10, 4, 4);
\t\t} else
#endif
\t\t{
\t\t\tseq_printf(m,
\t\t\t\t   "Size:           %8lu kB\\n"
\t\t\t\t   "KernelPageSize: %8lu kB\\n"
\t\t\t\t   "MMUPageSize:    %8lu kB\\n",
\t\t\t\t   (vma->vm_end - vma->vm_start) >> 10,
\t\t\t\t   vma_kernel_pagesize(vma) >> 10,
\t\t\t\t   vma_mmu_pagesize(vma) >> 10);
\t\t}
\t}""",
    "task_mmu SUS_MAP smaps size masking"
)
replace_once(
    "fs/proc/task_mmu.c",
    """\tif (!rollup_mode) {
\t\tarch_show_smap(m, vma);
\t\tshow_smap_vma_flags(m, vma);
\t}""",
    """\tif (!rollup_mode) {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tif (vma->vm_file &&
\t\t    unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
\t\t    susfs_is_current_non_root_user_app_proc()) {
\t\t\tseq_puts(m, "VmFlags: mr mw me");
\t\t\tseq_putc(m, '\\n');
\t\t} else
#endif
\t\t{
\t\t\tarch_show_smap(m, vma);
\t\t\tshow_smap_vma_flags(m, vma);
\t\t}
\t}""",
    "task_mmu SUS_MAP VmFlags masking"
)

# The three rejected hunks above are intentionally repaired semantically.
# Any other reject indicates an unexpected patch drift and must stop the build.
rejects = list(Path(".").rglob("*.rej"))
allowed = {"fs/namespace.c.rej", "fs/proc/cmdline.c.rej", "fs/proc/task_mmu.c.rej"}
unexpected = [str(p) for p in rejects if str(p) not in allowed]
if unexpected:
    raise SystemExit("[SUSFS][FATAL] Unexpected patch rejects: " + ", ".join(unexpected))
for p in rejects:
    p.unlink()
print("[SUSFS] Linux 4.14 backport compatibility checks passed")

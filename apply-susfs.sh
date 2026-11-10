#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$ROOT/KernelSU"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# This is the exact RSNTK/RKSU submodule revision used by Run #8.
EXPECTED_KSU_COMMIT="9b28326af4145974560122644e87fc9a021a2cce"
SUSFS_SOURCE_BASE="https://raw.githubusercontent.com/F640/begonia-ckernel-mod/fe1fe1491b2f71ee62be64eb9525c92f63fde938/patches/susfs-backport/thesillyok-susfs-1.5.12"
KERNEL_PATCH_URL="$SUSFS_SOURCE_BASE/thesillyok-susfs-1.5.12-mod.patch"

test -d "$ROOT/fs"
test -f "$KSU_DIR/kernel/Kconfig"
ACTUAL_KSU_COMMIT="$(git -C "$KSU_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_KSU_COMMIT" != "$EXPECTED_KSU_COMMIT" ]]; then
  echo "[SUSFS][FATAL] KernelSU submodule changed: expected $EXPECTED_KSU_COMMIT, got $ACTUAL_KSU_COMMIT"
  exit 1
fi
echo "[KSU] Pinned known-good submodule: $ACTUAL_KSU_COMMIT"

curl -fL --retry 3 "$KERNEL_PATCH_URL" -o "$TMP_DIR/susfs-kernel-1.5.12.patch"

# Apply the Linux 4.14 SUSFS backport only once.
if grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h" 2>/dev/null; then
  echo "[SUSFS] Kernel layer already has v1.5.12"
else
  if [[ -e "$ROOT/fs/susfs.c" || -e "$ROOT/include/linux/susfs.h" ]]; then
    echo "[SUSFS][FATAL] Existing SUSFS files found but version is not v1.5.12"
    exit 1
  fi
  # The upstream 4.14 backport has three context mismatches against the
  # Samsung Exynos 9825 Run #8 tree. Apply every matching hunk, then adapt
  # those three known sites explicitly below. Any other reject is fatal.
  if patch --batch --forward -p1 -F3 -d "$ROOT" < "$TMP_DIR/susfs-kernel-1.5.12.patch"; then
    echo "[SUSFS] Upstream kernel patch applied without rejects"
  else
    patch_status=$?
    [[ "$patch_status" -eq 1 ]] || {
      echo "[SUSFS][FATAL] patch command failed with status $patch_status"
      exit "$patch_status"
    }
    for reject in "$ROOT/fs/namespace.c.rej" "$ROOT/fs/proc/cmdline.c.rej" "$ROOT/fs/proc/task_mmu.c.rej"; do
      test -s "$reject" || {
        echo "[SUSFS][FATAL] Unexpected patch failure; missing expected reject: $reject"
        exit 1
      }
    done
    reject_count="$(find "$ROOT" -name '*.rej' -type f | wc -l)"
    [[ "$reject_count" -eq 3 ]] || {
      echo "[SUSFS][FATAL] Expected exactly 3 known rejects, found $reject_count"
      find "$ROOT" -name '*.rej' -type f -print
      exit 1
    }
    python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])

def replace_once(path, old, new, label):
    p = root / path
    s = p.read_text()
    if new in s:
        print(f"[SUSFS] {label}: already adapted")
        return
    if old not in s:
        raise SystemExit(f"[SUSFS][FATAL] {label}: expected source context not found")
    p.write_text(s.replace(old, new, 1))
    print(f"[SUSFS] {label}: adapted for Run #8 Samsung source")

# namespace.c: Samsung adds fslog.h/slub_def.h after sched/task.h.
p = root / "fs/namespace.c"
s = p.read_text()
if "include <linux/susfs_def.h>" not in s:
    anchor = "#include <linux/sched/task.h>\n"
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] namespace.c include anchor missing")
    inc = "#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n#include <linux/susfs_def.h>\n#endif\n"
    p.write_text(s.replace(anchor, anchor + inc, 1))

# cmdline.c: this Samsung tree exposes new_command_line, not saved_command_line.
p = root / "fs/proc/cmdline.c"
s = p.read_text()
if "extern int susfs_spoof_cmdline_or_bootconfig" not in s:
    anchor = "#include <asm/setup.h>\n"
    if anchor not in s:
        raise SystemExit("[SUSFS][FATAL] cmdline.c include anchor missing")
    decl = "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\nextern int susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);\n#endif\n"
    s = s.replace(anchor, anchor + decl, 1)
old = """static int cmdline_proc_show(struct seq_file *m, void *v)
{
\tseq_puts(m, new_command_line);"""
new = r"""static int cmdline_proc_show(struct seq_file *m, void *v)
{
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {
\t\tseq_putc(m, '\n');
\t\treturn 0;
\t}
#endif
\tseq_puts(m, new_command_line);"""
new = new.replace(r"\t", "\t")
if old in s:
    s = s.replace(old, new, 1)
elif "susfs_spoof_cmdline_or_bootconfig(m)" not in s:
    raise SystemExit("[SUSFS][FATAL] cmdline.c show function anchor missing")
p.write_text(s)

# task_mmu.c: adapt the missing show_smap() hunk to this tree's inline formatter.
p = root / "fs/proc/task_mmu.c"
s = p.read_text()
if "susfs_run8_smap_compat" not in s:
    # The upstream hunk immediately before the failed hunk adds the SUS_MAP
    # Size override and jumps to this label. Restore the missing label only.
    smaps_start = s.find("static int show_smap(")
    smaps_end = s.find("static int show_pid_smap", smaps_start)
    if smaps_start < 0 or smaps_end < 0:
        raise SystemExit("[SUSFS][FATAL] task_mmu.c show_smap() boundaries missing")
    smaps = s[smaps_start:smaps_end]
    if "goto bypass_orig_flow;" in smaps and "bypass_orig_flow:" not in smaps:
        anchor = """\t\t   vma_mmu_pagesize(vma) >> 10);"""
        if anchor not in smaps:
            raise SystemExit("[SUSFS][FATAL] task_mmu.c Size output tail missing")
        smaps = smaps.replace(anchor, anchor + "\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif", 1)
        s = s[:smaps_start] + smaps + s[smaps_end:]
    elif "goto bypass_orig_flow;" not in smaps:
        raise SystemExit("[SUSFS][FATAL] expected SUS_MAP Size override hunk was not applied")

    # This source tree keeps show_smap() inline and has no __show_smap().
    old = """\tif (!rollup_mode) {
\t\tarch_show_smap(m, vma);
\t\tshow_smap_vma_flags(m, vma);
\t}"""
    new = r"""\tif (!rollup_mode) {
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tif (vma->vm_file &&
\t\t    unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
\t\t    susfs_is_current_non_root_user_app_proc()) {
\t\t\tseq_puts(m, "VmFlags: mr mw me\n");
\t\t} else {
#endif
\t\t\tarch_show_smap(m, vma);
\t\t\tshow_smap_vma_flags(m, vma);
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\t}
#endif
\t}"""
    new = new.replace(r"\t", "\t")
    if old in s:
        s = s.replace(old, new, 1)
    elif "VmFlags: mr mw me" not in s:
        raise SystemExit("[SUSFS][FATAL] task_mmu.c smaps flags anchor missing")
    s = s.replace("/* susfs_run8_smap_compat:", "/* susfs_run8_smap_compat:", 1)
    p.write_text(s)
else:
    print("[SUSFS] task_mmu smaps compatibility already applied")
PY
    rm -f "$ROOT/fs/namespace.c.rej" "$ROOT/fs/proc/cmdline.c.rej" "$ROOT/fs/proc/task_mmu.c.rej"
  fi
fi

# The Linux 4.14 backport patch wires SUSFS into VFS but intentionally
# keeps the three SUSFS implementation/header files as separate source files.
# Fetch them from the same immutable upstream revision before Kconfig checks.
mkdir -p "$ROOT/include/linux"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs.h" -o "$ROOT/include/linux/susfs.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/include/linux/susfs_def.h" -o "$ROOT/include/linux/susfs_def.h"
curl -fL --retry 3 "$SUSFS_SOURCE_BASE/fs/susfs.c" -o "$ROOT/fs/susfs.c"

# The pinned rsuntk/susfs-rksu-master commit already contains native
# KernelSU-SUSFS integration. Do not apply the newer RKSU patch over it:
grep -q '^config KSU_SUSFS
grep -q 'SUSFS_VERSION "v1.5.12"' "$ROOT/include/linux/susfs.h"
grep -q '^config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig"
test -s "$ROOT/fs/susfs.c"
for symbol in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_MAP; do
  grep -q "^config ${symbol}$" "$KSU_DIR/kernel/Kconfig" || {
    echo "[SUSFS][FATAL] Missing KernelSU config symbol: ${symbol}"
    exit 1
  }
done

 "$KSU_DIR/kernel/Kconfig"
grep -q 'KernelSU-SusFS version' "$KSU_DIR/kernel/Makefile"
echo "[SUSFS] Native RKSU-SUSFS integration verified at $ACTUAL_KSU_COMMIT"

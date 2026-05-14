#!/usr/bin/env python3
import sys
import os

KERNEL_DIR = sys.argv[1] if len(sys.argv) > 1 else "private/msm-google"

def patch_file(filepath, search, replace):
    if not os.path.exists(filepath):
        print(f"  WARNING: {filepath} not found, skipping")
        return False
    with open(filepath, 'r') as f:
        content = f.read()
    if replace in content:
        print(f"  Already patched, skipping.")
        return True
    if search not in content:
        print(f"  WARNING: search pattern not found in {filepath}")
        return False
    content = content.replace(search, replace, 1)
    with open(filepath, 'w') as f:
        f.write(content)
    print(f"  Patched successfully.")
    return True

def insert_before(filepath, search, addition):
    if not os.path.exists(filepath):
        print(f"  WARNING: {filepath} not found, skipping")
        return False
    with open(filepath, 'r') as f:
        content = f.read()
    if addition.strip() in content:
        print(f"  Already patched, skipping.")
        return True
    if search not in content:
        print(f"  WARNING: search pattern not found in {filepath}")
        return False
    idx = content.index(search)
    content = content[:idx] + addition + "\n" + content[idx:]
    with open(filepath, 'w') as f:
        f.write(content)
    print(f"  Patched successfully.")
    return True

# 1. Add CONFIG_KSU to defconfig
print("[*] Adding CONFIG_KSU to defconfig...")
defconfig = os.path.join(KERNEL_DIR, "arch/arm64/configs/floral_defconfig")
if os.path.exists(defconfig):
    with open(defconfig, 'r') as f:
        content = f.read()
    if "CONFIG_KSU" not in content:
        with open(defconfig, 'a') as f:
            f.write("\nCONFIG_KSU=y\n")
        print("  Added CONFIG_KSU=y")
    else:
        print("  Already present.")
else:
    print(f"  WARNING: {defconfig} not found")

# 2. Patch fs/exec.c - do_execveat_common
print("[*] Patching fs/exec.c ...")
exec_c = os.path.join(KERNEL_DIR, "fs/exec.c")
insert_before(exec_c,
    "static int do_execveat_common(int fd, struct filename *filename,\n\t\t\t      struct user_arg_ptr argv,\n\t\t\t      struct user_arg_ptr envp,\n\t\t\t      int flags)\n{",
    "#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t void *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n\t\t\t\t void *argv, void *envp, int *flags);\n#endif")

patch_file(exec_c,
    "\tcurrent->flags &= ~PF_NPROC_EXCEEDED;\n\n\tretval = unshare_files(&displaced);",
    "\tcurrent->flags &= ~PF_NPROC_EXCEEDED;\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_execveat_hook))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n\telse\n\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n#endif\n\n\tretval = unshare_files(&displaced);")

# 3. Patch fs/open.c - SYSCALL_DEFINE3(faccessat)
print("[*] Patching fs/open.c ...")
open_c = os.path.join(KERNEL_DIR, "fs/open.c")
insert_before(open_c,
    "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{",
    "#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\tint *flags);\n#endif")

patch_file(open_c,
    "\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */",
    "\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */")

# 4. Patch fs/read_write.c - vfs_read
print("[*] Patching fs/read_write.c ...")
rw_c = os.path.join(KERNEL_DIR, "fs/read_write.c")
insert_before(rw_c,
    "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n{",
    "#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n\t\t\t size_t *count_ptr, loff_t **pos);\n#endif")

patch_file(rw_c,
    "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n{\n\tssize_t ret;\n\n\tif (!(file->f_mode & FMODE_READ))",
    "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n{\n\tssize_t ret;\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);\n#endif\n\n\tif (!(file->f_mode & FMODE_READ))")

# 5. Patch fs/stat.c - vfs_statx
print("[*] Patching fs/stat.c ...")
stat_c = os.path.join(KERNEL_DIR, "fs/stat.c")
insert_before(stat_c,
    "int vfs_statx(int dfd, const char __user *filename, int flags,\n\t      struct kstat *stat, u32 request_mask)\n{",
    "#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif")

patch_file(stat_c,
    "\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |",
    "\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |")

# 6. Patch drivers/input/input.c - input_handle_event (Safe Mode)
print("[*] Patching drivers/input/input.c ...")
input_c = os.path.join(KERNEL_DIR, "drivers/input/input.c")
insert_before(input_c,
    "static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{",
    "#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif")

patch_file(input_c,
    "\tint disposition = input_get_disposition(dev, type, code, &value);\n\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)",
    "\tint disposition = input_get_disposition(dev, type, code, &value);\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)")

# 7. Patch fs/devpts/inode.c - devpts_get_priv
print("[*] Patching fs/devpts/inode.c ...")
devpts_c = os.path.join(KERNEL_DIR, "fs/devpts/inode.c")
insert_before(devpts_c,
    "void *devpts_get_priv(struct dentry *dentry)\n{",
    "#ifdef CONFIG_KSU\nextern int ksu_handle_devpts(struct inode*);\n#endif")

patch_file(devpts_c,
    "void *devpts_get_priv(struct dentry *dentry)\n{\n\tif (dentry->d_sb->s_magic != DEVPTS_SUPER_MAGIC)",
    "void *devpts_get_priv(struct dentry *dentry)\n{\n#ifdef CONFIG_KSU\n\tksu_handle_devpts(dentry->d_inode);\n#endif\n\tif (dentry->d_sb->s_magic != DEVPTS_SUPER_MAGIC)")

print("[*] All patches applied!")

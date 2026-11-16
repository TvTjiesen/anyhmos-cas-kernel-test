#!/usr/bin/env python3
"""Inject CASDBG diagnostics into fs/block_dev.c:lookup_bdev().

Run from the kernel tree root (the dir that contains fs/) BEFORE building.
Idempotent: refuses to double-apply. This is the decisive probe for the H6
mount-ENOENT mystery: it prints the exact failure branch inside lookup_bdev().

Expected output on the device (ramoops / kmsg):
    CASDBG lookup_bdev('/dev/sda29')
    CASDBG lookup_bdev('/dev/sda29') kern_path=-2      <- kern_path failed
  or
    CASDBG lookup_bdev('/dev/sda29') path ok dentry=... inode=...
    ... followed by ENOTBLK / EACCES / ENOMEM branch markers
"""
import pathlib
import sys

OLD = """struct block_device *lookup_bdev(const char *pathname)
{
\tstruct block_device *bdev;
\tstruct inode *inode;
\tstruct path path;
\tint error;

\tif (!pathname || !*pathname)
\t\treturn ERR_PTR(-EINVAL);

\terror = kern_path(pathname, LOOKUP_FOLLOW, &path);
\tif (error)
\t\treturn ERR_PTR(error);
"""

NEW = """struct block_device *lookup_bdev(const char *pathname)
{
\tstruct block_device *bdev;
\tstruct inode *inode;
\tstruct path path;
\tint error;

\tif (!pathname || !*pathname) {
\t\tpr_err("CASDBG lookup_bdev: NULL/empty pathname\\n");
\t\treturn ERR_PTR(-EINVAL);
\t}

\tpr_err("CASDBG lookup_bdev('%s')\\n", pathname);
\terror = kern_path(pathname, LOOKUP_FOLLOW, &path);
\tif (error) {
\t\tpr_err("CASDBG lookup_bdev('%s') kern_path=%d\\n", pathname, error);
\t\treturn ERR_PTR(error);
\t}
\tpr_err("CASDBG lookup_bdev('%s') path ok dentry=%p inode=%p\\n",
\t       pathname, path.dentry, d_backing_inode(path.dentry));
"""

MARK_INODE = """\tinode = d_backing_inode(path.dentry);
\terror = -ENOTBLK;
\tif (!S_ISBLK(inode->i_mode))
\t\tgoto fail;
\terror = -EACCES;
\tif (!may_open_dev(&path))
\t\tgoto fail;
\terror = -ENOMEM;
\tbdev = bd_acquire(inode);
\tif (!bdev)
\t\tgoto fail;
"""

MARK_NEW = """\tinode = d_backing_inode(path.dentry);
\tpr_err("CASDBG lookup_bdev('%s') inode=%p mode=0%o\\n",
\t       pathname, inode, inode ? inode->i_mode : 0);
\terror = -ENOTBLK;
\tif (!S_ISBLK(inode->i_mode)) {
\t\tpr_err("CASDBG lookup_bdev('%s') NOTBLK\\n", pathname);
\t\tgoto fail;
\t}
\terror = -EACCES;
\tif (!may_open_dev(&path)) {
\t\tpr_err("CASDBG lookup_bdev('%s') EACCES may_open_dev\\n", pathname);
\t\tgoto fail;
\t}
\terror = -ENOMEM;
\tbdev = bd_acquire(inode);
\tif (!bdev) {
\t\tpr_err("CASDBG lookup_bdev('%s') ENOMEM bd_acquire\\n", pathname);
\t\tgoto fail;
\t}
\tpr_err("CASDBG lookup_bdev('%s') OK bdev=%p\\n", pathname, bdev);
"""


def main():
    p = pathlib.Path("fs/block_dev.c")
    if not p.exists():
        sys.exit("run from the kernel tree root (fs/block_dev.c not found)")
    s = p.read_text(encoding="utf-8", errors="surrogateescape")
    if "CASDBG lookup_bdev" in s:
        print("already patched; nothing to do")
        return
    if OLD not in s:
        sys.exit("lookup_bdev head pattern not found -- source differs, inspect manually")
    s = s.replace(OLD, NEW, 1)
    if MARK_INODE not in s:
        sys.exit("lookup_bdev body pattern not found -- head patched in memory only")
    s = s.replace(MARK_INODE, MARK_NEW, 1)
    p.write_text(s, encoding="utf-8", errors="surrogateescape")
    print("CASDBG injected: 2 sites (head + body) in fs/block_dev.c")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Inject CASDBG diagnostics into do_mount() and do_new_mount() (fs/namespace.c).

Round-044 proved lookup_bdev() is NEVER reached for preinit's mount(): the only
CASDBG lines came from block2mtd at 1.66 s. So mount() dies before mount_bdev().
do_mount() pre-steps: user_path() -> security_sb_mount() -> may_mount().
do_new_mount() pre-steps: get_fs_type() -> fs_context_for_mount() ->
vfs_parse_fs_string("source") -> vfs_get_tree(). Print each one.

Run from the kernel tree root (dir containing fs/), before building. Idempotent.
"""
import pathlib
import sys

PAIRS = [
    # 1) do_mount entry
    ("do_mount: entry",
     "\tint retval = 0;\n\n\t/* Discard magic */\n",
     "\tint retval = 0;\n\n"
     "\tpr_err(\"CASDBG do_mount: dev='%s' type='%s' flags=0x%lx\\n\",\n"
     "\t       dev_name ? dev_name : \"(null)\",\n"
     "\t       type_page ? type_page : \"(null)\", flags);\n\n"
     "\t/* Discard magic */\n"),

    # 2) user_path result
    ("do_mount: user_path",
     "\tretval = user_path(dir_name, &path);\n\tif (retval)\n\t\treturn retval;\n",
     "\tretval = user_path(dir_name, &path);\n"
     "\tpr_err(\"CASDBG do_mount: user_path=%d\\n\", retval);\n"
     "\tif (retval)\n\t\treturn retval;\n"),

    # 3) security_sb_mount result
    ("do_mount: security_sb_mount",
     "\tretval = security_sb_mount(dev_name, &path,\n"
     "\t\t\t\t   type_page, flags, data_page);\n"
     "\tif (!retval && !may_mount())\n",
     "\tretval = security_sb_mount(dev_name, &path,\n"
     "\t\t\t\t   type_page, flags, data_page);\n"
     "\tpr_err(\"CASDBG do_mount: security=%d\\n\", retval);\n"
     "\tif (!retval && !may_mount())\n"),

    # 4) final result before returning
    ("do_mount: result",
     "dput_out:\n\tpath_put(&path);\n\treturn retval;\n}\n",
     "dput_out:\n"
     "\tpr_err(\"CASDBG do_mount: result=%d\\n\", retval);\n"
     "\tpath_put(&path);\n\treturn retval;\n}\n"),

    # 5) do_new_mount entry + get_fs_type
    ("do_new_mount: entry",
     "\tint err = 0;\n\n\tif (!fstype)\n\t\treturn -EINVAL;\n\n"
     "\ttype = get_fs_type(fstype);\n\tif (!type)\n\t\treturn -ENODEV;\n",
     "\tint err = 0;\n\n"
     "\tpr_err(\"CASDBG new_mount: enter fstype='%s' name='%s' sb_flags=0x%x\\n\",\n"
     "\t       fstype ? fstype : \"(null)\", name ? name : \"(null)\", sb_flags);\n\n"
     "\tif (!fstype)\n\t\treturn -EINVAL;\n\n"
     "\ttype = get_fs_type(fstype);\n"
     "\tpr_err(\"CASDBG new_mount: get_fs_type=%p\\n\", type);\n"
     "\tif (!type)\n\t\treturn -ENODEV;\n"),

    # 6) vfs_get_tree result + effective fc->source
    ("do_new_mount: source parse result",
     "\tif (!err && name)\n"
     "\t\terr = vfs_parse_fs_string(fc, \"source\", name, strlen(name));\n"
     "\tif (!err)\n\t\terr = parse_monolithic_mount_data(fc, data);\n",
     "\tif (!err && name)\n"
     "\t\terr = vfs_parse_fs_string(fc, \"source\", name, strlen(name));\n"
     "\tpr_err(\"CASDBG new_mount: post_source err=%d source='%s' name='%s'\\n\",\n"
     "\t       err, fc->source ? fc->source : \"(null)\", name ? name : \"(null)\");\n"
     "\tif (!err)\n\t\terr = parse_monolithic_mount_data(fc, data);\n"),

    ("do_new_mount: vfs_get_tree",
     "\tif (!err)\n\t\terr = parse_monolithic_mount_data(fc, data);\n"
     "\tif (!err)\n\t\terr = vfs_get_tree(fc);\n"
     "\tif (!err)\n\t\terr = do_new_mount_fc(fc, path, mnt_flags);\n",
     "\tif (!err)\n\t\terr = parse_monolithic_mount_data(fc, data);\n"
     "\tpr_err(\"CASDBG new_mount: pre_tree err=%d source='%s'\\n\",\n"
     "\t       err, fc->source ? fc->source : \"(null)\");\n"
     "\tif (!err)\n\t\terr = vfs_get_tree(fc);\n"
     "\tpr_err(\"CASDBG new_mount: vfs_get_tree=%d\\n\", err);\n"
     "\tif (!err)\n\t\terr = do_new_mount_fc(fc, path, mnt_flags);\n"),
]


def main():
    p = pathlib.Path("fs/namespace.c")
    if not p.exists():
        sys.exit("run from the kernel tree root (fs/namespace.c not found)")
    s = p.read_text(encoding="utf-8", errors="surrogateescape")
    if "CASDBG do_mount" in s:
        print("already patched; nothing to do")
        return
    applied = 0
    for name, old, new in PAIRS:
        if old not in s:
            print("MISS   %s" % name)
            continue
        s = s.replace(old, new, 1)
        applied += 1
        print("OK     %s" % name)
    if applied != len(PAIRS):
        sys.exit("only %d/%d sites matched -- source drift, aborting" % (applied, len(PAIRS)))
    p.write_text(s, encoding="utf-8", errors="surrogateescape")
    print("CASDBG injected: %d sites in fs/namespace.c" % applied)


if __name__ == "__main__":
    main()

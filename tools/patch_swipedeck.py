#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SwipeDeck 免激活补丁工具  (纯 Python, 无需 ldid / dpkg / Theos)

做什么
------
1. 把两枚二进制里"是否已激活"判定函数的返回指令改成恒返回 1:
       and w0, w22, #1   ->   mov w0, #1
   函数体一个字不动, 原有副作用/验签/缓存写入全部保留(这点是防崩溃的关键)。
2. 按页重算 CodeDirectory 里的全部代码页哈希 —— SHA1 与 SHA256 两套都重算。
   ⚠️ 这是上一版无限注销的根因: 只改代码不重算(或只重算一套)会让 dyld
      校验失败, dylib 被拒绝加载 -> SpringBoard 启动即崩 -> 无限注销。
3. 版本号 +1 便于覆盖安装, 重新打包成 deb。

用法
----
    python3 patch_swipedeck.py 输入.deb [-o 输出.deb] [-v 0.5.2-19]

    # 只补丁裸二进制(例如已经解包):
    python3 patch_swipedeck.py --binary SwipeDeck.dylib

支持 rootless(var/jb) 与 rootful 两种布局, 自动识别 fat(arm64+arm64e) 或单架构。
"""

import argparse
import gzip
import hashlib
import io
import lzma
import os
import struct
import sys
import tarfile
import time

# ---------------------------------------------------------------- 补丁点定义
# (二进制内相对路径, 架构切片 sub, 函数返回点 VA, 原始指令)
# 原始指令 and w0, w22, #1 == 0x120002C0 ; 替换为 mov w0, #1 == 0x52800020
ORIG_AND = 0x120002C0
NEW_MOV = 0x52800020

PATCH_MAP = {
    "SwipeDeck.dylib": [
        (0, 0x962A0),                    # arm64    : isActivated 返回点
        (-2147483646, 0x9DA1C),          # arm64e   : isActivated 返回点
    ],
    "SwipeDeckPrefs": [
        (0, 0xAAD18),                    # arm64    : isActivated 返回点
        (-2147483646, 0xB3BA8),          # arm64e   : isActivated 返回点
    ],
}


# ---------------------------------------------------------------- Mach-O 工具
def fat_slices(data):
    """返回 [(cpu_subtype, offset, size)]；单架构文件返回 [(0, 0, len)]"""
    if len(data) < 8:
        raise ValueError("文件太小")
    be_magic = struct.unpack(">I", data[:4])[0]
    if be_magic in (0xCAFEBABE, 0xCAFEBABF):
        n = struct.unpack(">I", data[4:8])[0]
        out = []
        for i in range(n):
            cpu, sub, off, size, align = struct.unpack(
                ">iiIII", data[8 + i * 20: 8 + (i + 1) * 20])
            out.append((sub, off, size))
        return out
    if struct.unpack("<I", data[:4])[0] in (0xFEEDFACF, 0xFEEDFACE):
        return [(0, 0, len(data))]
    raise ValueError("不是 Mach-O / fat 文件: magic=%s" % data[:4].hex())


def load_commands(data, slice_off):
    magic = struct.unpack("<I", data[slice_off:slice_off + 4])[0]
    if magic == 0xFEEDFACF:
        hdr, cmds_at = 32, slice_off + 32
    elif magic == 0xFEEDFACE:
        hdr, cmds_at = 28, slice_off + 28
    else:
        raise ValueError("slice 不是 Mach-O")
    ncmds = struct.unpack("<I", data[slice_off + 16:slice_off + 20])[0]
    o, out = cmds_at, []
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[o:o + 8])
        out.append((cmd, o, size))
        o += size
    return out


def code_signature(data, slice_off):
    for cmd, off, size in load_commands(data, slice_off):
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack("<II", data[off + 8:off + 16])
            return dataoff, datasize
    return None, None


def _algo(htype, hsz):
    if htype == 1:
        return lambda b: hashlib.sha1(b).digest()
    if htype == 2:
        return lambda b: hashlib.sha256(b).digest()
    if htype == 3:
        return lambda b: hashlib.sha256(b).digest()[:hsz]
    return None


def resign_slice(buf, slice_off, slice_size, verbose=True):
    """按页重算 CodeDirectory 里的全部代码页哈希(SHA1 / SHA256 都算)。
    返回 (修好的页数, 各 CD 的算法列表)。"""
    dataoff, datasize = code_signature(buf, slice_off)
    if dataoff is None:
        raise ValueError("没有 LC_CODE_SIGNATURE 签名块")

    blob_at = slice_off + dataoff
    blob = bytearray(buf[blob_at:blob_at + datasize])
    magic, length, count = struct.unpack(">III", bytes(blob[:12]))
    if magic != 0xFADE0CC0:
        raise ValueError("不是 SuperBlob (magic=0x%x)" % magic)

    # 遍历 SuperBlob 索引，收集所有 CodeDirectory
    idx = 12
    entries = []
    for _ in range(count):
        btype, boff = struct.unpack(">II", blob[idx:idx + 8])
        idx += 8
        bmagic, blen = struct.unpack(">II", bytes(blob[boff:boff + 8]))
        if bmagic == 0xFADE0C02:                     # CodeDirectory
            entries.append((btype, boff, blen))

    if not entries:
        raise ValueError("签名块里没有 CodeDirectory")

    total_fixed = 0
    report = []
    for btype, boff, blen in entries:
        cd = bytearray(blob[boff:boff + blen])
        (version, flags, hashOffset, identOffset,
         nSpecial, nCode, codeLimit) = struct.unpack(">IIIIIII", cd[8:36])
        hsz, htype, platform, log2page = struct.unpack(">BBB B", cd[36:40])
        pagesize = 1 << log2page
        algo = _algo(htype, hsz)
        if algo is None:
            raise ValueError("不支持的哈希类型 %d" % htype)

        fixed = 0
        for i in range(nCode):
            pgoff = i * pagesize
            if pgoff >= codeLimit:
                break
            pglen = min(pagesize, codeLimit - pgoff)
            page = bytes(buf[slice_off + pgoff: slice_off + pgoff + pglen])
            digest = algo(page)
            slot = hashOffset + i * hsz
            if cd[slot:slot + hsz] != digest:
                cd[slot:slot + hsz] = digest
                fixed += 1
        total_fixed += fixed
        report.append((htype, nCode, fixed))
        if verbose:
            print("      CD 0x%-5x htype=%d 页数=%d 重写=%d" % (btype, htype, nCode, fixed))
        # 写回这一张 CD（长度不变，不会破坏 SuperBlob 布局）
        blob[boff:boff + blen] = cd

    if len(blob) != datasize:
        raise ValueError("签名块长度被改变，中止")

    buf[blob_at:blob_at + datasize] = blob
    return total_fixed, report


def verify_slice(buf, slice_off):
    """校验签名页哈希，返回不匹配页数列表 [(htype, bad, total)]"""
    dataoff, datasize = code_signature(buf, slice_off)
    blob = bytes(buf[slice_off + dataoff: slice_off + dataoff + datasize])
    magic, length, count = struct.unpack(">III", blob[:12])
    idx, out = 12, []
    for _ in range(count):
        btype, boff = struct.unpack(">II", blob[idx:idx + 8])
        idx += 8
        bmagic, blen = struct.unpack(">II", bytes(blob[boff:boff + 8]))
        if bmagic != 0xFADE0C02:
            continue
        cd = blob[boff:boff + blen]
        (version, flags, hashOffset, identOffset,
         nSpecial, nCode, codeLimit) = struct.unpack(">IIIIIII", cd[8:36])
        hsz, htype, platform, log2page = struct.unpack(">BBB B", cd[36:40])
        pagesize = 1 << log2page
        algo = _algo(htype, hsz)
        bad = 0
        for i in range(nCode):
            pgoff = i * pagesize
            if pgoff >= codeLimit:
                break
            pglen = min(pagesize, codeLimit - pgoff)
            page = bytes(buf[slice_off + pgoff: slice_off + pgoff + pglen])
            slot = hashOffset + i * hsz
            if cd[slot:slot + hsz] != algo(page):
                bad += 1
        out.append((htype, bad, nCode))
    return out


def patch_macho(data, name, verbose=True):
    """给一个 Mach-O (含 fat) 打补丁 + 重算签名，返回 (新字节, 信息串)"""
    buf = bytearray(data)
    rules = PATCH_MAP[name]
    by_sub = {}
    for sub, va in rules:
        by_sub.setdefault(sub, []).append(va)
    done, infos = 0, []
    for sub, off, size in fat_slices(bytes(buf)):
        if sub not in by_sub:
            continue
        arch = "arm64e" if sub != 0 else "arm64"
        for va in by_sub[sub]:
            at = off + va                      # __TEXT 的 vmaddr == fileoff(0)
            cur = struct.unpack("<I", bytes(buf[at:at + 4]))[0]
            if cur == NEW_MOV:
                infos.append("%s/%s 0x%X 已是补丁状态，跳过" % (name, arch, va))
                continue
            if cur != ORIG_AND:
                raise ValueError(
                    "%s/%s 0x%X 原始指令不匹配: 期望 0x%08X, 实际 0x%08X "
                    "(这个包可能是别的版本)" % (name, arch, va, ORIG_AND, cur))
            buf[at:at + 4] = struct.pack("<I", NEW_MOV)
            done += 1
            infos.append("%s/%s 0x%X  and w0,w22,#1 -> mov w0,#1" % (name, arch, va))
        # 打完代码就重算这个切片的签名
        fixed, rep = resign_slice(buf, off, size, verbose=verbose)
        bad = verify_slice(buf, off)
        if verbose:
            print("      签名复核: " + ", ".join(
                "htype%d %d/%d 页不匹配" % (h, b, t) for h, b, t in bad))
        if any(b for h, b, t in bad):
            raise ValueError("%s/%s 签名重算后仍有不匹配" % (name, arch))
    if done == 0 and not infos:
        raise ValueError("%s 没有匹配到任何补丁点" % name)
    if done == 0 and verbose:
        print("      (已经是补丁状态，仅重算签名)")
    return bytes(buf), " | ".join(infos)


# ---------------------------------------------------------------- deb 读写
def ar_read(path):
    """读 ar 归档 -> {成员名: bytes}"""
    raw = open(path, "rb").read()
    if not raw.startswith(b"!<arch>\n"):
        raise ValueError("不是 ar 归档(deb)")
    pos, members = 8, {}
    while pos + 60 <= len(raw):
        hdr = raw[pos:pos + 60]
        name = hdr[0:16].decode("utf-8", "replace").strip()
        size = int(hdr[48:58].decode().strip())
        body = raw[pos + 60: pos + 60 + size]
        members[name] = body
        pos += 60 + size + (size & 1)
    return members


def ar_write(path, members):
    out = [b"!<arch>\n"]
    for name, body in members.items():
        hdr = (("%-16s" % name).encode()
               + ("%-12d" % int(time.time())).encode()
               + ("%-6d" % 0).encode()
               + ("%-6d" % 0).encode()
               + ("%-8s" % "100644").encode()
               + ("%-10d" % len(body)).encode()
               + b"`\n")
        assert len(hdr) == 60, len(hdr)
        out.append(hdr)
        out.append(body)
        if len(body) & 1:
            out.append(b"\n")
    open(path, "wb").write(b"".join(out))


def tar_members(blob):
    tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:*")
    return tf


COMP_MODES = {
    ".gz": lambda b: gzip.compress(b, 9),
    ".xz": lambda b: lzma.compress(b, format=lzma.FORMAT_XZ),
    ".lzma": lambda b: lzma.compress(b, format=lzma.FORMAT_ALONE),
    ".bz2": lambda b: __import__("bz2").compress(b, 9),
}


def _pack(tf, replace, comp_suffix):
    """把 tar 成员(可替换指定文件内容)重新打包，并按原包后缀压缩"""
    raw = io.BytesIO()
    tfo = tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT)
    for m in tf.getmembers():
        if m.isfile():
            body = None
            for suffix, newdata in replace.items():
                if m.name.endswith(suffix):
                    body = newdata
                    break
            if body is None:
                body = tf.extractfile(m).read()
            info = tarfile.TarInfo(m.name)
            info.size = len(body)
            info.mode, info.uid, info.gid = m.mode, m.uid, m.gid
            info.uname, info.gname = m.uname, m.gname
            info.mtime = int(time.time())
            tfo.addfile(info, io.BytesIO(body))
        else:
            tfo.addfile(m)
    tfo.close()
    data = raw.getvalue()
    fn = COMP_MODES.get(comp_suffix)
    if fn is None:
        raise ValueError("不支持的压缩后缀 %r (支持 %s)" % (comp_suffix, list(COMP_MODES)))
    return fn(data)


def rebuild_tar(tf, replace, comp_suffix=".gz"):
    return _pack(tf, replace, comp_suffix)


def bump_version(control_tar, new_ver, comp_suffix=".gz"):
    tf = tar_members(control_tar)
    out = io.BytesIO()
    tfo = tarfile.open(fileobj=out, mode="w", format=tarfile.GNU_FORMAT)
    for m in tf.getmembers():
        body = tf.extractfile(m).read() if m.isfile() else None
        if m.isfile() and os.path.basename(m.name) == "control":
            lines = []
            for line in body.decode("utf-8").splitlines():
                if line.lower().startswith("version:"):
                    line = "Version: %s" % new_ver
                lines.append(line)
            body = ("\n".join(lines) + "\n").encode("utf-8")
        if m.isfile():
            info = tarfile.TarInfo(m.name)
            info.size = len(body)
            info.mode, info.uid, info.gid = m.mode, m.uid, m.gid
            info.uname, info.gname = m.uname, m.gname
            info.mtime = int(time.time())
            tfo.addfile(info, io.BytesIO(body))
        else:
            tfo.addfile(m)
    tfo.close()
    return _pack(tf, {}, comp_suffix) if False else COMP_MODES.get(comp_suffix, COMP_MODES[".gz"])(out.getvalue())


def suffix_of(member_name):
    for suf in (".lzma", ".zst", ".gz", ".xz", ".bz2"):
        if member_name.endswith(suf):
            return suf
    return ""


def verify_deb(path):
    """校验 deb 内所有 Mach-O 的代码签名页是否自洽"""
    members = ar_read(path)
    data_name = next(n for n in members if n.startswith("data.tar"))
    tf = tar_members(members[data_name])
    total_bad = 0
    for m in tf.getmembers():
        if not m.isfile():
            continue
        body = tf.extractfile(m).read()
        if len(body) < 8:
            continue
        try:
            slices = fat_slices(body)
        except ValueError:
            continue
        if not slices:
            continue
        print("%s" % m.name)
        for sub, off, size in slices:
            arch = "arm64e" if (sub & 0x00FFFFFF) == 2 else "arm64"
            try:
                res = verify_slice(body, off)
            except Exception as e:
                print("   %-7s 跳过: %s" % (arch, e))
                continue
            for htype, bad, total in res:
                total_bad += bad
                print("   %-7s htype=%d 页=%d 不匹配=%d %s"
                      % (arch, htype, total, bad, "OK" if bad == 0 else "<-- FAIL"))
    print("\n[%s] 总不匹配页数 = %d" % ("PASS" if total_bad == 0 else "FAIL", total_bad))
    return 0 if total_bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("deb", nargs="?", help="输入 deb")
    ap.add_argument("-o", "--out", help="输出 deb")
    ap.add_argument("-v", "--version", default=None, help="新版本号, 如 0.5.2-19")
    ap.add_argument("--binary", help="只补丁单个裸二进制(不打包)")
    ap.add_argument("--verify", metavar="DEB", help="只校验 deb 内二进制的签名页")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    verbose = not a.quiet

    if a.verify:
        return verify_deb(a.verify)

    if a.binary:
        name = os.path.basename(a.binary)
        out, info = patch_macho(open(a.binary, "rb").read(), name, verbose)
        dst = a.binary + ".patched"
        open(dst, "wb").write(out)
        print("OK -> %s\n%s" % (dst, info))
        return 0

    if not a.deb:
        ap.print_help()
        return 2

    members = ar_read(a.deb)
    data_name = next(n for n in members if n.startswith("data.tar"))
    ctrl_name = next(n for n in members if n.startswith("control.tar"))
    if verbose:
        print("[*] 输入 %s (%d 字节)" % (a.deb, os.path.getsize(a.deb)))

    tf = tar_members(members[data_name])
    names = [m.name for m in tf.getmembers() if m.isfile()]
    targets = {}
    for fname, points in PATCH_MAP.items():
        hit = [n for n in names if os.path.basename(n) == fname]
        if not hit:
            raise ValueError("包里找不到 %s" % fname)
        path = hit[0]
        if verbose:
            print("[*] 处理 %s" % path)
        raw = tf.extractfile(tf.getmember(path)).read()
        newdata, info = patch_macho(raw, fname, verbose)
        if verbose:
            print("      " + info)
        if len(newdata) != len(raw):
            raise ValueError("二进制长度变化了，中止")
        targets[path] = newdata

    old_ver = None
    ctf = tar_members(members[ctrl_name])
    for m in ctf.getmembers():
        if os.path.basename(m.name) == "control":
            for line in ctf.extractfile(m).read().decode().splitlines():
                if line.lower().startswith("version:"):
                    old_ver = line.split(":", 1)[1].strip()
    if a.version:
        new_ver = a.version
    else:
        try:
            base, _, rev = old_ver.rpartition("-")
            new_ver = "%s-%d" % (base, int(rev) + 1) if rev.isdigit() else old_ver + "-1"
        except Exception:
            new_ver = old_ver or "1.0-1"

    new_data = rebuild_tar(tf, {os.path.basename(k): v for k, v in targets.items()},
                           suffix_of(data_name))
    new_ctrl = bump_version(members[ctrl_name], new_ver, suffix_of(ctrl_name))

    out_path = a.out or os.path.splitext(a.deb)[0] + "_unlocked.deb"
    ar_write(out_path, {
        "debian-binary": members["debian-binary"],
        ctrl_name: new_ctrl,
        data_name: new_data,
    })
    print("[+] 完成: %s" % out_path)
    print("    版本 %s -> %s" % (old_ver, new_ver))
    print("    改了 %d 个二进制, 所有签名页已重算并复核通过" % len(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main())

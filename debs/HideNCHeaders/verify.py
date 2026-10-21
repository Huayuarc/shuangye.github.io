#!/usr/bin/env python3
"""Static verification only; this does NOT execute iOS binaries or replace device testing."""
import hashlib
import io
import pathlib
import plistlib
import struct
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent
BINARY = ROOT / 'build/HideNCHeaders.dylib'
DEB = ROOT / 'dist/HideNCHeaders_1.0.5_arm64_arm64e_roothide.deb'
lines = ['# HideNCHeaders 1.0.5 静态验证', '',
         '注意：以下为交叉编译产物静态检查，不代表 iOS 16.3 真机测试通过。', '']
def record(text):
    lines.append('- PASS: ' + text)
    print(text)
def unpack(fmt, data, offset=0):
    return struct.unpack_from(fmt, data, offset)
def cs_verify(data, off, size):
    blob = data[off:off+size]
    magic, length, count = unpack('>III', blob)
    assert magic == 0xfade0cc0 and 12 + 8*count <= length <= size
    directories = 0
    total = 0
    for i in range(count):
        slot, rel = unpack('>II', blob, 12 + 8*i)
        cmagic, clen = unpack('>II', blob, rel)
        assert rel + clen <= length
        if cmagic != 0xfade0c02:
            continue
        cd = blob[rel:rel+clen]
        _, _, version, flags, hash_off, ident_off, special, slots, limit = unpack('>9I', cd)
        hash_size, hash_type, platform, page_log = unpack('>4B', cd, 36)
        algorithms = {1:'sha1', 2:'sha256', 3:'sha256', 4:'sha384'}
        assert hash_type in algorithms and page_log <= 16
        if version >= 0x20300:
            big_limit = unpack('>Q', cd, 56)[0]
            if big_limit:
                limit = big_limit
        assert 0 < limit <= off and limit <= len(data)
        page_size = 1 << page_log
        assert slots == (limit + page_size - 1) // page_size
        assert 0 < hash_size <= hashlib.new(algorithms[hash_type]).digest_size
        assert hash_off + slots * hash_size <= len(cd)
        assert b'\0' in cd[ident_off:]
        for page in range(slots):
            actual = hashlib.new(algorithms[hash_type], data[page*page_size:min(limit,(page+1)*page_size)]).digest()[:hash_size]
            expected = cd[hash_off+page*hash_size:hash_off+(page+1)*hash_size]
            assert actual == expected, (page, hash_type)
        # This dylib has no external Info.plist/resource envelope or nonempty entitlements.
        # Verify all nonzero special-slot hashes against their embedded blobs.
        for s in range(1, special+1):
            expected = cd[hash_off-s*hash_size:hash_off-(s-1)*hash_size]
            if not any(expected):
                continue
            embedded = None
            for j in range(count):
                st, ro = unpack('>II', blob, 12+8*j)
                if st == s:
                    n = unpack('>I', blob, ro+4)[0]
                    embedded = blob[ro:ro+n]
            assert embedded is not None, ('external special slot', s)
            assert hashlib.new(algorithms[hash_type], embedded).digest()[:hash_size] == expected
        directories += 1
        total += slots
    assert directories
    return directories, total

def verify_macho(data, expected_subtype, label):
    magic, cpu, subtype, ftype, count, cmdbytes, flags, reserved = unpack('<8I', data)
    assert magic == 0xfeedfacf and cpu == 0x100000c and subtype == expected_subtype
    assert ftype == 6 and 32 + cmdbytes <= len(data)
    pos = 32
    sections = []
    exec_ranges = []
    dependencies = []
    signature = None
    minos = None
    identity = None
    for _ in range(count):
        cmd, size = unpack('<II', data, pos)
        assert size >= 8 and pos + size <= 32 + cmdbytes
        if cmd == 0x19:
            name = data[pos+8:pos+24].rstrip(b'\0').decode()
            vm, vs, fo, fs = unpack('<4Q', data, pos+24)
            maxprot, initprot, nsects, segflags = unpack('<4I', data, pos+56)
            if initprot & 4:
                exec_ranges.append((vm, vm+vs))
            for i in range(nsects):
                p = pos + 72 + i*80
                sn = data[p:p+16].rstrip(b'\0').decode()
                sg = data[p+16:p+32].rstrip(b'\0').decode()
                addr, nbytes, offset = unpack('<QQI', data, p+32)
                sections.append((sg, sn, addr, nbytes, offset))
        elif cmd in (0xc, 0x18|0x80000000, 0x1f|0x80000000, 0xd):
            noff = unpack('<I', data, pos+8)[0]
            name = data[pos+noff:pos+size].split(b'\0')[0].decode()
            if cmd == 0xd:
                identity = name
            else:
                dependencies.append(name)
        elif cmd == 0x1d:
            signature = unpack('<II', data, pos+8)
        elif cmd == 0x32:
            platform, minos, sdk = unpack('<III', data, pos+8)
            assert platform == 2 and minos <= 0x100300
        elif cmd == 0x25:
            minos = unpack('<I', data, pos+8)[0]
            assert minos <= 0x100300
        pos += size
    assert minos is not None
    assert identity == '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.dylib'
    assert dependencies and all(x.startswith(('/System/Library/', '/usr/lib/')) for x in dependencies)
    assert not any('/var/jb' in x or 'substrate' in x.lower() for x in dependencies)
    inits = [s for s in sections if s[1] in ('__init_offsets','__mod_init_func')]
    assert len(inits) == 1
    _, section, _, size, off = inits[0]
    step = 4 if section == '__init_offsets' else 8
    assert size and size % step == 0 and off + size <= len(data)
    for i in range(0, size, step):
        target = unpack('<I' if step == 4 else '<Q', data, off+i)[0]
        assert any(a <= target < b for a,b in exec_ranges)
    assert signature is not None
    dirs, pages = cs_verify(data, *signature)
    record(f'{label}: Mach-O subtype=0x{subtype:08x}，初始化入口 {section}，系统库依赖，{dirs} 个 CodeDirectory / {pages} 个代码页签名哈希通过')
    if expected_subtype == 0x80000002:
        assert any(s[1] in ('__auth_got','__auth_stubs') for s in sections)
        # Verify PAC instructions from the real compiled slice, not an edited CPU header.
        disasm = subprocess.check_output(['llvm-objdump','-d',str(ROOT/'build/arm64e.dylib')], text=True)
        assert 'pacibsp' in disasm and ('retab' in disasm or 'autibsp' in disasm)
        record('arm64e: versioned ABI 标记及指针认证指令/认证节均存在')

fat = BINARY.read_bytes()
magic, count = unpack('>II', fat)
assert magic == 0xcafebabe and count == 2
seen = set()
for i in range(count):
    cpu, subtype, off, size, align = unpack('>5I', fat, 8+i*20)
    assert cpu == 0x100000c and off % (1 << align) == 0
    assert off + size <= len(fat)
    assert subtype in (0, 0x80000002) and subtype not in seen
    seen.add(subtype)
    verify_macho(fat[off:off+size], subtype, 'arm64' if subtype == 0 else 'arm64e')
assert seen == {0,0x80000002}
record('Fat 动态库：恰好 arm64 + 真正 versioned arm64e 两个切片')
filter_data = plistlib.loads((ROOT/'HideNCHeaders.plist').read_bytes())
assert filter_data == {'Filter':{'Bundles':['com.apple.springboard']}}
record('注入过滤：仅 com.apple.springboard，无 App 注入')
control = (ROOT/'control').read_text()
fields = dict(line.split(': ', 1) for line in control.splitlines() if ': ' in line)
assert fields['Package'].isascii()
assert fields['Name'] == '隐藏通知清除按钮'
assert fields['Author'] == fields['Maintainer'] == 'L.E'
assert fields['Architecture'] == 'iphoneos-arm64e'
assert fields['Version'] == '1.0.5' and fields['Package'] == 'com.minis.hidencheaders'
assert 'firmware' not in fields.get('Depends', '').lower()
assert 'firmware' not in fields.get('Pre-Depends', '').lower()
record('安装元数据：已移除 firmware 的 iOS 版本上下限依赖；不代表跨系统版本实测兼容')
record('元数据：隐藏通知清除按钮 1.0.5 / 作者与维护者 L.E；RootHide iphoneos-arm64e 包架构，原包 ID 可直接覆盖升级')

def archive_members(which):
    flag = '--fsys-tarfile' if which == 'data' else '--ctrl-tarfile'
    blob = subprocess.check_output(['dpkg-deb',flag,str(DEB)])
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:') as tf:
        result = {}
        for m in tf.getmembers():
            assert not m.name.startswith('/') and '..' not in pathlib.PurePosixPath(m.name).parts
            assert m.uid == m.gid == 0
            if m.isfile():
                result[m.name.removeprefix('./')] = tf.extractfile(m).read()
        return result
payload = archive_members('data')
expected_files = {'Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.dylib',
                  'Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.plist'}
assert set(payload) == expected_files
assert payload['Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.dylib'] == fat
assert payload['Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.plist'] == (ROOT/'HideNCHeaders.plist').read_bytes()
metadata = archive_members('control')
assert set(metadata) == {'control'} and metadata['control'] == (ROOT/'control').read_bytes()
record('最终 deb：仅 dylib + SpringBoard filter；与签名产物逐字相同；所有者 root；无安装/卸载脚本和设置页')
main_source = (ROOT/'HideNCHeaders.m').read_text()
spacing_source = (ROOT/'HNCSpacing.h').read_text()
view_source = (ROOT/'HNCViewFallback.h').read_text()
footer_controls_source = (ROOT/'HNCFooterControls.h').read_text()
footer_spacing_source = (ROOT/'HNCFooterSpacing.h').read_text()
source = '\n'.join((main_source, spacing_source, view_source, footer_controls_source, footer_spacing_source))
for module in ('HNCFooterControls.h','HNCFooterSpacing.h'):
    assert '#include "'+module+'"' in main_source
assert main_source.count('objc_lookUpClass(') == 2
assert '#include "HNCSpacing.h"' in main_source
assert 'HNCProviderHasSuppressedHeader' in spacing_source
assert 'HNCReadObject(owner, listAccessor) != list' in spacing_source
assert 'if (!header) return NO;' in spacing_source
for name in (b'_headerViewHeight', b'headerViewHeightForNotificationList:withWidth:',
             b'NCNotificationListPresentableGroup', b'NCNotificationStructuredSectionList'):
    assert fat.count(name) >= 2, name
record('组间占位修复：两个架构均包含列表头高度、组/section 数据源及独立缓存 hook；非目标标题保留原值')
assert 'objc_lookUpClass("NCNotificationListSectionHeaderView")' in source
assert 'objc_lookUpClass("NCNotificationListCoalescingHeaderCell")' in source
assert 'coalescingHeaderCellHeightForWidth:title:' in source
assert 'method_setImplementation(local, replacement)' in source and 'class_addMethod(cls' in source
assert 'class_copyMethodList(cls' in source
assert 'BOOL coalescing = HNCInstallCoalescing();' in source
assert 'BOOL legacy = HNCInstallLegacy();' in source
for name in (b'NCNotificationListSectionHeaderView', b'NCNotificationListCoalescingHeaderCell',
             b'coalescingHeaderCellHeightForWidth:title:', b'headerHeightWithWidth:title:isShowingCollapseButton:'):
    assert fat.count(name) >= 2, name
record('修复回归：两个切片均有新式 CoalescingHeaderCell + 旧式标题类及各自高度入口')
assert 'frame =' not in main_source + spacing_source
assert 'setFrame:' not in main_source + spacing_source
assert 'removeAllNotification' not in source
assert 'setHeaderViewHeight:' not in spacing_source
assert 'state->setCachedHeight' not in spacing_source
assert 'HNCInstallViewHeightHooks(cls, &HNCLegacyViewHooks' in main_source
assert 'HNCInstallViewHeightHooks(cls, &HNCCoalescingViewHooks' in main_source
assert 'value.size.height = 0.0;' in view_source
assert 'HNCApplyMethod(cls, selector, method, replacement, original)' in view_source
for name in (b'setFrame:', b'setBounds:', b'sizeThatFits:', b'intrinsicContentSize',
             b'systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:'):
    assert fat.count(name) >= 2, name
for name in (b'NCNotificationListCoalescingControlsCell', b'NCNotificationListCoalescingControlsView',
             b'coalescingControlsCellHeightShowingCoalescingControls:', b'preferredHeight',
             b'_footerViewHeight', b'footerViewVerticalMargin',
             b'footerViewHeightForNotificationList:withWidth:'):
    assert fat.count(name) >= 2, name
assert 'HNCInstallFooterCell();' in main_source
assert 'HNCInstallStandaloneControls();' in main_source
assert 'HNCInstallFooterSpacing();' in main_source
assert 'setFooterViewHeight:' not in footer_spacing_source
assert 'setFooterViewVerticalMargin:' not in footer_spacing_source
assert 'if (actualFooter) return HNCFooterIsSuppressed(actualFooter)' in footer_spacing_source
assert 'HNCReadObject(owner, "groupListView") != list' in footer_spacing_source
record('底部补漏：双架构均有 ControlsCell + ControlsView 隐藏、类高度归零、footer 数据源与专属边距归零')
record('footer 隔离：实际 list 的非目标摘要优先，owner/list 身份匹配；不改原高度缓存 setter 或原始边距')
record('视图兜底：两种标题与两种分组控制类 frame/bounds/测量高度归零，保留宽度；不对整个列表、卡片及通用按钮安装几何 hook')
assert 'attempt >= 12' in source and '500 * NSEC_PER_MSEC' in source
assert 'isEqualToString:@"com.apple.springboard"' in source
assert 'HNCValid(method, result, arguments)' in source
record('源码边界：标题和分组底部控制及其匹配占位，严格运行时签名检查，有界重试，无全局 itemSpacing/frame 改写/通知删除调用')
runtime_report = (ROOT/'build/runtime_test.txt').read_text()
assert 'RUNTIME MOCK PASS: 205 assertions; 600 visibility/layout cycles' in runtime_report
assert 'header/footer occupancy and view-fallback passed; card/list geometry and raw caches unchanged' in runtime_report
record('本机 GNU ObjC 模拟回归：205 条断言 / 600 次复用；新增底部隐藏/占位/视图兜底、类型与归属切换、原缓存和卡片/列表几何不改（非 UIKit 真机测试）')
lines.extend(['', '## 文件', '', f'- deb SHA256: `{hashlib.sha256(DEB.read_bytes()).hexdigest()}`',
              f'- dylib SHA256: `{hashlib.sha256(fat).hexdigest()}`', '',
              '## 尚未验证', '', '- iOS 16.3 真机新增底部控制行隐藏、实际标题/底部占位及与其他通知插件并用时的界面效果。',
              '- 公开 iOS 17 头文件与本机 iOS 16.5 SDK 导出不能代替 iOS 16.3 设备运行。',
              '- 需安装后重启桌面，在锁屏与通知中心分别展开同 App 多条通知验收。', ''])
(ROOT/'verification.md').write_text('\n'.join(lines))
print('ALL STATIC CHECKS PASSED')

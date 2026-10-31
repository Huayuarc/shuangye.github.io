"""isolation.15 偏好持久化加固（rootless/Dopamine 链路）与"首次默认关闭"源码合同。

覆盖：
- CPUthermalSameFile（stat st_dev/st_ino）存在且三处删除点全部经闸门（同文件 + RootHide 判定）；
- Rootless 分支直接返回真实 var 路径（kCPUthermalPrefRootFSPathC），不再做 jbroot()/"/var/jb" 探测；
- RootHide 根评分含 +10000 数据锚定档；
- WritePrefs 读回校验（isEqualToDictionary）+ 重试一次 + CPUthermalCanonicalPrefPath 回退；
- Legacy 列表含 jbroot 转换变体与 symlink 解析变体；
- 面板级写校验（readback + 重试 + canonical 回退），notify_post 在写校验之后；
- 模块缺省值（Tweak.x / Tweak_ThermalWarn.xm / CPUthermalChargeTool.m）一律 NO。
"""
import re
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
PATHS = (P / 'include/CPUthermalPaths.h').read_text()
PANEL = (P / 'Settings/FRootListController.m').read_text()
TWEAK = (P / 'Tweak.x').read_text()
WARN = (P / 'CPUthermalSpringBoard.xm').read_text()
TOOL = (P / 'Tools/CPUthermalChargeTool.m').read_text()
FACEDOWN = (P / 'CPUthermalSpringBoard.xm').read_text()

SWITCH_KEYS = ('lockWhenFaceDown', 'sunlightLockedEnabled', 'blockThermalPopup',
               'suppressBatteryServiceWarnings', 'suppressComponentWarning',
               'smartChargeEnabled', 'ignoreThermalThrottle')


def body_of(text, start_marker, end_marker='\n}'):
    """取 { 起始的 C/ObjC 函数体（项目风格：结束花括号在行首）。"""
    assert start_marker in text, start_marker
    return text.split(start_marker, 1)[1].split(end_marker, 1)[0]


class PersistenceGuards(unittest.TestCase):
    # ------------------------------------------------------------------
    # A. 同文件保护与删除闸门
    # ------------------------------------------------------------------
    def test_same_file_helper_uses_stat_dev_and_ino(self):
        body = body_of(PATHS, 'static inline BOOL CPUthermalSameFile(NSString *a, NSString *b) {')
        self.assertIn('struct stat infoA;', body)
        self.assertIn('struct stat infoB;', body)
        self.assertIn('stat(a.fileSystemRepresentation, &infoA)', body)
        self.assertIn('stat(b.fileSystemRepresentation, &infoB)', body)
        self.assertIn('infoA.st_dev == infoB.st_dev && infoA.st_ino == infoB.st_ino', body)
        # 任一文件不存在（stat 失败）返回 NO：两文件都存在才可能判为同一文件
        self.assertEqual(body.count('!= 0) return NO;'), 2)

    def test_all_three_removals_guarded(self):
        # 删除点恰好三处（读两处 + 写一处），全部经 CPUthermalPrefDeletionAllowed 闸门。
        self.assertEqual(PATHS.count('removeItemAtPath:'), 3)
        self.assertEqual(PATHS.count('if (CPUthermalPrefDeletionAllowed('), 3)

    def test_deletion_gate_only_removes_known_legacy_copies(self):
        gate = body_of(PATHS, 'static inline BOOL CPUthermalPrefDeletionAllowed(NSString *currentPath, NSString *candidate) {')
        # 同文件（stat 判定，含 /var/jb 与真实路径互为别名）绝不允许删除
        self.assertIn('CPUthermalSameFile(candidate, currentPath)', gate)
        self.assertLess(gate.index('CPUthermalSameFile'), gate.index('return YES;'),
                        '同文件保护必须先于任何允许删除分支')
        # 只允许删除已知旧位置：RootHide 根、旧真实 var，以及越狱根镜像路径
        self.assertIn('S("/Containers/Shared/AppGroup/.jbroot-")', gate)
        self.assertIn('kCPUthermalPrefRootFSPathC', gate)
        self.assertIn('hasPrefix:', gate)

    # ------------------------------------------------------------------
    # B. 路径解析
    # ------------------------------------------------------------------
    def test_rootless_preferences_live_inside_jailbreak_root(self):
        # isolation.19：rootless 配置改放越狱根内（与 Hello 120Hz 同模型），避开 var 清理工具。
        current = body_of(PATHS, 'static inline NSString *CPUthermalCurrentPrefPath(void) {')
        code = '\n'.join(l for l in current.splitlines() if not l.lstrip().startswith('//'))
        self.assertIn('return CPUthermalRootlessPrefPath();', code)
        rootless = body_of(PATHS, 'static inline NSString *CPUthermalRootlessPrefPath(void) {')
        self.assertIn('S("/var/jb")', rootless)
        self.assertIn('kCPUthermalPrefJBRelativePathC', rootless)
        self.assertIn('var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist', PATHS)
        canonical = body_of(PATHS, 'static inline NSString *CPUthermalCanonicalPrefPath(void) {')
        self.assertIn('return CPUthermalRootlessPrefPath();', canonical)
        self.assertIn('CPUthermalRootHidePrefPathForRoot(rootHideRoot)', canonical)
        # 旧真实 var 路径仍保留为迁移来源
        self.assertIn('static const char *kCPUthermalPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist";', PATHS)

    def test_roothide_root_scoring_data_anchored(self):
        body = body_of(PATHS, 'static inline NSString *CPUthermalCurrentRootHideRoot(void) {')
        for weight in ('score += 10000;', 'score += 1000;', 'score += 100;', 'score += 10;'):
            self.assertIn(weight, body)
        # 数据锚定档（含现有 plist 的根）必须优先于仅含 dylib 的档
        self.assertIn('CPUthermalRootHidePrefPathForRoot(root)', body)
        self.assertLess(body.index('score += 10000;'), body.index('score += 1000;'))
        self.assertLess(body.index('score += 1000;'), body.index('score += 100;'))
        self.assertLess(body.index('score += 100;'), body.index('score += 10;'))
        # 同分再按 mtime 最新
        self.assertIn('[date compare:bestDate] == NSOrderedDescending', body)

    def test_legacy_list_includes_jbroot_variants(self):
        body = body_of(PATHS, 'static inline NSArray<NSString *> *CPUthermalLegacyPrefPaths(void) {')
        # 各 .jbroot-* 根
        self.assertIn('CPUthermalRootHidePrefPathForRoot(root)', body)
        # 解析后的旧 JB Library/Preferences 路径
        self.assertIn('CPUthermalOldJBRootPrefPath()', body)
        # jbroot 转换变体及其 symlink 解析变体
        self.assertIn('S("/var/jb") stringByAppendingPathComponent:S("var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist")', body)
        self.assertIn('destinationOfSymbolicLinkAtPath:S("/var/jb")', body)
        self.assertIn('resolvedJBRoot stringByAppendingPathComponent:S("var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist")', body)
        # 真实 var 路径
        self.assertIn('CPUthermalStringFromCPath(kCPUthermalPrefRootFSPathC)', body)
        # 去重
        self.assertIn('CPUthermalAppendUniquePath', body)
        self.assertIn('![paths containsObject:path]', PATHS)

    # ------------------------------------------------------------------
    # C. 写入校验与迁移
    # ------------------------------------------------------------------
    def test_write_prefs_readback_retry_and_canonical_fallback(self):
        verify = body_of(PATHS, 'static inline BOOL CPUthermalWritePrefsAtPathVerified(NSDictionary *prefs, NSString *path) {')
        self.assertIn('if (![prefs writeToFile:path atomically:YES]) return NO;', verify)
        self.assertIn('[NSDictionary dictionaryWithContentsOfFile:path]', verify)
        self.assertIn('[readBack isEqualToDictionary:prefs]', verify)
        self.assertIn('return readBack && [readBack isEqualToDictionary:prefs];', verify)

        body = body_of(PATHS, 'static inline BOOL CPUthermalWritePrefs(NSDictionary *prefs) {')
        self.assertEqual(body.count('CPUthermalWritePrefsAtPathVerified(prefs, path)'), 2)   # 首次 + 重试一次
        self.assertIn('CPUthermalCanonicalPrefPath()', body)
        self.assertIn('CPUthermalWritePrefsAtPathVerified(prefs, canonicalPath)', body)
        # 清理循环只在写入成功（ok）之后，且带闸门
        self.assertLess(body.index('if (ok) {'), body.index('CPUthermalPrefDeletionAllowed(path, legacyPath)'))
        self.assertIn('return ok;', body)

    def test_migration_writes_canonical_and_never_deletes_in_rootless(self):
        body = body_of(PATHS, 'static inline NSMutableDictionary *CPUthermalReadMutablePrefs(void) {')
        self.assertIn('CPUthermalCanonicalPrefPath()', body)
        self.assertIn('CPUthermalWritePrefsAtPathVerified(prefs, canonicalPath)', body)
        # 两处清理（当前有效分支 + 迁移分支）都过闸门；rootless 下闸门恒 NO
        self.assertEqual(body.count('if (CPUthermalPrefDeletionAllowed('), 2)

    # ------------------------------------------------------------------
    # D. 面板级写校验与属主/权限修复（isolation.15 补充要求）
    # ------------------------------------------------------------------
    def test_panel_write_readback_retry_canonical_fallback(self):
        body = body_of(PANEL, '- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {',
                       '\n- (id)readPreferenceValue:')
        self.assertEqual(body.count('CPUthermalWritePrefs(prefs);'), 2)                     # 首次 + 重试一次
        self.assertEqual(body.count('NSDictionary *readBack = CPUthermalReadPrefs();'), 1)
        self.assertEqual(body.count('readBack = CPUthermalReadPrefs();'), 2)                 # 首次 + 复核
        self.assertEqual(body.count('CPUthermalPrefValueEquals(readBack[key], value)'), 2)
        self.assertIn('CPUthermalWritePrefsAtPathVerified(prefs, CPUthermalCanonicalPrefPath());', body)
        # notify_post 在写校验之后
        self.assertLess(body.index('CPUthermalPrefValueEquals(readBack[key], value)'),
                        body.index('notify_post(kCPUthermalSettingsChangedNotifC)'))

    def test_ownership_fix_helper_and_write_paths(self):
        # chown mobile:mobile(501:501) + chmod 0644，best-effort、失败静默
        body = body_of(PATHS, 'static inline void CPUthermalFixPrefOwnership(NSString *path) {')
        self.assertIn('chown(filePath, 501, 501);', body)
        self.assertIn('chmod(filePath, 0644);', body)
        self.assertIn('if (path.length == 0) return;', body)
        self.assertIn('#include <unistd.h>', PATHS)
        # WritePrefs 成功路径调用（在 ok 分支内、旧副本清理之前）
        write = body_of(PATHS, 'static inline BOOL CPUthermalWritePrefs(NSDictionary *prefs) {')
        self.assertIn('if (ok) {', write)
        self.assertLess(write.index('CPUthermalFixPrefOwnership(path);'),
                        write.index('CPUthermalPrefDeletionAllowed(path, legacyPath)'))
        self.assertLess(write.index('CPUthermalWritePrefsAtPathVerified(prefs, canonicalPath)'),
                        write.index('CPUthermalPrefDeletionAllowed(path, legacyPath)'))
        # 迁移写入路径同样调用
        read = body_of(PATHS, 'static inline NSMutableDictionary *CPUthermalReadMutablePrefs(void) {')
        self.assertIn('CPUthermalFixPrefOwnership(canonicalPath);', read)
        # 只在成功路径出现（失败不修）
        self.assertEqual(PATHS.count('CPUthermalFixPrefOwnership('), 3)   # 定义 + 两处调用

    def test_ctor_and_postinst_fix_existing_file(self):
        # 核心 %ctor 启动补一次（best-effort）
        ctor = TWEAK.split('%ctor {', 1)[1]
        self.assertIn('CPUthermalFixPrefOwnership(CPUthermalCurrentPrefPath());', ctor)
        # postinst configure 分支对已存在文件执行 chown/chmod（保留原有 killall/bootstrap 行）
        postinst = (P / 'scripts/postinst.in').read_text()
        self.assertIn('chown mobile:mobile "$h18new" 2>/dev/null || true', postinst)
        self.assertIn('chmod 644 "$h18new" 2>/dev/null || true', postinst)
        self.assertIn('killall -q thermalmonitord', postinst)
        self.assertIn('launchctl bootstrap system @JBROOT@/Library/LaunchDaemons/', postinst)
        # 交付包内 DEBIAN/postinst 由 Makefile 在打包阶段从该模板渲染（见 Makefile after-stage），
        # 源内校验模板 + Makefile 渲染规则存在即可。
        self.assertIn('scripts/postinst.in', (P / 'Makefile').read_text())

    def test_panel_read_path_is_non_destructive(self):
        body = body_of(PANEL, '- (id)readPreferenceValue:(PSSpecifier *)spec {')
        self.assertIn('id val = [self prefs][key];', body)
        self.assertIn('if (val != nil) return val;', body)
        self.assertIn('id defaultValue = [spec propertyForKey:S("default")];', body)
        self.assertIn('return defaultValue ?: [NSNumber numberWithBool:NO];', body)
        for forbidden in ('CPUthermalWritePrefs', 'removeItemAtPath', 'writeToFile',
                          'chmod', 'chown', 'CFPreferencesSetAppValue'):
            self.assertNotIn(forbidden, body)

    def test_panel_switches_all_default_false(self):
        for key in SWITCH_KEYS:
            self.assertRegex(PANEL, rf'ITEM\([^\n]+"{key}"[^\n]+numberWithBool:NO')
        self.assertEqual(len(re.findall(
            r'ITEM\("[^"]+", "[^"]+", PSSwitchCell, \[NSNumber numberWithBool:YES\]', PANEL)), 0)

    # ------------------------------------------------------------------
    # E. 模块缺省值（缺失键一律 NO）与兼容性
    # ------------------------------------------------------------------
    def test_module_fallbacks_missing_key_off(self):
        # 高温警告抑制模块：静态初值与缺失键均为 NO
        self.assertIn('static BOOL gBlockThermalPopup = NO;', WARN)
        self.assertIn('__atomic_store_n(&gBlockThermalPopup, warnEnabled, __ATOMIC_RELEASE);', WARN)
        self.assertNotIn('gBlockThermalPopup = YES', WARN)
        # Tweak.x：blockPopup 由"恒开"改为读取偏好（缺失=NO）
        self.assertIn('id blockPopupValue = d[S("blockThermalPopup")];', TWEAK)
        self.assertIn('BOOL blockPopup = blockPopupValue ? [blockPopupValue boolValue] : NO;', TWEAK)
        self.assertNotIn('BOOL blockPopup = YES;', TWEAK)
        # 开关即时生效：settingsChanged → onSettingsChanged → loadPrefs
        settings_handler = body_of(TWEAK, 'static void onSettingsChanged(CFNotificationCenterRef center')
        self.assertIn('loadPrefs();', settings_handler)
        self.assertIn('CPUthermalSettingsChangedNotifC', TWEAK)
        # ChargeTool（isolation.23）：主开关合并为 smartChargeEnabled，缺省 NO；
        # smartChargeUseSmartBatteryAPI/DisableInflow 保留为兼容性 legacy 读取（无独立默认值断言）。
        self.assertIn('BOOL enabled = BoolPreference(prefs, S("smartChargeEnabled"), NO)', TOOL)
        # 其余开关读取点：nil → NO（boolValue 对 nil 返回 NO）
        self.assertIn('id faceValue = prefs[S("lockWhenFaceDown")];', FACEDOWN)
        self.assertIn('[faceValue respondsToSelector:@selector(boolValue)] ? [faceValue boolValue] : NO', FACEDOWN)

    def test_compat_constants_and_string_convention(self):
        self.assertIn('static const char *kCPUthermalSettingsChangedNotifC = "com.huayuarc.cputhermal/settingsChanged";', PATHS)
        self.assertIn('static const char *kCPUthermalSmartChargeCutoffNotifC = "com.huayuarc.cputhermal/smartChargeCutoffState";', PATHS)
        self.assertIn('#define S(str) [NSString stringWithUTF8String:(str)]', PATHS)
        # roothide 约定：源内不得出现 @"..." 字符串字面量
        for line in PATHS.splitlines():
            if line.lstrip().startswith('//'):
                continue
            self.assertNotIn('@"', line)

    def test_same_notification_used_by_all_settings_writers(self):
        # 面板写入路径仍只发这一条设置变更通知（触发各模块即时重载）
        self.assertEqual(PANEL.count('notify_post(kCPUthermalSettingsChangedNotifC)'), 1)
        self.assertIn('notify_register_dispatch(kCPUthermalSettingsChangedNotifC', WARN)
        self.assertIn('notify_register_dispatch(kCPUthermalSettingsChangedNotifC', FACEDOWN)


if __name__ == '__main__':
    unittest.main(verbosity=2)


class RebootButtonRemovedContracts(unittest.TestCase):
    def test_panel_has_no_userspace_reboot_entry(self):
        panel = (P / 'Settings/FRootListController.m').read_text()
        self.assertNotIn('重启用户空间', panel)
        self.assertNotIn('usreboot', panel)
    def test_no_reboot_notification_or_daemon_handler(self):
        self.assertNotIn('userspaceReboot', (P / 'include/CPUthermalPaths.h').read_text())
        tool = (P / 'Tools/CPUthermalChargeTool.m').read_text()
        self.assertNotIn('userspaceReboot', tool)
        self.assertNotIn('HandleUserspaceRebootRequest', tool)
    def test_postinst_migrates_preferences_out_of_real_var(self):
        script = (P / 'scripts/postinst.in').read_text()
        self.assertIn('$h120base/var/mobile/Library/Preferences', script)
        self.assertIn('cp "$h18old" "$h18new"', script)
        self.assertIn('rm -f "$h18old"', script)

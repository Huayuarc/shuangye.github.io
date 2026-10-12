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
WARN = (P / 'Tweak_ThermalWarn.xm').read_text()
TOOL = (P / 'Tools/CPUthermalChargeTool.m').read_text()
FACEDOWN = (P / 'FaceDownLock.xm').read_text()

SWITCH_KEYS = ('lockWhenFaceDown', 'sunlightLockedEnabled', 'blockThermalPopup',
               'smartChargeUseSmartBatteryAPI', 'smartChargeEnabled',
               'smartChargeDisableInflow', 'currentGuardEnabled')


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

    def test_deletion_gate_requires_roothide_and_distinct_file(self):
        gate = body_of(PATHS, 'static inline BOOL CPUthermalPrefDeletionAllowed(NSString *currentPath, NSString *candidate) {')
        # rootless（非 .jbroot 路径）直接不允许删除
        self.assertIn('S("/Containers/Shared/AppGroup/.jbroot-")', gate)
        self.assertIn('return NO;', gate)
        # 同一文件（stat 判定）不允许删除
        self.assertIn('CPUthermalSameFile(candidate, currentPath)', gate)
        self.assertLess(gate.index('containsString:'), gate.index('CPUthermalSameFile'),
                        'RootHide 闸门必须先于同文件判定')

    # ------------------------------------------------------------------
    # B. 路径解析
    # ------------------------------------------------------------------
    def test_rootless_branch_returns_real_var_path(self):
        current = body_of(PATHS, 'static inline NSString *CPUthermalCurrentPrefPath(void) {')
        code = '\n'.join(l for l in current.splitlines() if not l.lstrip().startswith('//'))
        self.assertIn('return CPUthermalStringFromCPath(kCPUthermalPrefRootFSPathC);', code)
        self.assertNotIn('jbroot(', code)          # 代码路径不再做 jbroot() 探测（注释除外）
        self.assertNotIn('/var/jb', code)
        canonical = body_of(PATHS, 'static inline NSString *CPUthermalCanonicalPrefPath(void) {')
        self.assertIn('return CPUthermalStringFromCPath(kCPUthermalPrefRootFSPathC);', canonical)
        self.assertIn('CPUthermalRootHidePrefPathForRoot(rootHideRoot)', canonical)
        # kCPUthermalPrefRootFSPathC 常量未变
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
    # D. 面板级写校验（isolation.15 补充要求）与 CFPreferences 双通道
    # ------------------------------------------------------------------
    def test_panel_write_dual_channel_and_verify(self):
        body = body_of(PANEL, '- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {',
                       '\n- (id)readPreferenceValue:')
        # rootless：CFPreferences（cfprefsd）为主通道；RootHide：直写为主
        self.assertIn('if (!CPUthermalIsRootHideMode()) {', body)
        self.assertIn('stored = CPUthermalWritePrefValueViaCFPreferences(key, value, prefs, previous);', body)
        self.assertIn('CPUthermalWritePrefs(prefs);', body)
        self.assertIn('CPUthermalPrefValueEquals([[self prefs] objectForKey:key], value)', body)
        self.assertIn('CPUthermalPrefValueEquals(CPUthermalCFPreferenceValue(key), value)', body)
        # 写校验之后才发通知
        self.assertLess(body.index('CPUthermalWritePrefValueViaCFPreferences'),
                        body.index('notify_post(kCPUthermalSettingsChangedNotifC)'))
        self.assertLess(body.index('CPUthermalPrefValueEquals(CPUthermalCFPreferenceValue(key), value)'),
                        body.index('notify_post(kCPUthermalSettingsChangedNotifC)'))
        # 写入前保留上一份字典（供 CFPreferences 删除已移除的键）
        self.assertIn('NSDictionary *previous = [prefs copy];', body)

    def test_cfpreferences_helpers_in_header(self):
        # 域名与 API 齐全
        self.assertIn('return S("com.huayuarc.cputhermal");', PATHS)
        self.assertIn('CFPreferencesCopyAppValue((__bridge CFStringRef)key,', PATHS)
        self.assertIn('CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain);', PATHS)
        self.assertIn('CFPreferencesAppSynchronize(domain);', PATHS)
        # 桥接与 ARC 语义
        self.assertIn('return (__bridge_transfer id)value;', PATHS)
        # 全量同步 + 已删除键清除（CFPreferencesSetAppValue 传 NULL）
        sync = body_of(PATHS, 'static inline void CPUthermalSyncPrefsToCFPreferences(NSDictionary *prefs, NSDictionary *previous) {')
        self.assertIn('for (NSString *key in prefs) {', sync)
        self.assertIn('if (prefs[key] == nil) {', sync)
        self.assertIn('CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, domain);', sync)
        # 写 + 读回校验 + 重试一次
        write = body_of(PATHS, 'static inline BOOL CPUthermalWritePrefValueViaCFPreferences(NSString *key, id value,\n                                                            NSDictionary *prefs, NSDictionary *previous) {')
        self.assertIn('for (int attempt = 0; attempt < 2 && !ok; attempt++) {', write)
        self.assertIn('CPUthermalSyncPrefsToCFPreferences(prefs, attempt == 0 ? previous : nil);', write)
        self.assertIn('ok = CPUthermalPrefValueEquals(CPUthermalCFPreferenceValue(key), value);', write)
        # rootless 判定
        self.assertIn('static inline BOOL CPUthermalIsRootHideMode(void) {\n    return CPUthermalCurrentRootHideRoot().length > 0;\n}', PATHS)

    def test_panel_read_dual_channel_order(self):
        body = body_of(PANEL, '- (id)readPreferenceValue:(PSSpecifier *)spec {')
        # rootless：CFPreferences → 直写文件 → default → NO
        self.assertIn('if (!CPUthermalIsRootHideMode()) {', body)
        cf_first = body.index('CPUthermalCFPreferenceValue(key)')
        file_read = body.index('id val = [self prefs][key];')
        default_read = body.index('id defaultValue = [spec propertyForKey:S("default")];')
        self.assertLess(cf_first, file_read)
        self.assertLess(file_read, default_read)
        self.assertIn('if (val != nil) return val;', body)
        self.assertIn('if (cfValue != nil) return cfValue;', body)
        self.assertIn('return defaultValue ?: [NSNumber numberWithBool:NO];', body)
        # RootHide 下 CFPreferences 再次作为回落（在直写之后、default 之前）
        self.assertLess(body.index('if (CPUthermalIsRootHideMode()) {'), default_read)
        # 显式 false 优先：CFBoolean false 非 nil；文件值 nil 检查同样保留
        self.assertIn('if (val != nil) return val;', body)

    def test_panel_read_path_is_non_destructive(self):
        body = body_of(PANEL, '- (id)readPreferenceValue:(PSSpecifier *)spec {')
        for forbidden in ('CPUthermalWritePrefs', 'CPUthermalWritePrefValueViaCFPreferences',
                          'removeItemAtPath', 'writeToFile', 'CFPreferencesSetAppValue'):
            self.assertNotIn(forbidden, body)
        for forbidden in ('CPUthermalWritePrefs', 'removeItemAtPath', 'writeToFile'):
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
        self.assertIn('gBlockThermalPopup = v ? [v boolValue] : NO;', WARN)
        self.assertNotIn('gBlockThermalPopup = YES', WARN)
        # Tweak.x：blockPopup 由"恒开"改为读取偏好（缺失=NO）
        self.assertIn('id blockPopupValue = d[S("blockThermalPopup")];', TWEAK)
        self.assertIn('BOOL blockPopup = blockPopupValue ? [blockPopupValue boolValue] : NO;', TWEAK)
        self.assertNotIn('BOOL blockPopup = YES;', TWEAK)
        # 开关即时生效：settingsChanged → onSettingsChanged → loadPrefs
        settings_handler = body_of(TWEAK, 'static void onSettingsChanged(CFNotificationCenterRef center')
        self.assertIn('loadPrefs();', settings_handler)
        self.assertIn('CPUthermalSettingsChangedNotifC', TWEAK)
        # ChargeTool 三处回退值：currentGuardEnabled / smartChargeUseSmartBatteryAPI ×2
        self.assertIn('return BoolPreference(prefs, S("currentGuardEnabled"), NO);', TOOL)
        self.assertEqual(len(re.findall(r'BoolPreference\(prefs, S\("smartChargeUseSmartBatteryAPI"\), NO\)', TOOL)), 2)
        self.assertIn('BoolPreference(prefs, S("smartChargeEnabled"), NO)', TOOL)
        self.assertIn('BoolPreference(prefs, S("smartChargeDisableInflow"), NO)', TOOL)
        # 其余开关读取点：nil → NO（boolValue 对 nil 返回 NO）
        self.assertIn('[CPUthermalReadPrefs()[S("lockWhenFaceDown")] boolValue]', FACEDOWN)

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

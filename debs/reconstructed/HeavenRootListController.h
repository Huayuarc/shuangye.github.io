// ============================================================================
// HeavenRootListController.h — 主设置列表控制器
// 逆向还原自 HeavenPrefs
// ============================================================================

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

NS_ASSUME_NONNULL_BEGIN

// [RE] 推测: HeavenRootListController : PSListController 是 PreferenceLoader 入口
// 通过 PLIST 中 entry 的 "controllerClass" 引用
@interface HeavenRootListController : PSListController

// ---- 缓存的动作方法 (PSListController 通过 specifier 的 action 调用) ----

// 清理类
- (void)actionCleanAll;
- (void)actionCleanAppleID;
- (void)actionCleanAppStore;
- (void)actionAdvancedCleanup;

// 备份管理
- (void)actionBackupManager;
- (void)actionSnapshotManager;
- (void)actionProfileManager;

// 配置文件
- (void)actionSelectApp;
- (void)actionGenerateNewProfile;
- (void)actionViewCurrentProfile;
- (void)actionResetToDefault;

// 系统
- (void)actionRespring;
- (void)actionShowDeviceInfo;

// 反馈
- (void)actionOpenFeedback;

// UI 辅助
- (void)_setupHeader;
- (void)_styleTableView;

@end

NS_ASSUME_NONNULL_END

# CC26 0.6.0.1-universal2 逻辑说明

## 核心补丁（继承 universal1）

```objc
if (view belongs to media / Now Playing path) {
    skip_CC26_media_customization();
}

if (materialLayer is very tall-and-narrow volume HUD layer) {
    skip_Prism_effect_for_this_layer();
} else {
    preserve_normal_Control_Center_Prism();
}

powerMenu.title = @"选择操作";
powerMenu.items = @[@"重启", @"刷新", @"用户重启"];
powerButton.showsMenuAsPrimaryAction = NO;

void applyBorderToSpecialViews(/* ... */) {
    return; // arm64 + arm64e 均直接返回
}
```

## 新增 Loader 版本边界

```objc
void CC26LoaderInit(void) {
    if (currentProcess.bundleID != @"com.apple.springboard") return;
    if (majorVersion < 15 || majorVersion > 16) return;
    if (!NSClassFromString(@"MTMaterialLayer")) return;
    if (!NSClassFromString(@"CCUIModularControlCenterOverlayViewController")) return;
    if (!class_getInstanceMethod(MTMaterialLayer,
          @selector(_configureIfNecessaryWithSettingsInterpolator:))) return;
    if (CFPreferences[Enabled] == NO) return;
    dlopen(siblingPath(@"CC26Core.dylib"), RTLD_NOW | RTLD_LOCAL);
}
```

上传版核心不再直接附带注入 plist；只有 Loader 注入 SpringBoard。这样 iOS 17+ 与缺失关键私有类的
运行环境会保留核心文件但不执行，避免版本不匹配导致 SpringBoard Safe Mode。

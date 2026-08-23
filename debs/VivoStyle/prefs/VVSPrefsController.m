#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <spawn.h>
#import <roothide.h>
#import "../common/VVSCommon.h"

extern char **environ;

@interface VVSPrefsController : PSListController <PHPickerViewControllerDelegate>
@property (nonatomic, assign) BOOL pickingVideo;
@end

@implementation VVSPrefsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *s = [NSMutableArray array];

        // ---- Group: master switch ----
        PSSpecifier *grp1 = [PSSpecifier preferenceSpecifierNamed:@"" target:self
            set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [grp1 setProperty:@"VivoStyle 还原 vivo OriginOS 的陀螺仪“翻转卡片”锁屏壁纸。左右倾斜手机，即可在所选照片之间自然切换。" forKey:@"footerText"];
        [s addObject:grp1];

        PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用 VivoStyle" target:self
            set:@selector(setPref:forSpecifier:) get:@selector(readPref:) detail:Nil cell:PSSwitchCell edit:Nil];
        [enabled setProperty:kVVSKeyEnabled forKey:@"key"];
        [enabled setProperty:kVVSPrefsSuite forKey:@"defaults"];
        [enabled setProperty:@NO forKey:@"default"];
        [s addObject:enabled];

        // ---- Group: photos ----
        PSSpecifier *grp2 = [PSSpecifier preferenceSpecifierNamed:@"照片" target:self
            set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [grp2 setProperty:@"vivo 默认使用 4 张照片；你可以自由选择数量，壁纸会按照选择顺序切换。" forKey:@"footerText"];
        [s addObject:grp2];

        PSSpecifier *pick = [PSSpecifier preferenceSpecifierNamed:@"选择照片…" target:self
            set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        [pick setProperty:@YES forKey:@"enabled"];
        pick.buttonAction = @selector(pickPhotos);
        [s addObject:pick];

        PSSpecifier *count = [PSSpecifier preferenceSpecifierNamed:[self countLabel] target:self
            set:NULL get:NULL detail:Nil cell:PSTitleValueCell edit:Nil];
        [count setProperty:@"countCell" forKey:@"id"];
        [s addObject:count];

        PSSpecifier *clear = [PSSpecifier preferenceSpecifierNamed:@"清除照片" target:self
            set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        clear.buttonAction = @selector(clearPhotos);
        [clear setProperty:@YES forKey:@"enabled"];
        [s addObject:clear];

        // ---- Group: video wallpaper ----
        PSSpecifier *grpV = [PSSpecifier preferenceSpecifierNamed:@"视频壁纸" target:self
            set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [grpV setProperty:@"使用循环静音视频替代照片翻转卡片。启用后视频将取代照片，且不使用陀螺仪效果。" forKey:@"footerText"];
        [s addObject:grpV];

        PSSpecifier *vEnabled = [PSSpecifier preferenceSpecifierNamed:@"使用视频壁纸" target:self
            set:@selector(setPref:forSpecifier:) get:@selector(readPref:) detail:Nil cell:PSSwitchCell edit:Nil];
        [vEnabled setProperty:kVVSKeyVideoEnabled forKey:@"key"];
        [vEnabled setProperty:kVVSPrefsSuite forKey:@"defaults"];
        [vEnabled setProperty:@NO forKey:@"default"];
        [s addObject:vEnabled];

        PSSpecifier *vPick = [PSSpecifier preferenceSpecifierNamed:@"选择视频…" target:self
            set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        vPick.buttonAction = @selector(pickVideo);
        [vPick setProperty:@YES forKey:@"enabled"];
        [s addObject:vPick];

        PSSpecifier *vStatus = [PSSpecifier preferenceSpecifierNamed:[self videoStatusLabel] target:self
            set:NULL get:NULL detail:Nil cell:PSTitleValueCell edit:Nil];
        [vStatus setProperty:@"videoCell" forKey:@"id"];
        [s addObject:vStatus];

        PSSpecifier *vClear = [PSSpecifier preferenceSpecifierNamed:@"清除视频" target:self
            set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        vClear.buttonAction = @selector(clearVideo);
        [vClear setProperty:@YES forKey:@"enabled"];
        [s addObject:vClear];

        // ---- Group: motion tuning ----
        PSSpecifier *grp3 = [PSSpecifier preferenceSpecifierNamed:@"动态效果" target:self
            set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [grp3 setProperty:@"灵敏度决定切换照片所需的倾斜幅度；视差可增强层次感；平滑度可让动画更加柔顺。" forKey:@"footerText"];
        [s addObject:grp3];

        [s addObject:[self sliderNamed:@"灵敏度" key:kVVSKeySensitivity def:0.5]];
        [s addObject:[self sliderNamed:@"视差强度" key:kVVSKeyParallax def:0.6]];
        [s addObject:[self sliderNamed:@"平滑度" key:kVVSKeySmoothing def:0.5]];

        PSSpecifier *loop = [PSSpecifier preferenceSpecifierNamed:@"循环切换" target:self
            set:@selector(setPref:forSpecifier:) get:@selector(readPref:) detail:Nil cell:PSSwitchCell edit:Nil];
        [loop setProperty:kVVSKeyLoop forKey:@"key"];
        [loop setProperty:kVVSPrefsSuite forKey:@"defaults"];
        [loop setProperty:@NO forKey:@"default"];
        [s addObject:loop];

        // ---- Group: transition style ----
        PSSpecifier *grpT = [PSSpecifier preferenceSpecifierNamed:@"过渡效果" target:self
            set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [grpT setProperty:@"vivo 风格光栅过渡：渐隐渐显为柔和溶解；棱镜光栅通过竖向光栅条展开下一张；磨砂玻璃通过模糊玻璃切换；景深模拟焦点变化。" forKey:@"footerText"];
        [s addObject:grpT];

        PSSpecifier *trans = [PSSpecifier preferenceSpecifierNamed:[self transitionLabel] target:self
            set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        [trans setProperty:@"transCell" forKey:@"id"];
        [trans setProperty:@YES forKey:@"enabled"];
        trans.buttonAction = @selector(pickTransition);
        [s addObject:trans];

        // ---- Group: framing ----
        PSSpecifier *grp5 = [PSSpecifier preferenceSpecifierNamed:@"壁纸尺寸" target:self
            set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [grp5 setProperty:@"关闭（原始比例）：居中显示完整照片，并用模糊背景填充边缘。\n开启（填充屏幕）：放大照片铺满屏幕，裁剪边缘但不会拉伸。" forKey:@"footerText"];
        [s addObject:grp5];

        PSSpecifier *mode = [PSSpecifier preferenceSpecifierNamed:@"填充屏幕" target:self
            set:@selector(setPref:forSpecifier:) get:@selector(readPref:) detail:Nil cell:PSSwitchCell edit:Nil];
        [mode setProperty:kVVSKeyFill forKey:@"key"];
        [mode setProperty:kVVSPrefsSuite forKey:@"defaults"];
        [mode setProperty:@NO forKey:@"default"];
        [s addObject:mode];

        // ---- Group: apply ----
        PSSpecifier *grp4 = [PSSpecifier preferenceSpecifierNamed:@"" target:self
            set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [s addObject:grp4];
        PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:@"应用并重启桌面" target:self
            set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        respring.buttonAction = @selector(respring);
        [s addObject:respring];

        _specifiers = s;
    }
    return _specifiers;
}

#pragma mark - Helpers

- (PSSpecifier *)sliderNamed:(NSString *)name key:(NSString *)key def:(float)def {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPref:forSpecifier:) get:@selector(readPref:) detail:Nil cell:PSSliderCell edit:Nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kVVSPrefsSuite forKey:@"defaults"];
    [sp setProperty:@(def) forKey:@"default"];
    [sp setProperty:@0.0 forKey:@"min"];
    [sp setProperty:@1.0 forKey:@"max"];
    [sp setProperty:@kVVSReloadNotification forKey:@"PostNotification"];
    return sp;
}

- (NSArray<NSString *> *)transitionNames {
    return @[@"渐隐渐显", @"棱镜光栅", @"磨砂玻璃", @"景深"];
}

- (NSString *)transitionLabel {
    NSInteger i = [[self defaults] integerForKey:kVVSKeyTransition];
    if (i < 0 || i >= (NSInteger)self.transitionNames.count) i = 0;
    return [NSString stringWithFormat:@"过渡效果：%@", self.transitionNames[i]];
}

- (void)pickTransition {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"过渡效果"
        message:@"选择倾斜手机时的照片切换方式" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *names = self.transitionNames;
    NSInteger current = [[self defaults] integerForKey:kVVSKeyTransition];
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        NSString *title = (i == current) ? [NSString stringWithFormat:@"✓ %@", names[i]] : names[i];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                [[self defaults] setInteger:i forKey:kVVSKeyTransition];
                CFPreferencesAppSynchronize(kVVSPrefsAppID);
                [self postReload];
                [self reloadSpecifiers];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // iPad / popover anchor
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)countLabel {
    NSInteger n = [[self defaults] integerForKey:kVVSKeyImageCount];
    return [NSString stringWithFormat:@"已选择：%ld 张照片", (long)n];
}

- (NSUserDefaults *)defaults {
    return [[NSUserDefaults alloc] initWithSuiteName:kVVSPrefsSuite];
}

#pragma mark - Generic get/set bound to our suite (+ live reload)

- (id)readPref:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id v = [[self defaults] objectForKey:key];
    return v ?: [specifier propertyForKey:@"default"];
}

- (void)setPref:(id)value forSpecifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    [[self defaults] setObject:value forKey:key];
    CFPreferencesAppSynchronize(kVVSPrefsAppID);
    [self postReload];
}

- (void)postReload {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVVSReloadNotification), NULL, NULL, YES);
}

#pragma mark - Photo picking

- (void)pickPhotos {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 0;                       // unlimited (vivo defaults to 4)
    cfg.filter = [PHPickerFilter imagesFilter];
    if (@available(iOS 15.0, *)) cfg.selection = PHPickerConfigurationSelectionOrdered;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (self.pickingVideo) { self.pickingVideo = NO; [self importVideo:results]; return; }
    if (results.count == 0) return;

    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"正在导入…"
        message:@"正在保存照片。" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:nil];

    NSMutableArray *images = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)results.count; i++) [images addObject:[NSNull null]];

    dispatch_group_t group = dispatch_group_create();
    for (NSInteger i = 0; i < (NSInteger)results.count; i++) {
        PHPickerResult *r = results[i];
        if (![r.itemProvider canLoadObjectOfClass:[UIImage class]]) continue;
        dispatch_group_enter(group);
        [r.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *image, NSError *error) {
            if (image) {
                @synchronized (images) { images[i] = image; }
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSInteger saved = [self writeImages:images];
        [[self defaults] setInteger:saved forKey:kVVSKeyImageCount];
        CFPreferencesAppSynchronize(kVVSPrefsAppID);
        [self postReload];
        [hud dismissViewControllerAnimated:YES completion:^{
            [self reloadSpecifiers];
        }];
    });
}

// Returns number of images actually written (in selection order, compacted).
- (NSInteger)writeImages:(NSArray *)images {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = VVSImagesDirectory();
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSInteger idx = 0;
    for (id obj in images) {
        if (![obj isKindOfClass:[UIImage class]]) continue;
        UIImage *down = [self downscale:(UIImage *)obj maxDim:1800.0];
        NSData *data = UIImageJPEGRepresentation(down, 0.9);
        if (!data) continue;
        [data writeToFile:VVSImagePathAtIndex(idx) atomically:YES];
        idx++;
    }
    return idx;
}

- (UIImage *)downscale:(UIImage *)image maxDim:(CGFloat)maxDim {
    CGSize sz = image.size;
    CGFloat m = MAX(sz.width, sz.height);
    if (m <= maxDim) return image;
    CGFloat scale = maxDim / m;
    CGSize newSize = CGSizeMake(floor(sz.width * scale), floor(sz.height * scale));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:newSize format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    }];
}

#pragma mark - Video picking

- (NSString *)videoStatusLabel {
    BOOL has = [[self defaults] boolForKey:kVVSKeyHasVideo] &&
               [[NSFileManager defaultManager] fileExistsAtPath:VVSVideoPath()];
    return has ? @"视频：已选择 ✓" : @"视频：未选择";
}

- (void)pickVideo {
    self.pickingVideo = YES;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 1;
    cfg.filter = [PHPickerFilter videosFilter];
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importVideo:(NSArray<PHPickerResult *> *)results {
    if (results.count == 0) return;
    PHPickerResult *r = results.firstObject;

    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"正在导入…"
        message:@"正在保存视频。" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:nil];

    [r.itemProvider loadFileRepresentationForTypeIdentifier:@"public.movie"
        completionHandler:^(NSURL *url, NSError *error) {
        BOOL ok = NO;
        if (url) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/VivoStyle"];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *dst = VVSVideoPath();
            [fm removeItemAtPath:dst error:nil];
            ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[self defaults] setBool:ok forKey:kVVSKeyHasVideo];
            if (ok) [[self defaults] setBool:YES forKey:kVVSKeyVideoEnabled];   // auto-enable
            CFPreferencesAppSynchronize(kVVSPrefsAppID);
            [self postReload];
            [hud dismissViewControllerAnimated:YES completion:^{ [self reloadSpecifiers]; }];
        });
    }];
}

- (void)clearVideo {
    [[NSFileManager defaultManager] removeItemAtPath:VVSVideoPath() error:nil];
    [[self defaults] setBool:NO forKey:kVVSKeyHasVideo];
    [[self defaults] setBool:NO forKey:kVVSKeyVideoEnabled];
    CFPreferencesAppSynchronize(kVVSPrefsAppID);
    [self postReload];
    [self reloadSpecifiers];
}

- (void)clearPhotos {
    [[NSFileManager defaultManager] removeItemAtPath:VVSImagesDirectory() error:nil];
    [[self defaults] setInteger:0 forKey:kVVSKeyImageCount];
    CFPreferencesAppSynchronize(kVVSPrefsAppID);
    [self postReload];
    [self reloadSpecifiers];
}

- (void)respring {
    [self postReload];
    NSFileManager *fm = [NSFileManager defaultManager];
    pid_t pid;
    // jbroot() resolves the bootstrap prefix at runtime: /var/jb on rootless,
    // the randomized /var/containers/Bundle/Application/.jbroot-XXXX on RootHide.
    NSString *sbreload = jbroot(@"/usr/bin/sbreload");
    if ([fm fileExistsAtPath:sbreload]) {
        const char *argv[] = { sbreload.fileSystemRepresentation, NULL };
        posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
    } else {
        const char *killall = jbroot("/usr/bin/killall");
        const char *argv[] = { killall, "-9", "SpringBoard", NULL };
        posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
    }
}

@end

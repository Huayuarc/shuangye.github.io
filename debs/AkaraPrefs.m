#import "AkaraPrefs.h"
#import "AkaraCommon.h"
#import <Preferences/PSControlTableCell.h>
#import <QuartzCore/QuartzCore.h>
#import <spawn.h>

extern char **environ;

static void AKRRunCommand(NSString *path, NSArray<NSString *> *arguments) {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        return;
    }

    NSMutableArray<NSString *> *allArguments = [NSMutableArray arrayWithObject:path];
    if (arguments) {
        [allArguments addObjectsFromArray:arguments];
    }

    NSUInteger count = allArguments.count;
    char **argv = calloc(count + 1, sizeof(char *));
    if (!argv) {
        return;
    }

    for (NSUInteger index = 0; index < count; index++) {
        argv[index] = strdup(allArguments[index].UTF8String);
    }
    argv[count] = NULL;

    pid_t pid = 0;
    posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, environ);

    for (NSUInteger index = 0; index < count; index++) {
        free(argv[index]);
    }
    free(argv);
}

static UIImage *AKRBundleImage(NSString *name) {
    NSBundle *bundle = [NSBundle bundleForClass:AKRRootListController.class];
    NSString *path = [bundle pathForResource:name ofType:nil];
    return path ? [UIImage imageWithContentsOfFile:path] : nil;
}

@interface AKRRootListController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@interface AKRImageChooseCell : PSTableCell
@end

@implementation AKRImageChooseCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}
@end

@implementation AKRRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Akara";

    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithTitle:@"应用" style:UIBarButtonItemStyleDone target:self action:@selector(respring)];
    self.navigationItem.rightBarButtonItem = applyButton;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Register defaults if not already set
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AKRPrefsDomain];
    [defaults registerDefaults:@{
        @"akaraTweakEnabled": @YES,
        @"akaraUseLargeMode": @NO,
        @"akaraUseSEMode": @NO,
        @"akaraUseBackgroundBlur": @YES,
        @"akaraUseBackgroundImage": @NO,
        @"akaraUseCustomCornerRadius": @NO,
        @"akaraCustomCornerRadius": @38.0,
        @"akaraUseCustomMaterialViewAlpha": @NO,
        @"akaraCustomMaterialViewAlpha": @1.0,
        @"akaraUseStaticWifiIcon": @NO,
        @"akaraUseStaticBluetoothIcon": @NO,
        @"akaraUseStaticBrightnessSliderIcon": @NO,
        @"akaraUseStaticVolumeSliderIcon": @NO,
        @"akaraUseNativeConnectivityLabels": @YES,
        @"akaraShowMediaRadioButton": @NO,
        @"akaraShowStatusBar": @NO,
        @"akaraShowNotchStatusBar": @NO,
        @"akaraEnableTopRightGesture": @NO,
        @"akaraEnableTopRightAndBottomGesture": @NO,
        @"akaraEaseLockScreenGesture": @NO,
        @"akaraDisableInLandscapeMode": @NO,
        @"akaraScrollBackToFirstConnectivityPage": @NO,
        @"akaraBackgroundBlurStyle": @2,
        @"akaraCustomSliderHeight": @2.0,
        @"akaraCustomMediaWidth": @2.0,
        @"akaraCustomMediaHeight": @2.0,
        @"akaraConnectivityFirstRowOrder": @"123",
        @"akaraConnectivitySecondRowOrder": @"456"
    }];
    [defaults synchronize];
}

- (void)respring {
    [self.view endEditing:YES];
    AKRPostPrefsChanged();
    AKRRunCommand(@"/var/jb/usr/bin/sbreload", @[]);
    AKRRunCommand(@"/usr/bin/sbreload", @[]);
}

- (void)chooseImage {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        return;
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    picker.allowsEditing = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *image = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
    if (image) {
        NSString *directory = AKRMobilePath(@"Library/Application Support/Akara");
        NSString *path = [directory stringByAppendingPathComponent:@"background.jpg"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        [UIImageJPEGRepresentation(image, 0.92) writeToFile:path atomically:YES];

        NSMutableDictionary *preferences = [NSMutableDictionary dictionaryWithContentsOfFile:AKRPrefsPathForDomain(AKRPrefsDomain)] ?: [NSMutableDictionary dictionary];
        preferences[@"akaraBackgroundImage"] = path;
        [preferences writeToFile:AKRPrefsPathForDomain(AKRPrefsDomain) atomically:YES];
        AKRPostPrefsChanged();
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)resetLayoutToDefault {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置布局" message:@"确定要将模块布局重置为默认值吗？" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self copyDefaultLayoutFiles];
        [self respring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetPreferencesToDefault {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置偏好" message:@"确定要将偏好选项重置为默认值吗？" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[NSFileManager defaultManager] removeItemAtPath:AKRPrefsPathForDomain(AKRPrefsDomain) error:nil];
        AKRPostPrefsChanged();
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyDefaultLayoutFiles {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *supportPath = AKRPathInPrefix(@"/Library/Application Support/Akara");
    NSDictionary<NSString *, NSString *> *copies = @{
        [supportPath stringByAppendingPathComponent:@"ModuleConfiguration_Akara.plist"]: AKRMobilePath(@"Library/ControlCenter/ModuleConfiguration_Akara.plist"),
        [supportPath stringByAppendingPathComponent:@"com.huayuarc.akara.providedakaramodule.0.plist"]: AKRMobilePath(@"Library/Preferences/com.huayuarc.akara.providedakaramodule.0.plist"),
        [supportPath stringByAppendingPathComponent:@"com.huayuarc.akara.providedakaramodule.1.plist"]: AKRMobilePath(@"Library/Preferences/com.huayuarc.akara.providedakaramodule.1.plist"),
        [supportPath stringByAppendingPathComponent:@"com.huayuarc.akara.providedakaraverticalmodule.0.plist"]: AKRMobilePath(@"Library/Preferences/com.huayuarc.akara.providedakaraverticalmodule.0.plist")
    };

    [copies enumerateKeysAndObjectsUsingBlock:^(NSString *source, NSString *destination, __unused BOOL *stop) {
        [fileManager createDirectoryAtPath:[destination stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [fileManager removeItemAtPath:destination error:nil];
        [fileManager copyItemAtPath:source toPath:destination error:nil];
    }];
}

@end

@implementation AKRLabeledSliderCell {
    UILabel *_valueLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];
        [self updateValueLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _valueLabel.frame = CGRectMake(CGRectGetWidth(self.contentView.bounds) - 84.0, 8.0, 68.0, 22.0);
    [self updateValueLabel];
}

- (void)controlChanged:(UIControl *)control {
    [super controlChanged:control];
    [self updateValueLabel];
}

- (void)setValue:(id)value {
    [super setValue:value];
    [self updateValueLabel];
}

- (void)updateValueLabel {
    id value = [(PSControlTableCell *)self value];
    if (!value && [self respondsToSelector:@selector(control)]) {
        UIControl *control = [(PSControlTableCell *)self control];
        if ([control isKindOfClass:UISlider.class]) {
            value = @([(UISlider *)control value]);
        } else if ([control isKindOfClass:UIStepper.class]) {
            value = @([(UIStepper *)control value]);
        }
    }
    if ([value respondsToSelector:@selector(floatValue)]) {
        CGFloat numericValue = [value floatValue];
        _valueLabel.text = fabs(numericValue - round(numericValue)) < 0.01 ? [NSString stringWithFormat:@"%.0f", numericValue] : [NSString stringWithFormat:@"%.2f", numericValue];
    } else {
        _valueLabel.text = @"";
    }
}

@end

@implementation AKRTableCell

- (void)layoutSubviews {
    [super layoutSubviews];
    self.backgroundColor = UIColor.clearColor;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
}

@end

@implementation AKRLinkCell {
    BOOL _isBig;
    UIView *_avatarView;
    UIImageView *_avatarImageView;
    UIImage *_avatarImage;
}
@synthesize avatarImage = _avatarImage;

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _isBig = [[specifier propertyForKey:@"isBig"] boolValue];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (UIView *)avatarView {
    if (!_avatarView) {
        _avatarView = [[UIView alloc] initWithFrame:CGRectZero];
        _avatarView.backgroundColor = UIColor.clearColor;
        _avatarView.layer.cornerRadius = self.isBig ? 28.0 : 18.0;
        _avatarView.clipsToBounds = YES;
        [_avatarView addSubview:self.avatarImageView];
        [self.contentView addSubview:_avatarView];
    }
    return _avatarView;
}

- (UIImageView *)avatarImageView {
    if (!_avatarImageView) {
        _avatarImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
    }
    return _avatarImageView;
}

- (BOOL)isBig {
    return _isBig;
}

- (BOOL)shouldShowAvatar {
    return YES;
}

- (void)setAvatarImage:(UIImage *)avatarImage {
    if (_avatarImage != avatarImage) {
        _avatarImage = avatarImage;
        self.avatarImageView.image = _avatarImage;
    }
}

- (void)loadAvatarIfNeeded {
    NSString *iconName = [self.specifier propertyForKey:@"iconName"];
    if (!self.avatarImage && iconName.length > 0) {
        self.avatarImage = AKRBundleImage(iconName);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (![self shouldShowAvatar]) {
        return;
    }
    [self loadAvatarIfNeeded];
    CGFloat size = self.isBig ? 56.0 : 36.0;
    self.avatarView.frame = CGRectMake(16.0, floor((CGRectGetHeight(self.contentView.bounds) - size) / 2.0), size, size);
    self.avatarImageView.frame = self.avatarView.bounds;
}

@end

@implementation AKRHeaderCell
@synthesize titleLabel = _titleLabel;
@synthesize subtitleLabel = _subtitleLabel;
@synthesize iconView = _iconView;
@synthesize containerStackView = _containerStackView;
@synthesize backgroundView = _backgroundView;

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        [self setupWithSpecifier:specifier];
    }
    return self;
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil specifier:specifier];
    if (self) {
        [self setupWithSpecifier:specifier];
    }
    return self;
}

- (void)setupWithSpecifier:(PSSpecifier *)specifier {
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;

    self.backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
    self.backgroundView.backgroundColor = UIColor.clearColor;

    self.iconView = [[UIImageView alloc] initWithImage:AKRBundleImage([specifier propertyForKey:@"iconPath"] ? [[specifier propertyForKey:@"iconPath"] lastPathComponent] : @"akara.png")];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = [specifier propertyForKey:@"title"] ?: @"Akara";
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont systemFontOfSize:36.0 weight:UIFontWeightBold];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.subtitleLabel.text = [specifier propertyForKey:@"subtitle"] ?: @"极简设计，毫不妥协";
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.textColor = UIColor.secondaryLabelColor;
    self.subtitleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];

    self.containerStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.iconView, self.titleLabel, self.subtitleLabel]];
    self.containerStackView.axis = UILayoutConstraintAxisVertical;
    self.containerStackView.alignment = UIStackViewAlignmentCenter;
    self.containerStackView.spacing = 4.0;
    [self.contentView addSubview:self.containerStackView];
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return 150.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.containerStackView.frame = CGRectInset(self.contentView.bounds, 16.0, 12.0);
    self.iconView.bounds = CGRectMake(0.0, 0.0, 50.0, 50.0);
}

@end

@implementation AKRDuoTwitterCell {
    NSString *_user;
    NSString *_user2;
    UILabel *_leftLabel;
    UILabel *_rightLabel;
    UIImageView *_leftImageView;
    UIImageView *_rightImageView;
}

+ (instancetype)cellWithSpecifier:(PSSpecifier *)specifier {
    return [[self alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AKRDuoTwitterCell" specifier:specifier];
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _user = [specifier propertyForKey:@"firstAccount"] ?: @"FectaTr1";
        _user2 = [specifier propertyForKey:@"secondAccount"] ?: @"_Kennyroo";
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _leftLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _leftLabel.text = [specifier propertyForKey:@"firstLabel"] ?: @"Tr1Fecta";
        _leftLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _leftLabel.textAlignment = NSTextAlignmentCenter;

        _rightLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _rightLabel.text = [specifier propertyForKey:@"secondLabel"] ?: @"Kennyroo ☾";
        _rightLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _rightLabel.textAlignment = NSTextAlignmentCenter;

        _leftImageView = [[UIImageView alloc] initWithImage:AKRBundleImage(@"FectaTr1.png")];
        _rightImageView = [[UIImageView alloc] initWithImage:AKRBundleImage(@"_Kennyroo.png")];
        for (UIImageView *imageView in @[_leftImageView, _rightImageView]) {
            imageView.contentMode = UIViewContentModeScaleAspectFill;
            imageView.clipsToBounds = YES;
            imageView.layer.cornerRadius = 18.0;
        }

        [self.contentView addSubview:_leftImageView];
        [self.contentView addSubview:_rightImageView];
        [self.contentView addSubview:_leftLabel];
        [self.contentView addSubview:_rightLabel];

        UITapGestureRecognizer *leftTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleLeftTap:)];
        UITapGestureRecognizer *rightTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleRightTap:)];
        _leftLabel.userInteractionEnabled = YES;
        _rightLabel.userInteractionEnabled = YES;
        [_leftLabel addGestureRecognizer:leftTap];
        [_rightLabel addGestureRecognizer:rightTap];
        [_leftImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleLeftTap:)]];
        [_rightImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleRightTap:)]];
        _leftImageView.userInteractionEnabled = YES;
        _rightImageView.userInteractionEnabled = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds) / 2.0;
    _leftImageView.frame = CGRectMake(width / 2.0 - 18.0, 6.0, 36.0, 36.0);
    _rightImageView.frame = CGRectMake(width + width / 2.0 - 18.0, 6.0, 36.0, 36.0);
    _leftLabel.frame = CGRectMake(0.0, 39.0, width, 18.0);
    _rightLabel.frame = CGRectMake(width, 39.0, width, 18.0);
}

- (void)handleLeftTap:(UITapGestureRecognizer *)gestureRecognizer {
    [self openTwitterUser:_user];
}

- (void)handleRightTap:(UITapGestureRecognizer *)gestureRecognizer {
    [self openTwitterUser:_user2];
}

- (void)openTwitterUser:(NSString *)user {
    NSString *cleanUser = [user stringByReplacingOccurrencesOfString:@"@" withString:@""];
    NSURL *appURL = [NSURL URLWithString:[NSString stringWithFormat:@"twitter://user?screen_name=%@", cleanUser]];
    NSURL *webURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://twitter.com/%@", cleanUser]];
    UIApplication *application = UIApplication.sharedApplication;
    if ([application canOpenURL:appURL]) {
        [application openURL:appURL options:@{} completionHandler:nil];
    } else {
        [application openURL:webURL options:@{} completionHandler:nil];
    }
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:NO animated:animated];
}

- (BOOL)canBecomeFirstResponder {
    return NO;
}

@end

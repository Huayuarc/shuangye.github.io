#import "PM16Base.h"
#import <PhotosUI/PhotosUI.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *PM16S(const char *s) { return [NSString stringWithUTF8String:s]; }
static NSString *PM16Root(void) {
    NSString *root = PM16S("/var/mobile/Library/PictureModule");
    NSString *jb = PM16S("/var/jb/var/mobile/Library/PictureModule");
    if ([[NSFileManager defaultManager] fileExistsAtPath:PM16S("/var/jb")]) root = jb;
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}
static NSString *PM16Prefs(NSInteger slot) { return [PM16S("com.huayuarc.picturemodule16.") stringByAppendingFormat:PM16S("%ld"),(long)slot]; }
static NSString *PM16File(NSInteger slot, NSString *ext) { return [PM16Root() stringByAppendingPathComponent:[PM16S("slot-") stringByAppendingFormat:PM16S("%ld.%@"),(long)slot,ext]]; }

@interface PM16ViewController : UIViewController <CCUIContentModuleContentViewController,PHPickerViewControllerDelegate>
@property NSInteger slot;
@property UIImageView *imageView;
@property AVPlayer *player;
@property AVPlayerLayer *playerLayer;
@property UILabel *emptyLabel;
@property UILabel *titleLabel;
@property UIButton *chooseButton;
@property UIButton *modeButton;
@property UIButton *opacityButton;
@end

@implementation PM16ViewController
- (instancetype)initWithSlot:(NSInteger)slot { if ((self=[super init])) _slot=slot; return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=[UIColor secondarySystemBackgroundColor]; self.view.clipsToBounds=YES;
    self.view.layer.cornerRadius=18; self.view.layer.cornerCurve=kCACornerCurveContinuous;
    _imageView=[[UIImageView alloc] initWithFrame:self.view.bounds]; _imageView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; _imageView.clipsToBounds=YES; [self.view addSubview:_imageView];
    _playerLayer=[AVPlayerLayer layer]; _playerLayer.frame=self.view.bounds; [self.view.layer addSublayer:_playerLayer];
    UIBlurEffect *blur=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]; UIVisualEffectView *bar=[[UIVisualEffectView alloc] initWithEffect:blur]; bar.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:bar];
    UIStackView *stack=[[UIStackView alloc] init]; stack.axis=UILayoutConstraintAxisHorizontal; stack.spacing=8; stack.alignment=UIStackViewAlignmentCenter; stack.translatesAutoresizingMaskIntoConstraints=NO; [bar.contentView addSubview:stack];
    _titleLabel=[[UILabel alloc] init]; _titleLabel.text=[PM16S("图片 ") stringByAppendingFormat:PM16S("%ld"),(long)_slot]; _titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; [_titleLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    _chooseButton=[self button:PM16S("选择") action:@selector(choose:)]; _modeButton=[self button:PM16S("显示") action:@selector(changeMode:)]; _opacityButton=[self button:PM16S("透明") action:@selector(changeOpacity:)];
    [stack addArrangedSubview:_titleLabel]; [stack addArrangedSubview:_modeButton]; [stack addArrangedSubview:_opacityButton]; [stack addArrangedSubview:_chooseButton];
    _emptyLabel=[[UILabel alloc] init]; _emptyLabel.text=PM16S("长按展开后选择图片或视频"); _emptyLabel.textAlignment=NSTextAlignmentCenter; _emptyLabel.textColor=[UIColor secondaryLabelColor]; _emptyLabel.numberOfLines=2; _emptyLabel.translatesAutoresizingMaskIntoConstraints=NO; [self.view insertSubview:_emptyLabel belowSubview:bar];
    [NSLayoutConstraint activateConstraints:@[[bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[bar.heightAnchor constraintEqualToConstant:52],[stack.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor constant:12],[stack.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor constant:-12],[stack.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],[_emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[_emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],[_emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:15],[_emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-15]]];
    [self reloadMedia];
}
- (UIButton *)button:(NSString *)title action:(SEL)action { UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:title forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return b; }
- (NSDictionary *)prefs { return [[NSUserDefaults alloc] initWithSuiteName:PM16Prefs(_slot)].dictionaryRepresentation; }
- (void)setPref:(id)value key:(NSString *)key { NSUserDefaults *d=[[NSUserDefaults alloc] initWithSuiteName:PM16Prefs(_slot)]; [d setObject:value forKey:key]; [d synchronize]; [self applyAppearance]; }
- (void)applyAppearance {
    NSDictionary *p=[self prefs]; NSInteger mode=[p[PM16S("contentMode")] integerValue]; if (!mode) mode=1;
    _imageView.contentMode=mode==1?UIViewContentModeScaleAspectFill:(mode==2?UIViewContentModeScaleAspectFit:UIViewContentModeScaleToFill);
    _playerLayer.videoGravity=mode==1?AVLayerVideoGravityResizeAspectFill:(mode==2?AVLayerVideoGravityResizeAspect:AVLayerVideoGravityResize);
    NSNumber *op=p[PM16S("opacity")]; CGFloat a=op?op.doubleValue/100.0:1; _imageView.alpha=a; _playerLayer.opacity=a;
}
- (void)reloadMedia {
    [_player pause]; _player=nil; _playerLayer.player=nil; _imageView.image=nil;
    NSString *kind=[self prefs][PM16S("kind")]; NSString *path=[kind isEqualToString:PM16S("video")]?PM16File(_slot,PM16S("mp4")):PM16File(_slot,PM16S("img"));
    if ([kind isEqualToString:PM16S("video")] && [[NSFileManager defaultManager] fileExistsAtPath:path]) { _player=[AVPlayer playerWithURL:[NSURL fileURLWithPath:path]]; _player.actionAtItemEnd=AVPlayerActionAtItemEndNone; _player.muted=YES; _playerLayer.player=_player; [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loop:) name:AVPlayerItemDidPlayToEndTimeNotification object:_player.currentItem]; [_player play]; _emptyLabel.hidden=YES; }
    else { NSData *data=[NSData dataWithContentsOfFile:path]; _imageView.image=[UIImage imageWithData:data]; _emptyLabel.hidden=(_imageView.image!=nil); }
    [self applyAppearance];
}
- (void)loop:(NSNotification *)n { [_player seekToTime:kCMTimeZero]; [_player play]; }
- (void)choose:(id)sender {
    PHPickerConfiguration *c=[[PHPickerConfiguration alloc] initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]]; c.selectionLimit=1; c.filter=[PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter],[PHPickerFilter videosFilter]]];
    PHPickerViewController *p=[[PHPickerViewController alloc] initWithConfiguration:c]; p.delegate=self; [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil]; NSItemProvider *provider=results.firstObject.itemProvider; if (!provider) return;
    if ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) [provider loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSData *data,NSError *e){ if (!data) return; [data writeToFile:PM16File(self.slot,PM16S("img")) atomically:YES]; NSUserDefaults *d=[[NSUserDefaults alloc] initWithSuiteName:PM16Prefs(self.slot)]; [d setObject:PM16S("image") forKey:PM16S("kind")]; [d synchronize]; dispatch_async(dispatch_get_main_queue(),^{[self reloadMedia];}); }];
    else if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url,NSError *e){ if (!url) return; NSString *dst=PM16File(self.slot,PM16S("mp4")); [[NSFileManager defaultManager] removeItemAtPath:dst error:nil]; [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil]; NSUserDefaults *d=[[NSUserDefaults alloc] initWithSuiteName:PM16Prefs(self.slot)]; [d setObject:PM16S("video") forKey:PM16S("kind")]; [d synchronize]; dispatch_async(dispatch_get_main_queue(),^{[self reloadMedia];}); }];
}
- (void)changeMode:(id)sender { NSInteger m=[self.prefs[PM16S("contentMode")] integerValue]; m=m%3+1; [self setPref:@(m) key:PM16S("contentMode")]; NSArray *a=@[PM16S(""),PM16S("裁切"),PM16S("适应"),PM16S("拉伸")]; [_modeButton setTitle:a[m] forState:UIControlStateNormal]; }
- (void)changeOpacity:(id)sender { NSInteger o=[self.prefs[PM16S("opacity")] integerValue]; if (!o) o=100; o=(o<=25)?100:o-25; [self setPref:@(o) key:PM16S("opacity")]; [_opacityButton setTitle:[PM16S("") stringByAppendingFormat:PM16S("%ld%%"),(long)o] forState:UIControlStateNormal]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; _playerLayer.frame=self.view.bounds; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadMedia]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [_player pause]; }
- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (CGFloat)preferredExpandedContentHeight { return 300; }
- (CGFloat)preferredExpandedContentWidth { return MIN(UIScreen.mainScreen.bounds.size.width-30,380); }
- (BOOL)providesOwnPlatter { return NO; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated { [self reloadMedia]; }
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

@implementation PM16Module { PM16ViewController *_controller; }
- (instancetype)initWithSlot:(NSInteger)slot { if ((self=[super init])) _controller=[[PM16ViewController alloc] initWithSlot:slot]; return self; }
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController { return _controller; }
- (UIViewController *)backgroundViewController { return nil; }
@end

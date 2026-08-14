#import "PMOriginal.h"
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <notify.h>
#import "PMPaths.h"

static NSString *Root(void){PMPrepareAndMigrate();return PMDataRoot();}
static NSInteger Slot(NSString *identifier){NSString *tail=[identifier componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"._"]].lastObject;NSInteger n=tail.integerValue;return MAX(1,MIN(5,n));}
static NSString *LegacyID(NSInteger n){return [NSString stringWithFormat:@"com.4nni3.picturemodule_%ld",(long)n];}
static NSString *ImagePath(NSInteger n){NSArray *a=@[[NSString stringWithFormat:@"%@_img.dat",LegacyID(n)],[NSString stringWithFormat:@"slot-%ld.img",(long)n],[NSString stringWithFormat:@"%@.jpg",LegacyID(n)]];for(NSString *x in a){NSString *p=[Root() stringByAppendingPathComponent:x];if([[NSFileManager defaultManager] fileExistsAtPath:p])return p;}return [Root() stringByAppendingPathComponent:a[0]];}
static NSString *VideoPath(NSInteger n){return [Root() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_video.mp4",LegacyID(n)]];}
static NSDictionary *Prefs(NSString *identifier){PMPrepareAndMigrate();NSInteger n=Slot(identifier);NSString *transition=[NSString stringWithFormat:@"com.huayuarc.picturemodule16.%ld",(long)n];NSMutableDictionary *m=[NSMutableDictionary dictionaryWithDictionary:PMReadDomain(transition)];[m addEntriesFromDictionary:PMReadDomain(LegacyID(n))];[m addEntriesFromDictionary:PMReadDomain(identifier)];return m;}

@interface PMPlayerView:UIView
@property(nonatomic,strong) AVPlayer *player;
@end
@implementation PMPlayerView
+ (Class)layerClass{return AVPlayerLayer.class;}
- (AVPlayerLayer *)playerLayer{return (AVPlayerLayer *)self.layer;}
- (void)setPlayer:(AVPlayer *)p{_player=p;self.playerLayer.player=p;}
@end

@interface PMOriginalContentViewController:UIViewController<CCUIContentModuleContentViewController,UIScrollViewDelegate>
@property(nonatomic,strong) NSString *identifier;@property(nonatomic,strong) UIScrollView *scrollView;@property(nonatomic,strong) UIView *mediaView;@property(nonatomic,strong) UIImageView *backdropView;@property(nonatomic,strong) UIVisualEffectView *blurView;@property(nonatomic,strong) UILabel *labelView;@property(nonatomic,strong) AVPlayer *player;@property BOOL expanded;@property int notifyToken;@property int prefsNotifyToken;
@end
@implementation PMOriginalContentViewController
- (instancetype)initWithIdentifier:(NSString *)i{if((self=[super init]))_identifier=i;return self;}
- (void)viewDidLoad{[super viewDidLoad];self.view.clipsToBounds=YES;self.view.backgroundColor=UIColor.clearColor;_scrollView=[[UIScrollView alloc]initWithFrame:self.view.bounds];_scrollView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;_scrollView.delegate=self;_scrollView.minimumZoomScale=1;_scrollView.maximumZoomScale=4;_scrollView.showsHorizontalScrollIndicator=NO;_scrollView.showsVerticalScrollIndicator=NO;[self.view addSubview:_scrollView];_labelView=[[UILabel alloc]init];_labelView.textColor=UIColor.whiteColor;_labelView.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];_labelView.layer.shadowOpacity=.6;_labelView.layer.shadowRadius=2;[self.view addSubview:_labelView];UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(doubleTap:)];tap.numberOfTapsRequired=2;[_scrollView addGestureRecognizer:tap];__weak typeof(self) weakSelf=self;NSString *event=[_identifier stringByAppendingString:@"/updatePicture"];notify_register_dispatch(event.UTF8String,&_notifyToken,dispatch_get_main_queue(),^(int token){[weakSelf reloadPicture];});notify_register_dispatch(_identifier.UTF8String,&_prefsNotifyToken,dispatch_get_main_queue(),^(int token){[weakSelf reloadPicture];});[self reloadPicture];}
- (void)unloadPicture{[_player pause];_player=nil;[_mediaView removeFromSuperview];_mediaView=nil;[_blurView removeFromSuperview];_blurView=nil;[_backdropView removeFromSuperview];_backdropView=nil;}
- (void)reloadPicture{[self unloadPicture];NSDictionary *p=Prefs(_identifier);NSInteger n=Slot(_identifier);NSString *type=p[@"type"];
 if([type isEqual:@"video"]||[[NSFileManager defaultManager]fileExistsAtPath:VideoPath(n)]){PMPlayerView *v=[[PMPlayerView alloc]init];_player=[AVPlayer playerWithURL:[NSURL fileURLWithPath:VideoPath(n)]];v.player=_player;_player.actionAtItemEnd=AVPlayerActionAtItemEndNone;_player.muted=![p[@"Sound"] boolValue];[[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(loop:) name:AVPlayerItemDidPlayToEndTimeNotification object:_player.currentItem];_mediaView=v;[_player play];}
 else{UIImageView *v=[[UIImageView alloc]init];v.image=[UIImage imageWithContentsOfFile:ImagePath(n)];NSInteger mode=[p[@"contentMode"]integerValue];if(mode==2&&v.image){_backdropView=[[UIImageView alloc]initWithImage:v.image];_backdropView.contentMode=UIViewContentModeScaleAspectFill;_backdropView.clipsToBounds=YES;[_scrollView addSubview:_backdropView];UIBlurEffect *effect=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];_blurView=[[UIVisualEffectView alloc]initWithEffect:effect];_blurView.userInteractionEnabled=NO;[_scrollView addSubview:_blurView];}_mediaView=v;}
 [_scrollView addSubview:_mediaView];_labelView.text=p[@"Label"]?:@"";[self applyPrefs:p];[self layoutPicView];}
- (void)applyPrefs:(NSDictionary *)p{NSInteger mode=[p[@"contentMode"]integerValue];if(!mode)mode=1;UIViewContentMode cm=mode==1?UIViewContentModeScaleAspectFill:(mode==2?UIViewContentModeScaleAspectFit:UIViewContentModeScaleToFill);if([_mediaView isKindOfClass:UIImageView.class])((UIImageView *)_mediaView).contentMode=cm;if([_mediaView isKindOfClass:PMPlayerView.class])((PMPlayerView *)_mediaView).playerLayer.videoGravity=mode==1?AVLayerVideoGravityResizeAspectFill:(mode==2?AVLayerVideoGravityResizeAspect:AVLayerVideoGravityResize);CGFloat alpha=p[@"opacity"]?[p[@"opacity"]doubleValue]/100.0:1;_mediaView.alpha=alpha;_mediaView.clipsToBounds=YES;if(p[@"PixelArt"]&&[p[@"PixelArt"]boolValue]){_mediaView.layer.magnificationFilter=kCAFilterNearest;_mediaView.layer.minificationFilter=kCAFilterNearest;}}
- (void)layoutPicView{NSDictionary *p=Prefs(_identifier);BOOL deviceStyle=[p[@"idevice"]boolValue];BOOL noMargin=[p[@"NoMargin"]boolValue];CGFloat margin=(deviceStyle||!noMargin)?4.0:0.0;CGRect bounds=_scrollView.bounds;CGRect mediaFrame=CGRectInset(bounds,margin,margin);CGFloat outerRadius=MIN(19.0,MIN(bounds.size.width,bounds.size.height)*0.22);CGFloat mediaRadius=deviceStyle?2.0:MAX(0.0,outerRadius-margin);self.view.layer.cornerCurve=kCACornerCurveContinuous;self.view.layer.cornerRadius=outerRadius;self.view.layer.masksToBounds=YES;_scrollView.layer.cornerCurve=kCACornerCurveContinuous;_scrollView.layer.cornerRadius=outerRadius;_scrollView.layer.masksToBounds=YES;if(_scrollView.zoomScale<=1.001)_mediaView.frame=mediaFrame;_backdropView.frame=mediaFrame;_blurView.frame=mediaFrame;_backdropView.layer.cornerCurve=kCACornerCurveContinuous;_backdropView.layer.cornerRadius=mediaRadius;_backdropView.layer.masksToBounds=YES;_blurView.layer.cornerCurve=kCACornerCurveContinuous;_blurView.layer.cornerRadius=mediaRadius;_blurView.layer.masksToBounds=YES;_mediaView.layer.cornerCurve=kCACornerCurveContinuous;_mediaView.layer.cornerRadius=mediaRadius;_mediaView.layer.masksToBounds=YES;_scrollView.contentSize=mediaFrame.size;_labelView.hidden=(_labelView.text.length==0);[_labelView sizeToFit];_labelView.frame=CGRectMake(margin+6,self.view.bounds.size.height-_labelView.bounds.size.height-margin-4,_labelView.bounds.size.width,_labelView.bounds.size.height);}
- (void)viewDidLayoutSubviews{[super viewDidLayoutSubviews];[self layoutPicView];}
- (void)viewWillAppear:(BOOL)a{[super viewWillAppear:a];[self reloadPicture];}
- (void)viewDidDisappear:(BOOL)a{[super viewDidDisappear:a];[_player pause];}
- (void)loop:(NSNotification *)n{[_player seekToTime:kCMTimeZero];[_player play];}
- (void)doubleTap:(UITapGestureRecognizer *)g{BOOL reset=_scrollView.zoomScale>1.001;[_scrollView setZoomScale:(reset?1:2) animated:YES];if(reset)dispatch_async(dispatch_get_main_queue(),^{[self layoutPicView];});}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)s{return _mediaView;}
- (BOOL)shouldBeginTransitionToExpandedContentModule{return YES;}
- (void)willTransitionToExpandedContentMode:(BOOL)e{_expanded=e;[self reloadPicture];}
- (CGFloat)preferredExpandedContentHeight{return 350;}- (CGFloat)preferredExpandedContentWidth{return MIN(UIScreen.mainScreen.bounds.size.width-30,400);}- (CGFloat)preferredExpandedContinuousCornerRadius{return 20;}- (BOOL)providesOwnPlatter{return NO;}
- (void)dealloc{if(_notifyToken)notify_cancel(_notifyToken);if(_prefsNotifyToken)notify_cancel(_prefsNotifyToken);[[NSNotificationCenter defaultCenter]removeObserver:self];}
@end

@implementation PMOriginalModule{NSString *_identifier;PMOriginalContentViewController *_controller;}
- (instancetype)initWithIdentifier:(NSString *)i{if((self=[super init])){_identifier=i;_controller=[[PMOriginalContentViewController alloc]initWithIdentifier:i];}return self;}
- (NSString *)identifier{return _identifier;}
- (CCUILayoutSize)moduleSizeForOrientation:(int)o{NSDictionary *p=Prefs(_identifier);NSUInteger w=MAX(1,MIN(4,[p[@"Width"]integerValue]?:2)),h=MAX(1,MIN(4,[p[@"Height"]integerValue]?:1));return (CCUILayoutSize){w,h};}
- (BOOL)_canShowWhileLocked{return YES;}
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController{return _controller;}
- (UIViewController *)backgroundViewController{return nil;}
@end

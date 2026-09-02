#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Photos/Photos.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import "SCPaths.h"

static NSString *const kDualCamVersion = @"1.4.0";
static BOOL gDualActive = NO;
static NSHashTable<AVCaptureSession *> *gCameraSessions;
static dispatch_queue_t gSessionRegistryQueue;
static UIButton *gToggleButton;
static UIWindow *gHostWindow;

@class SCDualCamController;
static SCDualCamController *gController;
static void SCToggleDualCam(void);
static void SCEnsureToggleButton(void);

@interface SCDualCamTarget : NSObject
+ (void)toggle;
@end
@implementation SCDualCamTarget
+ (void)toggle { SCToggleDualCam(); }
@end

@interface SCDualCamController : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property(nonatomic,strong) dispatch_queue_t sessionQueue;
@property(nonatomic,strong) dispatch_queue_t sampleQueue;
@property(nonatomic,strong) AVCaptureMultiCamSession *session;
@property(nonatomic,strong) AVCaptureDevice *backDevice;
@property(nonatomic,strong) AVCaptureDevice *frontDevice;
@property(nonatomic,strong) AVCaptureVideoDataOutput *backVideo;
@property(nonatomic,strong) AVCaptureVideoDataOutput *frontVideo;
@property(nonatomic,strong) AVCaptureAudioDataOutput *audioOutput;
@property(nonatomic,strong) AVCapturePhotoOutput *backPhoto;
@property(nonatomic,strong) AVCapturePhotoOutput *frontPhoto;
@property(nonatomic,strong) AVSampleBufferDisplayLayer *backLayer;
@property(nonatomic,strong) AVSampleBufferDisplayLayer *frontLayer;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIButton *shutterButton;
@property(nonatomic,strong) UIButton *flashButton;
@property(nonatomic,strong) UIButton *modeButton;
@property(nonatomic,strong) UILabel *zoomLabel;
@property(nonatomic,assign) BOOL videoMode;
@property(nonatomic,assign) BOOL recording;
@property(nonatomic,assign) NSInteger flashState;
@property(nonatomic,assign) CGFloat zoomBase;
@property(nonatomic,strong) AVAssetWriter *writer;
@property(nonatomic,strong) AVAssetWriterInput *videoWriterInput;
@property(nonatomic,strong) AVAssetWriterInput *audioWriterInput;
@property(nonatomic,strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic,assign) CVPixelBufferPoolRef recordPool;
@property(nonatomic,assign) CVPixelBufferRef lastBack;
@property(nonatomic,assign) CVPixelBufferRef lastFront;
@property(nonatomic,assign) BOOL writerSessionStarted;
@property(nonatomic,assign) CMTime writerStartTime;
@property(nonatomic,assign) CGFloat recordDegrees;
@property(nonatomic,assign) size_t recordWidth;
@property(nonatomic,assign) size_t recordHeight;
@property(nonatomic,strong) NSURL *recordURL;
@property(nonatomic,strong) NSNumber *pendingBackID;
@property(nonatomic,strong) NSNumber *pendingFrontID;
@property(nonatomic,strong) UIImage *pendingBackImage;
@property(nonatomic,strong) UIImage *pendingFrontImage;
- (void)startDualCam;
- (void)stopDualCamWithCompletion:(dispatch_block_t)completion;
@end

static UIWindow *SCCameraWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState == UISceneActivationStateUnattached) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
        UIWindow *first = ((UIWindowScene *)scene).windows.firstObject;
        if (first) return first;
    }
    return app.keyWindow ?: app.windows.firstObject;
}

@implementation SCDualCamController
- (instancetype)init {
    if ((self=[super init])) {
        _sessionQueue=dispatch_queue_create("com.spark.sneakycam.dual.session",DISPATCH_QUEUE_SERIAL);
        _sampleQueue=dispatch_queue_create("com.spark.sneakycam.dual.sample",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.blackColor;
    self.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.backLayer=[AVSampleBufferDisplayLayer layer]; self.backLayer.videoGravity=AVLayerVideoGravityResizeAspectFill;
    self.frontLayer=[AVSampleBufferDisplayLayer layer]; self.frontLayer.videoGravity=AVLayerVideoGravityResizeAspectFill;
    self.frontLayer.cornerRadius=14; self.frontLayer.masksToBounds=YES; self.frontLayer.borderWidth=2; self.frontLayer.borderColor=UIColor.whiteColor.CGColor;
    [self.view.layer insertSublayer:self.backLayer atIndex:0]; [self.view.layer insertSublayer:self.frontLayer above:self.backLayer];
    self.statusLabel=[UILabel new]; self.statusLabel.textColor=UIColor.whiteColor; self.statusLabel.numberOfLines=0; self.statusLabel.textAlignment=NSTextAlignmentCenter; self.statusLabel.font=[UIFont systemFontOfSize:15]; self.statusLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:.6]; self.statusLabel.layer.cornerRadius=10; self.statusLabel.layer.masksToBounds=YES; self.statusLabel.hidden=YES; [self.view addSubview:self.statusLabel];
    self.shutterButton=[UIButton buttonWithType:UIButtonTypeCustom]; self.shutterButton.backgroundColor=UIColor.whiteColor; self.shutterButton.layer.cornerRadius=35; self.shutterButton.layer.borderWidth=4; self.shutterButton.layer.borderColor=UIColor.lightGrayColor.CGColor; [self.shutterButton addTarget:self action:@selector(shutter) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:self.shutterButton];
    self.flashButton=[self smallButton:@"关" action:@selector(toggleFlash)]; [self.view addSubview:self.flashButton];
    self.modeButton=[self smallButton:@"录像" action:@selector(toggleMode)]; [self.view addSubview:self.modeButton];
    self.zoomLabel=[UILabel new]; self.zoomLabel.textColor=UIColor.whiteColor; self.zoomLabel.textAlignment=NSTextAlignmentCenter; self.zoomLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightBold]; self.zoomLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:.45]; self.zoomLabel.layer.cornerRadius=8; self.zoomLabel.layer.masksToBounds=YES; self.zoomLabel.hidden=YES; [self.view addSubview:self.zoomLabel];
    [self.view addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)]];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged) name:UIDeviceOrientationDidChangeNotification object:nil];
}
- (UIButton *)smallButton:(NSString *)title action:(SEL)action { UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom]; b.backgroundColor=[UIColor colorWithWhite:0 alpha:.55]; b.layer.cornerRadius=22; b.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightBold]; [b setTitle:title forState:UIControlStateNormal]; [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return b; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; CGRect b=self.view.bounds; self.backLayer.frame=b; self.frontLayer.frame=CGRectMake(CGRectGetWidth(b)-146,80,130,180); CGFloat cy=CGRectGetHeight(b)-130,cx=CGRectGetMidX(b); self.shutterButton.frame=CGRectMake(cx-35,cy,70,70); self.flashButton.frame=CGRectMake(cx-160,cy+13,44,44); self.modeButton.frame=CGRectMake(cx+116,cy+13,44,44); self.zoomLabel.frame=CGRectMake(cx-40,40,80,30); self.statusLabel.frame=CGRectMake(30,CGRectGetMidY(b)-60,CGRectGetWidth(b)-60,120); [self.view bringSubviewToFront:self.statusLabel]; [self.view bringSubviewToFront:self.shutterButton]; [self.view bringSubviewToFront:self.flashButton]; [self.view bringSubviewToFront:self.modeButton]; [self.view bringSubviewToFront:self.zoomLabel]; }
- (void)showStatus:(NSString *)text { dispatch_async(dispatch_get_main_queue(),^{ self.statusLabel.text=text; self.statusLabel.hidden=NO; [self.view bringSubviewToFront:self.statusLabel]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2.5*NSEC_PER_SEC),dispatch_get_main_queue(),^{ if([self.statusLabel.text isEqualToString:text]) self.statusLabel.hidden=YES; }); }); }

- (AVCaptureInputPort *)videoPort:(AVCaptureDeviceInput *)input { for(AVCaptureInputPort *p in input.ports) if([p.mediaType isEqualToString:AVMediaTypeVideo]) return p; return nil; }
- (AVCaptureInputPort *)audioPort:(AVCaptureDeviceInput *)input { for(AVCaptureInputPort *p in input.ports) if([p.mediaType isEqualToString:AVMediaTypeAudio]) return p; return nil; }
- (AVCaptureVideoOrientation)orientation { switch(UIDevice.currentDevice.orientation){case UIDeviceOrientationPortraitUpsideDown:return AVCaptureVideoOrientationPortraitUpsideDown;case UIDeviceOrientationLandscapeLeft:return AVCaptureVideoOrientationLandscapeRight;case UIDeviceOrientationLandscapeRight:return AVCaptureVideoOrientationLandscapeLeft;default:return AVCaptureVideoOrientationPortrait;} }
- (void)orientationChanged { dispatch_async(self.sessionQueue,^{ AVCaptureVideoOrientation o=[self orientation]; for(AVCaptureConnection *c in self.backVideo.connections)if(c.isVideoOrientationSupported)c.videoOrientation=o; for(AVCaptureConnection *c in self.frontVideo.connections)if(c.isVideoOrientationSupported)c.videoOrientation=o; }); }
- (AVCaptureDeviceFormat *)formatForDevice:(AVCaptureDevice *)device width:(int32_t)width {
    AVCaptureDeviceFormat *best=nil;
    for(AVCaptureDeviceFormat *f in device.formats){ CMVideoDimensions d=CMVideoFormatDescriptionGetDimensions(f.formatDescription); BOOL supports30=NO; for(AVFrameRateRange *r in f.videoSupportedFrameRateRanges)if(r.maxFrameRate>=30){supports30=YES;break;} if(!supports30)continue; if(d.width==width&&d.height==width*9/16){best=f;break;} if(!best&&d.width<=width)best=f; }
    return best;
}
- (void)configureDevice:(AVCaptureDevice *)device {
    if(![device lockForConfiguration:nil])return;
    AVCaptureDeviceFormat *f=[self formatForDevice:device width:1280]; if(f)device.activeFormat=f;
    device.activeVideoMinFrameDuration=CMTimeMake(1,30); device.activeVideoMaxFrameDuration=CMTimeMake(1,30);
    [device unlockForConfiguration];
}
- (BOOL)addConnection:(AVCaptureConnection *)connection session:(AVCaptureMultiCamSession *)session error:(NSString **)error {
    if(connection&&[session canAddConnection:connection]){[session addConnection:connection];return YES;} if(error)*error=@"多摄连接资源不足"; return NO;
}
- (void)startDualCam {
    dispatch_async(self.sessionQueue,^{
        if(self.session)return;
        if(!AVCaptureMultiCamSession.isMultiCamSupported){[self showStatus:@"设备不支持前后多摄（需要 A12+）"];return;}
        AVCaptureDevice *back=[AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
        AVCaptureDevice *front=[AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront];
        if(!back||!front){[self showStatus:@"未找到前后摄像头"];return;}
        NSError *e=nil; AVCaptureDeviceInput *bi=[AVCaptureDeviceInput deviceInputWithDevice:back error:&e]; if(!bi){[self showStatus:[NSString stringWithFormat:@"后置输入失败：%@",e.localizedDescription?:@"未知错误"]];return;}
        e=nil; AVCaptureDeviceInput *fi=[AVCaptureDeviceInput deviceInputWithDevice:front error:&e]; if(!fi){[self showStatus:[NSString stringWithFormat:@"前置输入失败：%@",e.localizedDescription?:@"未知错误"]];return;}
        self.backDevice=back;self.frontDevice=front;[self configureDevice:back];[self configureDevice:front];
        AVCaptureMultiCamSession *s=[AVCaptureMultiCamSession new];[s beginConfiguration];
        NSString *failure=nil;
        if(![s canAddInput:bi]||![s canAddInput:fi])failure=@"系统拒绝添加前后输入";
        else {[s addInputWithNoConnections:bi];[s addInputWithNoConnections:fi];}
        self.backVideo=[AVCaptureVideoDataOutput new];self.frontVideo=[AVCaptureVideoDataOutput new];
        NSDictionary *pixel=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};self.backVideo.videoSettings=pixel;self.frontVideo.videoSettings=pixel;self.backVideo.alwaysDiscardsLateVideoFrames=YES;self.frontVideo.alwaysDiscardsLateVideoFrames=YES;[self.backVideo setSampleBufferDelegate:self queue:self.sampleQueue];[self.frontVideo setSampleBufferDelegate:self queue:self.sampleQueue];
        self.backPhoto=[AVCapturePhotoOutput new];self.frontPhoto=[AVCapturePhotoOutput new];
        for(AVCaptureOutput *o in @[self.backVideo,self.frontVideo,self.backPhoto,self.frontPhoto]){if(!failure&&[s canAddOutput:o])[s addOutputWithNoConnections:o];else if(!failure)failure=@"系统拒绝添加双摄输出";}
        AVCaptureInputPort *bp=[self videoPort:bi],*fp=[self videoPort:fi];
        if(!failure&&(!bp||!fp))failure=@"摄像头视频端口缺失";
        if(!failure){
            AVCaptureConnection *bc=[AVCaptureConnection connectionWithInputPorts:@[bp] output:self.backVideo];bc.videoMirrored=NO;[self addConnection:bc session:s error:&failure];
            AVCaptureConnection *fc=[AVCaptureConnection connectionWithInputPorts:@[fp] output:self.frontVideo];fc.automaticallyAdjustsVideoMirroring=NO;fc.videoMirrored=YES;[self addConnection:fc session:s error:&failure];
            [self addConnection:[AVCaptureConnection connectionWithInputPorts:@[bp] output:self.backPhoto] session:s error:&failure];
            [self addConnection:[AVCaptureConnection connectionWithInputPorts:@[fp] output:self.frontPhoto] session:s error:&failure];
        }
        AVCaptureDevice *mic=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];AVCaptureDeviceInput *mi=mic?[AVCaptureDeviceInput deviceInputWithDevice:mic error:nil]:nil;
        if(!failure&&mi&&[s canAddInput:mi]){[s addInputWithNoConnections:mi];self.audioOutput=[AVCaptureAudioDataOutput new];if([s canAddOutput:self.audioOutput]){[s addOutputWithNoConnections:self.audioOutput];AVCaptureInputPort *ap=[self audioPort:mi];AVCaptureConnection *ac=ap?[AVCaptureConnection connectionWithInputPorts:@[ap] output:self.audioOutput]:nil;if(ac&&[s canAddConnection:ac]){[s addConnection:ac];[self.audioOutput setSampleBufferDelegate:self queue:self.sampleQueue];}}}
        [s commitConfiguration];
        if(failure){[self clearCaptureObjects];[self showStatus:failure];return;}
        self.session=s;[[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(runtimeError:) name:AVCaptureSessionRuntimeErrorNotification object:s];
        [self orientationChanged];[s startRunning];
        if(!s.isRunning){[self clearCaptureObjects];[self showStatus:@"前后双摄会话启动失败"];return;}
        dispatch_async(dispatch_get_main_queue(),^{[self showStatus:@"运行中：后置 + 前置"];});
    });
}
- (void)runtimeError:(NSNotification *)n { NSError *e=n.userInfo[AVCaptureSessionErrorKey];[self showStatus:[NSString stringWithFormat:@"双摄会话错误：%@",e.localizedDescription?:@"未知错误"]]; }
- (void)clearCaptureObjects { self.backVideo=nil;self.frontVideo=nil;self.audioOutput=nil;self.backPhoto=nil;self.frontPhoto=nil;self.backDevice=nil;self.frontDevice=nil;self.session=nil; }

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)connection {
    if(output==self.audioOutput){[self appendAudio:sb];return;}
    CVPixelBufferRef pb=CMSampleBufferGetImageBuffer(sb);if(!pb)return;
    if(output==self.backVideo){if(self.lastBack)CVPixelBufferRelease(self.lastBack);self.lastBack=CVPixelBufferRetain(pb);if(self.recording&&self.lastFront&&self.videoWriterInput.readyForMoreMediaData)[self appendVideoAt:CMSampleBufferGetPresentationTimeStamp(sb)];}
    else if(output==self.frontVideo){if(self.lastFront)CVPixelBufferRelease(self.lastFront);self.lastFront=CVPixelBufferRetain(pb);}
    CFRetain(sb);dispatch_async(dispatch_get_main_queue(),^{AVSampleBufferDisplayLayer *layer=output==self.backVideo?self.backLayer:self.frontLayer;if(layer.status==AVQueuedSampleBufferRenderingStatusFailed)[layer flushAndRemoveImage];[layer enqueueSampleBuffer:sb];CFRelease(sb);});
}
static void SCReleaseImageBytes(void *info,const void *data,size_t length){free((void *)data);}
- (CGImageRef)newImageFromBuffer:(CVPixelBufferRef)buf {
    if(!buf)return NULL;CVPixelBufferLockBaseAddress(buf,kCVPixelBufferLock_ReadOnly);size_t w=CVPixelBufferGetWidth(buf),h=CVPixelBufferGetHeight(buf),row=CVPixelBufferGetBytesPerRow(buf),size=row*h;void *copy=malloc(size);if(!copy){CVPixelBufferUnlockBaseAddress(buf,kCVPixelBufferLock_ReadOnly);return NULL;}memcpy(copy,CVPixelBufferGetBaseAddress(buf),size);CVPixelBufferUnlockBaseAddress(buf,kCVPixelBufferLock_ReadOnly);CGDataProviderRef p=CGDataProviderCreateWithData(NULL,copy,size,SCReleaseImageBytes);CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGImageRef image=CGImageCreate(w,h,8,32,row,cs,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little,p,NULL,NO,kCGRenderingIntentDefault);CGColorSpaceRelease(cs);CGDataProviderRelease(p);return image;
}
- (void)drawImage:(CGImageRef)image context:(CGContextRef)c center:(CGPoint)center box:(CGSize)box degrees:(CGFloat)degrees mirror:(BOOL)mirror {
    CGContextSaveGState(c);CGContextTranslateCTM(c,center.x,center.y);CGContextRotateCTM(c,degrees*M_PI/180.0);if(mirror)CGContextScaleCTM(c,-1,1);size_t iw=CGImageGetWidth(image),ih=CGImageGetHeight(image);BOOL swap=((NSInteger)degrees%180)!=0;CGFloat cw=swap?ih:iw,ch=swap?iw:ih,scale=MAX(box.width/cw,box.height/ch);CGContextDrawImage(c,CGRectMake(-iw*scale/2,-ih*scale/2,iw*scale,ih*scale),image);CGContextRestoreGState(c);
}
- (CVPixelBufferRef)newCompositeBuffer {
    if(!self.recordPool||!self.lastBack||!self.lastFront)return NULL;CVPixelBufferRef out=NULL;if(CVPixelBufferPoolCreatePixelBuffer(NULL,self.recordPool,&out)!=kCVReturnSuccess)return NULL;CVPixelBufferLockBaseAddress(out,0);CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef c=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(out),self.recordWidth,self.recordHeight,8,CVPixelBufferGetBytesPerRow(out),cs,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);CGColorSpaceRelease(cs);if(!c){CVPixelBufferUnlockBaseAddress(out,0);CVPixelBufferRelease(out);return NULL;}CGContextSetRGBFillColor(c,0,0,0,1);CGContextFillRect(c,CGRectMake(0,0,self.recordWidth,self.recordHeight));CGImageRef back=[self newImageFromBuffer:self.lastBack];if(back){[self drawImage:back context:c center:CGPointMake(self.recordWidth/2.0,self.recordHeight/2.0) box:CGSizeMake(self.recordWidth,self.recordHeight) degrees:self.recordDegrees mirror:NO];CGImageRelease(back);}CGImageRef front=[self newImageFromBuffer:self.lastFront];if(front){CGFloat pw=self.recordWidth*.28,ph=pw*4.0/3.0,px=self.recordWidth-pw-self.recordWidth*.03,py=self.recordHeight-ph-self.recordHeight*.03;CGRect pip=CGRectMake(px,py,pw,ph);CGPathRef path=CGPathCreateWithRoundedRect(pip,14,14,NULL);CGContextSaveGState(c);CGContextAddPath(c,path);CGContextClip(c);[self drawImage:front context:c center:CGPointMake(CGRectGetMidX(pip),CGRectGetMidY(pip)) box:pip.size degrees:self.recordDegrees mirror:YES];CGContextRestoreGState(c);CGContextAddPath(c,path);CGContextSetRGBStrokeColor(c,1,1,1,1);CGContextSetLineWidth(c,4);CGContextStrokePath(c);CGPathRelease(path);CGImageRelease(front);}CGContextRelease(c);CVPixelBufferUnlockBaseAddress(out,0);return out;
}
- (CGFloat)recordingDegrees { switch(UIDevice.currentDevice.orientation){case UIDeviceOrientationPortraitUpsideDown:return 270;case UIDeviceOrientationLandscapeLeft:return 180;case UIDeviceOrientationLandscapeRight:return 0;default:return 90;} }
- (void)shutter {
    if(self.videoMode){self.recording?[self stopRecording]:[self startRecording];return;}
    dispatch_async(self.sessionQueue,^{if(!self.session.isRunning){[self showStatus:@"双摄未运行"];return;}self.pendingBackImage=nil;self.pendingFrontImage=nil;AVCapturePhotoSettings *b=[AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey:AVVideoCodecTypeJPEG}],*f=[AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey:AVVideoCodecTypeJPEG}];if(self.backDevice.hasFlash)b.flashMode=(AVCaptureFlashMode)self.flashState;f.flashMode=AVCaptureFlashModeOff;self.pendingBackID=@(b.uniqueID);self.pendingFrontID=@(f.uniqueID);[self.backPhoto capturePhotoWithSettings:b delegate:self];[self.frontPhoto capturePhotoWithSettings:f delegate:self];});
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    dispatch_async(self.sampleQueue,^{NSNumber *uid=@(photo.resolvedSettings.uniqueID);if(error){self.pendingBackImage=nil;self.pendingFrontImage=nil;self.pendingBackID=nil;self.pendingFrontID=nil;[self showStatus:[NSString stringWithFormat:@"双摄拍照失败：%@",error.localizedDescription?:@"未知错误"]];return;}UIImage *image=[UIImage imageWithData:photo.fileDataRepresentation];if(!image)return;if([uid isEqual:self.pendingBackID])self.pendingBackImage=image;else if([uid isEqual:self.pendingFrontID])self.pendingFrontImage=image;else return;if(!self.pendingBackImage||!self.pendingFrontImage)return;UIImage *back=self.pendingBackImage,*front=self.pendingFrontImage;self.pendingBackImage=nil;self.pendingFrontImage=nil;self.pendingBackID=nil;self.pendingFrontID=nil;CGSize size=back.size;UIGraphicsImageRenderer *r=[[UIGraphicsImageRenderer alloc]initWithSize:size];UIImage *result=[r imageWithActions:^(UIGraphicsImageRendererContext *ctx){[back drawInRect:(CGRect){CGPointZero,size}];CGFloat pw=size.width*.28,ph=pw*front.size.height/front.size.width;CGRect pip=CGRectMake(size.width-pw-size.width*.03,size.height-ph-size.height*.03,pw,ph);UIBezierPath *p=[UIBezierPath bezierPathWithRoundedRect:pip cornerRadius:14];[p addClip];CGContextTranslateCTM(ctx.CGContext,CGRectGetMaxX(pip),CGRectGetMinY(pip));CGContextScaleCTM(ctx.CGContext,-1,1);[front drawInRect:CGRectMake(0,0,pw,ph)];}];[[PHPhotoLibrary sharedPhotoLibrary]performChanges:^{[PHAssetChangeRequest creationRequestForAssetFromImage:result];} completionHandler:^(BOOL ok,NSError *e){[self showStatus:ok?@"双摄照片已保存":[NSString stringWithFormat:@"保存失败：%@",e.localizedDescription?:@"未知错误"]];}];});
}

- (void)startRecording {
    dispatch_async(self.sampleQueue,^{
        if(!self.session.isRunning||!self.lastBack||!self.lastFront){[self showStatus:@"等待前后画面就绪"];return;}
        [self resetWriter];self.recordDegrees=[self recordingDegrees];BOOL swap=((NSInteger)self.recordDegrees%180)!=0;self.recordWidth=swap?1280:720;self.recordHeight=swap?720:1280;NSString *name=[NSString stringWithFormat:@"SneakyCam-Dual-%@.mov",NSUUID.UUID.UUIDString];self.recordURL=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];NSError *e=nil;self.writer=[AVAssetWriter assetWriterWithURL:self.recordURL fileType:AVFileTypeQuickTimeMovie error:&e];if(!self.writer){[self showStatus:[NSString stringWithFormat:@"录像创建失败：%@",e.localizedDescription?:@"未知错误"]];return;}
        NSDictionary *vs=@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@(self.recordWidth),AVVideoHeightKey:@(self.recordHeight),AVVideoCompressionPropertiesKey:@{AVVideoAverageBitRateKey:@6000000,AVVideoExpectedSourceFrameRateKey:@30,AVVideoMaxKeyFrameIntervalKey:@60}};self.videoWriterInput=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vs];self.videoWriterInput.expectsMediaDataInRealTime=YES;
        NSDictionary *attrs=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferWidthKey:@(self.recordWidth),(id)kCVPixelBufferHeightKey:@(self.recordHeight),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};self.adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoWriterInput sourcePixelBufferAttributes:attrs];
        NSDictionary *as=@{AVFormatIDKey:@(kAudioFormatMPEG4AAC),AVNumberOfChannelsKey:@1,AVSampleRateKey:@44100,AVEncoderBitRateKey:@64000};self.audioWriterInput=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:as];self.audioWriterInput.expectsMediaDataInRealTime=YES;
        if(![self.writer canAddInput:self.videoWriterInput]){[self showStatus:@"设备拒绝录像编码输入"];[self resetWriter];return;}[self.writer addInput:self.videoWriterInput];if([self.writer canAddInput:self.audioWriterInput])[self.writer addInput:self.audioWriterInput];else self.audioWriterInput=nil;
        CVPixelBufferPoolRef pool=NULL;if(CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attrs,&pool)!=kCVReturnSuccess||!pool){[self showStatus:@"录像缓冲池创建失败"];[self resetWriter];return;}self.recordPool=pool;
        if(![self.writer startWriting]){[self showStatus:[NSString stringWithFormat:@"录像编码启动失败：%@",self.writer.error.localizedDescription?:@"未知错误"]];[self resetWriter];return;}self.writerSessionStarted=NO;self.recording=YES;dispatch_async(dispatch_get_main_queue(),^{self.shutterButton.backgroundColor=UIColor.redColor;[self showStatus:self.audioWriterInput?@"双摄录像中（含声音）":@"双摄录像中（无声音）"];});
    });
}
- (void)appendVideoAt:(CMTime)time { if(!self.recording||!self.writer||self.writer.status!=AVAssetWriterStatusWriting)return;if(!self.writerSessionStarted){[self.writer startSessionAtSourceTime:time];self.writerStartTime=time;self.writerSessionStarted=YES;}CVPixelBufferRef frame=[self newCompositeBuffer];if(frame){[self.adaptor appendPixelBuffer:frame withPresentationTime:time];CVPixelBufferRelease(frame);} }
- (void)appendAudio:(CMSampleBufferRef)sb { if(!self.recording||!self.writerSessionStarted||!self.audioWriterInput.readyForMoreMediaData)return;CMTime t=CMSampleBufferGetPresentationTimeStamp(sb);if(CMTimeCompare(t,self.writerStartTime)>=0)[self.audioWriterInput appendSampleBuffer:sb]; }
- (void)stopRecording {
    dispatch_async(self.sampleQueue,^{if(!self.recording)return;self.recording=NO;dispatch_async(dispatch_get_main_queue(),^{self.shutterButton.backgroundColor=UIColor.whiteColor;[self showStatus:@"正在保存双摄录像…"];});AVAssetWriter *writer=self.writer;NSURL *url=self.recordURL;if(!self.writerSessionStarted){[writer cancelWriting];[self resetWriter];[self showStatus:@"录像时间过短，未写入画面"];return;}[self.videoWriterInput markAsFinished];[self.audioWriterInput markAsFinished];[writer finishWritingWithCompletionHandler:^{if(writer.status==AVAssetWriterStatusCompleted){[[PHPhotoLibrary sharedPhotoLibrary]performChanges:^{[PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];} completionHandler:^(BOOL ok,NSError *e){[[NSFileManager defaultManager]removeItemAtURL:url error:nil];[self showStatus:ok?@"双摄录像已保存":[NSString stringWithFormat:@"录像保存失败：%@",e.localizedDescription?:@"未知错误"]];}];}else{[[NSFileManager defaultManager]removeItemAtURL:url error:nil];[self showStatus:[NSString stringWithFormat:@"录像写入失败：%@",writer.error.localizedDescription?:@"未知错误"]];}dispatch_async(self.sampleQueue,^{[self resetWriter];});}];});
}
- (void)resetWriter { if(self.recordPool){CVPixelBufferPoolRelease(self.recordPool);self.recordPool=NULL;}self.writer=nil;self.videoWriterInput=nil;self.audioWriterInput=nil;self.adaptor=nil;self.recordURL=nil;self.writerSessionStarted=NO; }
- (void)toggleMode { if(self.recording)return;self.videoMode=!self.videoMode;[self.modeButton setTitle:self.videoMode?@"照片":@"录像" forState:UIControlStateNormal]; }
- (void)toggleFlash { self.flashState=(self.flashState+1)%3;NSString *title=self.flashState==0?@"关":self.flashState==1?@"开":@"自动";[self.flashButton setTitle:title forState:UIControlStateNormal]; }
- (void)pinch:(UIPinchGestureRecognizer *)gesture { AVCaptureDevice *d=self.backDevice;if(!d)return;if(gesture.state==UIGestureRecognizerStateBegan)self.zoomBase=d.videoZoomFactor;CGFloat zoom=MAX(1,MIN(MIN(d.activeFormat.videoMaxZoomFactor,10),self.zoomBase*gesture.scale));dispatch_async(self.sessionQueue,^{if([d lockForConfiguration:nil]){d.videoZoomFactor=zoom;[d unlockForConfiguration];}});self.zoomLabel.text=[NSString stringWithFormat:@"%.1fx",zoom];self.zoomLabel.hidden=NO;if(gesture.state==UIGestureRecognizerStateEnded||gesture.state==UIGestureRecognizerStateCancelled)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{self.zoomLabel.hidden=YES;}); }
- (void)stopDualCamWithCompletion:(dispatch_block_t)completion {
    dispatch_async(self.sessionQueue,^{if(self.recording){dispatch_sync(self.sampleQueue,^{self.recording=NO;if(self.writer)[self.writer cancelWriting];[self resetWriter];});}AVCaptureMultiCamSession *s=self.session;[[NSNotificationCenter defaultCenter]removeObserver:self name:nil object:s];[self.backVideo setSampleBufferDelegate:nil queue:NULL];[self.frontVideo setSampleBufferDelegate:nil queue:NULL];[self.audioOutput setSampleBufferDelegate:nil queue:NULL];if(s.isRunning)[s stopRunning];dispatch_sync(self.sampleQueue,^{if(self.lastBack){CVPixelBufferRelease(self.lastBack);self.lastBack=NULL;}if(self.lastFront){CVPixelBufferRelease(self.lastFront);self.lastFront=NULL;}self.pendingBackImage=nil;self.pendingFrontImage=nil;});[self clearCaptureObjects];dispatch_async(dispatch_get_main_queue(),^{[self.backLayer flushAndRemoveImage];[self.frontLayer flushAndRemoveImage];if(completion)completion();});});
}
- (void)dealloc { [[NSNotificationCenter defaultCenter]removeObserver:self];[[UIDevice currentDevice]endGeneratingDeviceOrientationNotifications]; }
@end

static BOOL SCDualEnabled(void){id v=SCReadPreferencesNoMigrate()[@"DualCamEnabled"];return v?[v boolValue]:YES;}
static NSArray<AVCaptureSession *> *SCCameraSessionSnapshot(void){__block NSArray *sessions;dispatch_sync(gSessionRegistryQueue,^{sessions=gCameraSessions.allObjects;});return sessions?:@[];}
static void SCPlaceToggle(UIWindow *window){if(!window||!gToggleButton)return;if(gToggleButton.superview!=window){[gToggleButton removeFromSuperview];[window addSubview:gToggleButton];}[window bringSubviewToFront:gToggleButton];}
static void SCEnsureToggleButton(void){
    dispatch_async(dispatch_get_main_queue(),^{UIWindow *window=SCCameraWindow();if(!SCDualEnabled()){if(gDualActive)SCToggleDualCam();[gToggleButton removeFromSuperview];gToggleButton=nil;return;}if(!gToggleButton){gToggleButton=[UIButton buttonWithType:UIButtonTypeCustom];gToggleButton.frame=CGRectMake(CGRectGetWidth(UIScreen.mainScreen.bounds)-84,74,72,44);gToggleButton.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleBottomMargin;gToggleButton.backgroundColor=[UIColor colorWithWhite:0 alpha:.58];gToggleButton.layer.cornerRadius=22;gToggleButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightBold];[gToggleButton setTitle:@"双摄" forState:UIControlStateNormal];[gToggleButton addTarget:SCDualCamTarget.class action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];}SCPlaceToggle(window);});
}
static void SCToggleDualCam(void){
    if(!gDualActive){
        gDualActive=YES;[gToggleButton setTitle:@"关闭" forState:UIControlStateNormal];NSArray *sessions=SCCameraSessionSnapshot();dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{for(AVCaptureSession *s in sessions)if(s.isRunning)[s stopRunning];dispatch_async(dispatch_get_main_queue(),^{UIWindow *window=SCCameraWindow();gHostWindow=window;if(!gController)gController=[SCDualCamController new];UIView *view=gController.view;view.frame=window.bounds;view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;if(view.superview!=window)[window addSubview:view];[window bringSubviewToFront:view];SCPlaceToggle(window);[gController startDualCam];});});
    }else{
        gDualActive=NO;[gToggleButton setTitle:@"双摄" forState:UIControlStateNormal];[gController stopDualCamWithCompletion:^{[gController.view removeFromSuperview];SCPlaceToggle(SCCameraWindow());NSArray *sessions=SCCameraSessionSnapshot();dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{for(AVCaptureSession *s in sessions)if(!s.isRunning)[s startRunning];});}];
    }
}

%hook AVCaptureSession
- (void)startRunning {if(!gCameraSessions){%orig;return;}dispatch_async(gSessionRegistryQueue,^{[gCameraSessions addObject:self];});if(gDualActive&&self!=gController.session)return;%orig;}
- (BOOL)startRunningWithError:(NSError **)error {if(!gCameraSessions)return %orig;dispatch_async(gSessionRegistryQueue,^{[gCameraSessions addObject:self];});if(gDualActive&&self!=gController.session){if(error)*error=nil;return YES;}return %orig;}
%end

static void SCDualPreferenceChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){SCEnsureToggleButton();}
%ctor {@autoreleasepool{
    gSessionRegistryQueue=dispatch_queue_create("com.spark.sneakycam.dual.registry",DISPATCH_QUEUE_SERIAL);gCameraSessions=[NSHashTable weakObjectsHashTable];
    [[NSNotificationCenter defaultCenter]addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.5*NSEC_PER_SEC),dispatch_get_main_queue(),^{SCEnsureToggleButton();});}];
    [[NSNotificationCenter defaultCenter]addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){SCEnsureToggleButton();}];
    [[NSNotificationCenter defaultCenter]addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){if(gDualActive)SCToggleDualCam();}];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,SCDualPreferenceChanged,CFSTR("com.spark.SneakyCam"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
}}

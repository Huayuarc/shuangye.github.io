#import "SCCaptureManager.h"
#import "SCPaths.h"
#import <notify.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#import <unistd.h>

static NSString * const SCPhotoKey=@"PhotoEnabled";
static NSString * const SCVideoKey=@"VideoEnabled";

@interface SCCaptureManager () <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate>
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) AVCaptureSession *session;
@property(nonatomic,strong) AVCaptureDeviceInput *videoInput;
@property(nonatomic,strong) AVCaptureDeviceInput *audioInput;
@property(nonatomic,strong) AVCapturePhotoOutput *photoOutput;
@property(nonatomic,strong) AVCaptureMovieFileOutput *movieOutput;
@property(nonatomic,strong) NSURL *movieURL;
@property(nonatomic,assign) BOOL recording;
@property(nonatomic,assign) BOOL startFeedbackSent;
@end

@implementation SCCaptureManager

+ (instancetype)shared { static id x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (instancetype)init { if((self=[super init])) _queue=dispatch_queue_create("com.spark.sneakycam.capture", DISPATCH_QUEUE_SERIAL); return self; }
- (NSDictionary *)prefs { return SCReadPreferences(); }
- (BOOL)boolPref:(NSString *)key def:(BOOL)def { id v=self.prefs[key]; return v?[v boolValue]:def; }

- (AVCaptureDevicePosition)requestedPosition {
    if([self.prefs[@"CameraDevice"] isEqualToString:@"AVCaptureDevicePositionFront"]) return AVCaptureDevicePositionFront;
    return AVCaptureDevicePositionBack;
}

// 跨设备摄像头发现：优先目标方向，其次任意广角，再任意相机；方向不符时依次回退。
- (AVCaptureDevice *)bestDeviceForPosition:(AVCaptureDevicePosition)requested {
    NSMutableArray *candidates=[NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (AVCaptureDeviceType type in @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera, AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInDualWideCamera, AVCaptureDeviceTypeBuiltInTripleCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera]) {
            AVCaptureDeviceDiscoverySession *ds=[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[type] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
            for (AVCaptureDevice *d in ds.devices) [candidates addObject:d];
        }
    }
    if (candidates.count==0) { for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) [candidates addObject:d]; }

    AVCaptureDevice *preferred=nil; AVCaptureDevice *any=nil;
    for (AVCaptureDevice *d in candidates) {
        if (d.position==requested) {
            if (!preferred) preferred=d;
        } else if (any==nil) {
            any=d;
        }
    }
    if (!preferred) preferred=any;
    if (!preferred && candidates.count) preferred=candidates[0];
    return preferred;
}

- (BOOL)hasCameraAccess {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    AVAuthorizationStatus s=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (s==AVAuthorizationStatusNotDetermined) { [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL g){}]; s=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]; }
    return s==AVAuthorizationStatusAuthorized;
#endif
}
- (BOOL)hasMicAccess {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return [[AVAudioSession sharedInstance] recordPermission]==AVAudioSessionRecordPermissionGranted;
#endif
}

- (void)configureHardware:(AVCaptureDevice *)dev fps:(NSInteger)fps {
    if (!dev || ![dev lockForConfiguration:nil]) return;
    AVFrameRateRange *best=nil;
    for (AVFrameRateRange *r in dev.activeFormat.videoSupportedFrameRateRanges) {
        if (r.maxFrameRate>=fps-0.5) { if(!best || r.maxFrameRate>best.maxFrameRate) best=r; }
    }
    if (!best) { for (AVFrameRateRange *r in dev.activeFormat.videoSupportedFrameRateRanges) { if(!best || r.maxFrameRate>best.maxFrameRate) best=r; } }
    if (best) {
        int32_t apply=(int32_t)fps; if (fps>best.maxFrameRate) apply=(int32_t)best.maxFrameRate; if(apply<best.minFrameRate) apply=(int32_t)best.minFrameRate;
        dev.activeVideoMinFrameDuration=CMTimeMake(1,apply);
        dev.activeVideoMaxFrameDuration=CMTimeMake(1,apply);
    }
    [dev unlockForConfiguration];
}

// 选择最能匹配请求分辨率的 preset（按设备支持逐级降级）
- (NSString *)resolvePreset:(NSString *)requested forSession:(AVCaptureSession *)session {
    NSArray<NSString*> *ranked;
    if ([requested isEqualToString:AVCaptureSessionPreset3840x2160]) ranked=@[AVCaptureSessionPreset3840x2160,AVCaptureSessionPreset1920x1080,AVCaptureSessionPreset1280x720,AVCaptureSessionPresetHigh,AVCaptureSessionPreset640x480];
    else if ([requested isEqualToString:AVCaptureSessionPreset1920x1080]) ranked=@[AVCaptureSessionPreset1920x1080,AVCaptureSessionPreset1280x720,AVCaptureSessionPresetHigh,AVCaptureSessionPreset640x480];
    else if ([requested isEqualToString:AVCaptureSessionPreset1280x720]) ranked=@[AVCaptureSessionPreset1280x720,AVCaptureSessionPresetHigh,AVCaptureSessionPreset640x480];
    else ranked=@[requested,AVCaptureSessionPresetHigh,AVCaptureSessionPreset640x480,AVCaptureSessionPreset352x288];
    for (NSString *p in ranked) { if (p && [session canSetSessionPreset:p]) return p; }
    return AVCaptureSessionPresetHigh;
}

- (BOOL)prepare:(BOOL)video {
    if (_session) return YES;
    if (![self hasCameraAccess]) return NO;
    AVCaptureDevice *dev=[self bestDeviceForPosition:[self requestedPosition]];
    if (!dev) return NO;
    NSError *err=nil;
    AVCaptureDeviceInput *in=[AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!in) return NO;

    AVCaptureSession *session=[AVCaptureSession new];
    NSString *presetStr=self.prefs[@"VideoQuality"] ?: AVCaptureSessionPreset1920x1080;
    NSString *resolved=[self resolvePreset:presetStr forSession:session];
    if ([session canSetSessionPreset:resolved]) session.sessionPreset=resolved;

    if ([session canAddInput:in]) { [session addInput:in]; } else { return NO; }
    _videoInput=in;

    // 拍照输出
    _photoOutput=[AVCapturePhotoOutput new]; if ([session canAddOutput:_photoOutput]) [session addOutput:_photoOutput];
    // 录像输出（两段式：先建输出再加，保证音频可后续加入）
    _movieOutput=[AVCaptureMovieFileOutput new];
    if (@available(iOS 11.0,*)) _movieOutput.movieFragmentInterval=CMTimeMake(1,1);
    if ([session canAddOutput:_movieOutput]) [session addOutput:_movieOutput];

    // 录像时加入默认麦克风；被占用或权限不足则仅视频
    NSInteger fps=[self.prefs[@"FrameRate"] integerValue]; if(fps<=0) fps=60;
    if (video) {
        [self configureHardware:dev fps:fps];
        if ([self hasMicAccess]) {
            AVCaptureDevice *mic=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            if (mic) {
                AVCaptureDeviceInput *m=[AVCaptureDeviceInput deviceInputWithDevice:mic error:nil];
                if (m && [session canAddInput:m]) { [session addInput:m]; _audioInput=m; }
            }
        }
    } else {
        [self configureHardware:dev fps:[self.prefs[@"FrameRate"] integerValue] ?: 30];
    }

    [session startRunning];
    _session=session;
    return _session.isRunning;
}

// 播放音视频时暂停录制保护（DisableIfPlayback）
- (BOOL)blockedByPlayback {
    if ([self boolPref:@"DisableIfPlayback" def:NO]) {
        return [[AVAudioSession sharedInstance] isOtherAudioPlaying];
    }
    return NO;
}

- (void)reportStatus:(NSString *)status hapticStyle:(UIImpactFeedbackStyle)style repeats:(NSInteger)repeats {
    (void)style;
    NSDateFormatter *formatter=[NSDateFormatter new]; formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss";
    SCWritePreference(@"LastActionDate", [formatter stringFromDate:[NSDate date]]);
    SCWritePreference(@"LastActionStatus", status ?: @"未知状态");
    notify_post("com.spark.SneakyCam.actionstatechanged");
    if(repeats>0 && [self boolPref:@"HapticFeedback" def:YES]) {
        // 双通道触觉：亮屏使用 UIKit Impact，熄屏时 AudioServices 仍能驱动系统马达。
        for(NSInteger i=0;i<repeats;i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(i*0.28*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            UIImpactFeedbackGenerator *g=[[UIImpactFeedbackGenerator alloc]initWithStyle:style];
            [g prepare]; [g impactOccurred];
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        });
    }
}

- (void)takePhoto {
    if(![self boolPref:SCPhotoKey def:YES]) { [self reportStatus:@"拍照功能已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
    dispatch_async(_queue, ^{
        if(![self boolPref:@"Enabled" def:NO]) { [self reportStatus:@"功能总开关已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if([self blockedByPlayback]) { [self reportStatus:@"播放音视频中，已阻止拍照" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if(![self presentSessionForVideo:NO]) { [self reportStatus:@"相机启动失败" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        AVCapturePhotoSettings *s=[AVCapturePhotoSettings photoSettings];
        if([self boolPref:@"PhotoSilent" def:YES]) {
            SEL silentSelector=NSSelectorFromString(@"setShutterSound:");
            if(![s respondsToSelector:silentSelector]) silentSelector=NSSelectorFromString(@"_setShutterSound:");
            if([s respondsToSelector:silentSelector]) ((void(*)(id,SEL,BOOL))objc_msgSend)(s,silentSelector,NO);
        }
        [self.photoOutput capturePhotoWithSettings:s delegate:self];
    });
}
// 受 takePhoto 使用；实际 prepare 由 -prepare: 完成
- (BOOL)presentSessionForVideo:(BOOL)video { return [self prepare:video]; }

- (void)toggleVideo {
    dispatch_async(_queue, ^{
        if(![self boolPref:SCVideoKey def:YES]) { [self reportStatus:@"录像功能已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if(![self boolPref:@"Enabled" def:NO]) { [self reportStatus:@"功能总开关已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if([self blockedByPlayback]) { [self reportStatus:@"播放音视频中，已阻止录像" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if(self.movieOutput && self.movieOutput.isRecording){ [self reportStatus:@"录像停止请求已接受" hapticStyle:UIImpactFeedbackStyleLight repeats:2]; [self.movieOutput stopRecording]; return; }
        if(![self prepare:YES]) { [self reportStatus:@"相机启动失败" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.mov",NSUUID.UUID.UUIDString];
        self.movieURL=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:n]];
        [self.movieOutput startRecordingToOutputFileURL:self.movieURL recordingDelegate:self];
        [self setRecordingState:YES];
        self.startFeedbackSent=YES;
        [self reportStatus:@"录像启动请求已接受" hapticStyle:UIImpactFeedbackStyleHeavy repeats:2];
    });
}

- (NSString *)saveData:(NSData *)data ext:(NSString *)ext {
    if([self boolPref:@"SaveToRoot" def:NO]){
        NSString *dir=@"/var/mobile/Downloads";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.%@",NSUUID.UUID.UUIDString,ext];
        NSString *path=[dir stringByAppendingPathComponent:n];
        return [data writeToFile:path atomically:YES] ? path : nil;
    }
    NSError *err=nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        PHAssetCreationRequest *r=[PHAssetCreationRequest creationRequestForAsset];
        [r addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
    } error:&err];
    return err?nil:@"已保存到系统相册";
}

- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (!error) {
        NSData *d=photo.fileDataRepresentation;
        NSString *result=d?[self saveData:d ext:@"jpg"]:nil;
        if(result) [self reportStatus:[NSString stringWithFormat:@"拍照成功：%@",result] hapticStyle:UIImpactFeedbackStyleMedium repeats:2];
        else [self reportStatus:@"拍照保存失败" hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    } else [self reportStatus:[NSString stringWithFormat:@"拍照失败：%@",error.localizedDescription?:@"未知错误"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    [self stopAndRelease];
}
- (void)setRecordingState:(BOOL)rec {
    self.recording=rec;
    SCWritePreference(@"Recording", @(rec));
    notify_post("com.spark.SneakyCam.recordingstatechanged");
}
- (void)captureOutput:(AVCaptureFileOutput *)o didStartRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c {
    [self setRecordingState:YES];
    BOOL needsFeedback=!self.startFeedbackSent; self.startFeedbackSent=YES;
    [self reportStatus:@"录像已开始" hapticStyle:UIImpactFeedbackStyleHeavy repeats:needsFeedback?2:0];
}
- (void)captureOutput:(AVCaptureFileOutput *)o didFinishRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c error:(NSError *)e {
    [self setRecordingState:NO];
    if(!e){
        NSString *saved=@"已保存到系统相册";
        if([self boolPref:@"SaveToRoot" def:NO]){
            NSString *dir=@"/var/mobile/Downloads";
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *target=[dir stringByAppendingPathComponent:u.lastPathComponent];
            BOOL ok=[[NSFileManager defaultManager] moveItemAtURL:u toURL:[NSURL fileURLWithPath:target] error:nil];
            saved=ok?target:nil;
        } else {
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:u];
            } completionHandler:^(BOOL ok,NSError *x){ [[NSFileManager defaultManager] removeItemAtURL:u error:nil]; }];
        }
        if(saved) [self reportStatus:[NSString stringWithFormat:@"录像已停止：%@",saved] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
        else [self reportStatus:@"录像保存失败" hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    } else [self reportStatus:[NSString stringWithFormat:@"录像失败：%@",e.localizedDescription?:@"未知错误"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    [self stopAndRelease];
}

- (void)stopAndRelease {
    dispatch_async(_queue, ^{
        if(self.movieOutput && self.movieOutput.isRecording){ [self.movieOutput stopRecording]; return; }
        if(self.session){ [self.session stopRunning];
            if(self.audioInput && [self.session.inputs containsObject:self.audioInput]) [self.session removeInput:self.audioInput];
            if(self.videoInput && [self.session.inputs containsObject:self.videoInput]) [self.session removeInput:self.videoInput];
            for(AVCaptureOutput *out in self.session.outputs) [self.session removeOutput:out];
        }
        self.audioInput=nil; self.videoInput=nil; self.photoOutput=nil; self.movieOutput=nil; self.session=nil; self.movieURL=nil; self.startFeedbackSent=NO;
        [self setRecordingState:NO];
    });
}
@end

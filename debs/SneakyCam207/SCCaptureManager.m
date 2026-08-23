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
@property(nonatomic,copy) NSString *lastPrepareError;
@property(nonatomic,assign) BOOL videoDesired;
@property(nonatomic,assign) BOOL userStopping;
@property(nonatomic,assign) BOOL sessionInterrupted;
@property(nonatomic,assign) NSInteger restartAttempts;
@property(nonatomic,assign) BOOL recoveryScheduled;
@property(nonatomic,strong) NSMutableArray<NSURL *> *videoSegments;
@end

@implementation SCCaptureManager

+ (instancetype)shared { static id x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (instancetype)init { if((self=[super init])) { _queue=dispatch_queue_create("com.spark.sneakycam.capture", DISPATCH_QUEUE_SERIAL); _videoSegments=[NSMutableArray array]; } return self; }
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

- (BOOL)isPrivilegedCaptureHost {
    NSString *p=NSProcessInfo.processInfo.processName.lowercaseString;
    return [p isEqualToString:@"springboard"]||[p isEqualToString:@"mediaserverd"]||[p containsString:@"celestial"];
}
- (BOOL)hasCameraAccess {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    // 越狱系统捕获运行在 SpringBoard/mediaserverd，后台访问由 SneakySupport Hook 授予；
    // 普通 App 的 TCC 状态不应在此阻断系统进程。
    if([self isPrivilegedCaptureHost]) return YES;
    AVAuthorizationStatus s=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if(s==AVAuthorizationStatusNotDetermined) [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted){}];
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
    self.lastPrepareError=nil;
    if (_session && _session.isRunning && ((video&&_movieOutput)||(!video&&_photoOutput))) return YES;
    if (_session) { [_session stopRunning]; _session=nil; _photoOutput=nil; _movieOutput=nil; _videoInput=nil; _audioInput=nil; }
    if (![self hasCameraAccess]) { self.lastPrepareError=@"相机访问权限未就绪"; return NO; }
    AVCaptureDevice *dev=[self bestDeviceForPosition:[self requestedPosition]];
    if (!dev) { self.lastPrepareError=@"未发现可用摄像头"; return NO; }
    NSError *err=nil;
    AVCaptureDeviceInput *in=[AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!in) { self.lastPrepareError=[NSString stringWithFormat:@"摄像头输入失败：%@",err.localizedDescription?:@"未知错误"]; return NO; }

    AVCaptureSession *session=[AVCaptureSession new];
    [session beginConfiguration];
    if(![session canAddInput:in]) { [session commitConfiguration]; self.lastPrepareError=@"系统拒绝添加摄像头输入"; return NO; }
    [session addInput:in]; _videoInput=in;
    NSString *presetStr=self.prefs[@"VideoQuality"] ?: AVCaptureSessionPreset1920x1080;
    NSString *resolved=[self resolvePreset:presetStr forSession:session];
    if ([session canSetSessionPreset:resolved]) session.sessionPreset=resolved;

    if(video) {
        AVCaptureMovieFileOutput *movie=[AVCaptureMovieFileOutput new];
        if (@available(iOS 11.0,*)) movie.movieFragmentInterval=CMTimeMake(1,1);
        if(![session canAddOutput:movie]) { [session commitConfiguration]; self.lastPrepareError=@"设备不支持当前录像输出"; return NO; }
        [session addOutput:movie]; _movieOutput=movie; _photoOutput=nil;
        AVCaptureDevice *mic=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if(mic) { AVCaptureDeviceInput *m=[AVCaptureDeviceInput deviceInputWithDevice:mic error:nil]; if(m&&[session canAddInput:m]){[session addInput:m];_audioInput=m;} }
    } else {
        AVCapturePhotoOutput *photo=[AVCapturePhotoOutput new];
        if(![session canAddOutput:photo]) { [session commitConfiguration]; self.lastPrepareError=@"设备不支持当前拍照输出"; return NO; }
        [session addOutput:photo]; _photoOutput=photo; _movieOutput=nil;
    }
    [session commitConfiguration];
    NSInteger applyFPS=video?[self.prefs[@"FrameRate"] integerValue]:30; if(applyFPS<=0)applyFPS=video?60:30;
    [self configureHardware:dev fps:applyFPS];
    _session=session;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:session];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:session];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:session];
    [session startRunning];
    // 后台系统进程中 isRunning 可能延迟更新；输入/输出配置成功即接受启动请求，
    // 后续由 whenSessionReady 重试等待或 RuntimeError 通知报告真实失败。
    return YES;
}
- (void)scheduleVideoRecovery:(NSString *)reason {
    if(![self keepLockScreenRecording]||!self.videoDesired||self.userStopping||self.recoveryScheduled)return;
    if(self.restartAttempts>=3){ [self reportStatus:@"录像恢复失败：已达到重试上限" hapticStyle:UIImpactFeedbackStyleLight repeats:0];self.videoDesired=NO;return; }
    self.restartAttempts++;self.recoveryScheduled=YES;
    [self reportStatus:[NSString stringWithFormat:@"录像被系统中断，正在恢复（%ld/3）：%@",(long)self.restartAttempts,reason?:@"屏幕状态变化"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.45*NSEC_PER_SEC)),self.queue,^{
        self.recoveryScheduled=NO;
        if(!self.videoDesired||self.userStopping)return;
        if(self.session){[[NSNotificationCenter defaultCenter]removeObserver:self name:nil object:self.session];[self.session stopRunning];}
        self.session=nil;self.movieOutput=nil;self.photoOutput=nil;self.videoInput=nil;self.audioInput=nil;self.recording=NO;
        if(![self prepare:YES]){[self scheduleVideoRecovery:self.lastPrepareError?:@"会话重建失败"];return;}
        [self whenSessionReadyAttempt:0 action:^{
            if(!self.videoDesired||self.userStopping)return;
            NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.mov",NSUUID.UUID.UUIDString];self.movieURL=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:n]];
            [self.movieOutput startRecordingToOutputFileURL:self.movieURL recordingDelegate:self];[self setRecordingState:YES];self.startFeedbackSent=YES;self.restartAttempts=0;
            [self reportStatus:@"录像已自动恢复" hapticStyle:UIImpactFeedbackStyleMedium repeats:0];
        }];
    });
}
- (void)sessionRuntimeError:(NSNotification *)note {
    NSError *e=note.userInfo[AVCaptureSessionErrorKey];
    [self reportStatus:[NSString stringWithFormat:@"相机会话错误：%@",e.localizedDescription?:@"未知错误"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    if(self.videoDesired&&!self.userStopping&&[self keepLockScreenRecording])[self scheduleVideoRecovery:e.localizedDescription];
}
- (void)sessionWasInterrupted:(NSNotification *)note {
    self.sessionInterrupted=YES;
    if(self.videoDesired&&!self.userStopping&&[self keepLockScreenRecording])[self reportStatus:@"录像被屏幕状态中断，等待恢复" hapticStyle:UIImpactFeedbackStyleLight repeats:0];
}
- (void)sessionInterruptionEnded:(NSNotification *)note {
    BOOL shouldRecover=self.videoDesired&&!self.userStopping&&[self keepLockScreenRecording]&&(self.sessionInterrupted||!self.movieOutput.isRecording);self.sessionInterrupted=NO;
    if(shouldRecover)[self scheduleVideoRecovery:@"系统中断已结束"];
}
- (void)whenSessionReadyAttempt:(NSInteger)attempt action:(dispatch_block_t)action {
    if(self.session.isRunning){ if(action)action(); return; }
    if(attempt>=12){ self.lastPrepareError=@"相机会话启动超时"; [self reportStatus:self.lastPrepareError hapticStyle:UIImpactFeedbackStyleLight repeats:0]; [self stopAndRelease]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.15*NSEC_PER_SEC)),self.queue,^{ [self whenSessionReadyAttempt:attempt+1 action:action]; });
}

// 播放音视频时暂停录制保护（DisableIfPlayback）
- (BOOL)keepLockScreenRecording { return [self boolPref:@"LockScreenKeepRecording" def:YES]; }

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
        // 单通道系统马达：亮屏与锁屏/熄屏均可靠，避免 UIKit 与 AudioServices 叠加成两次触感。
        for(NSInteger i=0;i<repeats;i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(i*0.28*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ AudioServicesPlaySystemSound(1519); });
    }
}

- (void)takePhoto {
    if(![self boolPref:SCPhotoKey def:YES]) { [self reportStatus:@"拍照功能已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
    dispatch_async(_queue, ^{
        if(![self boolPref:@"Enabled" def:NO]) { [self reportStatus:@"功能总开关已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if([self blockedByPlayback]) { [self reportStatus:@"播放音视频中，已阻止拍照" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if(![self presentSessionForVideo:NO]) { [self reportStatus:self.lastPrepareError?:@"相机启动失败" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        [self whenSessionReadyAttempt:0 action:^{
            AVCapturePhotoSettings *s=[AVCapturePhotoSettings photoSettings];
            if([self boolPref:@"PhotoSilent" def:YES]) {
                SEL silentSelector=NSSelectorFromString(@"setShutterSound:");
                if(![s respondsToSelector:silentSelector]) silentSelector=NSSelectorFromString(@"_setShutterSound:");
                if([s respondsToSelector:silentSelector]) ((void(*)(id,SEL,BOOL))objc_msgSend)(s,silentSelector,NO);
            }
            [self.photoOutput capturePhotoWithSettings:s delegate:self];
        }];
    });
}
// 受 takePhoto 使用；实际 prepare 由 -prepare: 完成
- (BOOL)presentSessionForVideo:(BOOL)video { return [self prepare:video]; }

- (void)toggleVideo {
    dispatch_async(_queue, ^{
        if(![self boolPref:SCVideoKey def:YES]) { [self reportStatus:@"录像功能已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if(![self boolPref:@"Enabled" def:NO]) { [self reportStatus:@"功能总开关已关闭" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if([self blockedByPlayback]) { [self reportStatus:@"播放音视频中，已阻止录像" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        if(self.videoDesired){ self.videoDesired=NO;self.userStopping=YES;self.recoveryScheduled=NO;[self reportStatus:@"录像停止请求已接受" hapticStyle:UIImpactFeedbackStyleLight repeats:0];if(self.movieOutput.isRecording)[self.movieOutput stopRecording];else [self stopAndRelease];return; }
       self.videoDesired=YES;self.userStopping=NO;self.restartAttempts=0;self.sessionInterrupted=NO;[self.videoSegments removeAllObjects];
        if(![self prepare:YES]) { self.videoDesired=NO;[self reportStatus:self.lastPrepareError?:@"相机启动失败" hapticStyle:UIImpactFeedbackStyleLight repeats:0]; return; }
        [self whenSessionReadyAttempt:0 action:^{
            if(!self.videoDesired||self.userStopping)return;
            NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.mov",NSUUID.UUID.UUIDString];
            self.movieURL=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:n]];
            [self.movieOutput startRecordingToOutputFileURL:self.movieURL recordingDelegate:self];
            [self setRecordingState:YES];
            self.startFeedbackSent=YES;
            [self reportStatus:@"录像启动请求已接受" hapticStyle:UIImpactFeedbackStyleHeavy repeats:0];
        }];
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
        if(result) [self reportStatus:[NSString stringWithFormat:@"拍照成功：%@",result] hapticStyle:UIImpactFeedbackStyleMedium repeats:0];
        else [self reportStatus:@"拍照保存失败" hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    } else { [self reportStatus:[NSString stringWithFormat:@"拍照失败：%@",error.localizedDescription?:@"未知错误"] hapticStyle:UIImpactFeedbackStyleLight repeats:0]; }
    [self stopAndRelease];
}
- (void)setRecordingState:(BOOL)rec {
    self.recording=rec;
    SCWritePreference(@"Recording", @(rec));
    notify_post("com.spark.SneakyCam.recordingstatechanged");
}
- (void)captureOutput:(AVCaptureFileOutput *)o didStartRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c {
    [self setRecordingState:YES];
    self.startFeedbackSent=YES;
    [self reportStatus:@"录像已开始" hapticStyle:UIImpactFeedbackStyleHeavy repeats:0];
}
- (void)mergeVideoSegments:(NSArray<NSURL *> *)segments completion:(void(^)(NSURL *url,NSError *error))completion {
    NSMutableArray<NSURL *> *valid=[NSMutableArray array];
    for(NSURL *u in segments) if(u && [[NSFileManager defaultManager] fileExistsAtPath:u.path]) [valid addObject:u];
    if(valid.count==0){ if(completion)completion(nil,[NSError errorWithDomain:@"SneakyCam" code:1 userInfo:@{NSLocalizedDescriptionKey:@"没有可用录像片段"}]);return; }
    if(valid.count==1){ if(completion)completion(valid.firstObject,nil);return; }
    AVMutableComposition *composition=[AVMutableComposition composition];
    AVMutableCompositionTrack *videoTrack=[composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *audioTrack=[composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTime cursor=kCMTimeZero;NSError *insertError=nil;
    for(NSURL *u in valid){
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:u options:nil];CMTime duration=asset.duration;if(!CMTIME_IS_NUMERIC(duration)||CMTimeCompare(duration,kCMTimeZero)<=0)continue;
        AVAssetTrack *v=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;if(v){[videoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero,duration) ofTrack:v atTime:cursor error:&insertError];videoTrack.preferredTransform=v.preferredTransform;}
        AVAssetTrack *a=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;if(a)[audioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero,duration) ofTrack:a atTime:cursor error:nil];
        if(insertError)break;cursor=CMTimeAdd(cursor,duration);
    }
    if(insertError){if(completion)completion(nil,insertError);return;}
    NSURL *out=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"SneakyCam-Merged-%@.mov",NSUUID.UUID.UUIDString]]];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
    AVAssetExportSession *exporter=[[AVAssetExportSession alloc]initWithAsset:composition presetName:AVAssetExportPresetPassthrough];exporter.outputURL=out;exporter.outputFileType=AVFileTypeQuickTimeMovie;exporter.shouldOptimizeForNetworkUse=YES;
    [exporter exportAsynchronouslyWithCompletionHandler:^{ dispatch_async(self.queue,^{ if(exporter.status==AVAssetExportSessionStatusCompleted){if(completion)completion(out,nil);}else{if(completion)completion(nil,exporter.error?:[NSError errorWithDomain:@"SneakyCam" code:2 userInfo:@{NSLocalizedDescriptionKey:@"片段合并失败"}]);} }); }];
}
- (void)removeVideoSegments:(NSArray<NSURL *> *)segments except:(NSURL *)keep { for(NSURL *u in segments)if(u&&![u isEqual:keep])[[NSFileManager defaultManager]removeItemAtURL:u error:nil]; }
- (void)captureOutput:(AVCaptureFileOutput *)o didFinishRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c error:(NSError *)e {
    [self setRecordingState:NO];
    BOOL frameworkSaysFinished=[e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue];
    NSDictionary *attrs=u?[[NSFileManager defaultManager]attributesOfItemAtPath:u.path error:nil]:nil;
    BOOL validSegment=u && [attrs[NSFileSize] unsignedLongLongValue]>0 && (!e||frameworkSaysFinished);
    if(validSegment&&![[self.videoSegments valueForKey:@"path"] containsObject:u.path])[self.videoSegments addObject:u];
    BOOL shouldRecover=self.videoDesired&&!self.userStopping&&[self keepLockScreenRecording];
    [self stopAndRelease];
    if(shouldRecover){
        [self reportStatus:[NSString stringWithFormat:@"已缓存第 %lu 段，准备恢复录像",(unsigned long)self.videoSegments.count] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),self.queue,^{[self scheduleVideoRecovery:e.localizedDescription?:@"屏幕状态切换导致录制停止"];});
        return;
    }
    self.videoDesired=NO;self.userStopping=NO;self.restartAttempts=0;
    NSArray<NSURL *> *segments=[self.videoSegments copy];
    if(!validSegment&&segments.count==0){[self reportStatus:[NSString stringWithFormat:@"录像失败：%@",e.localizedDescription?:@"未生成有效片段"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];return;}
    [self reportStatus:[NSString stringWithFormat:@"正在合并 %lu 个录像片段",(unsigned long)segments.count] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
    [self mergeVideoSegments:segments completion:^(NSURL *merged,NSError *mergeError){
        if(!merged){[self reportStatus:[NSString stringWithFormat:@"录像合并失败：%@",mergeError.localizedDescription?:@"未知错误"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];return;}
        if([self boolPref:@"SaveToRoot" def:NO]){
            NSString *dir=@"/var/mobile/Downloads";[[NSFileManager defaultManager]createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *target=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"SneakyCam-%@.mov",NSUUID.UUID.UUIDString]];NSError *moveError=nil;BOOL ok=[[NSFileManager defaultManager]moveItemAtURL:merged toURL:[NSURL fileURLWithPath:target] error:&moveError];
            [self removeVideoSegments:segments except:nil];[self.videoSegments removeAllObjects];
            [self reportStatus:ok?[NSString stringWithFormat:@"录像已保存：%@",target]:[NSString stringWithFormat:@"录像保存失败：%@",moveError.localizedDescription?:@"未知错误"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];
        }else{
            [[PHPhotoLibrary sharedPhotoLibrary]performChanges:^{[PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:merged];} completionHandler:^(BOOL ok,NSError *x){dispatch_async(self.queue,^{[self removeVideoSegments:segments except:nil];[[NSFileManager defaultManager]removeItemAtURL:merged error:nil];[self.videoSegments removeAllObjects];[self reportStatus:ok?@"录像已保存到系统相册":[NSString stringWithFormat:@"录像保存失败：%@",x.localizedDescription?:@"未知错误"] hapticStyle:UIImpactFeedbackStyleLight repeats:0];});}];
        }
    }];
}

- (void)stopAndRelease {
    dispatch_async(_queue, ^{
        if(self.movieOutput && self.movieOutput.isRecording){ [self.movieOutput stopRecording]; return; }
        if(self.session){ [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:self.session]; [self.session stopRunning];
            if(self.audioInput && [self.session.inputs containsObject:self.audioInput]) [self.session removeInput:self.audioInput];
            if(self.videoInput && [self.session.inputs containsObject:self.videoInput]) [self.session removeInput:self.videoInput];
            for(AVCaptureOutput *out in self.session.outputs) [self.session removeOutput:out];
        }
        self.audioInput=nil; self.videoInput=nil; self.photoOutput=nil; self.movieOutput=nil; self.session=nil; self.movieURL=nil; self.startFeedbackSent=NO;
        [self setRecordingState:NO];
    });
}
@end

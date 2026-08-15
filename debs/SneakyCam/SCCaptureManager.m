#import "SCCaptureManager.h"
#import "SCPaths.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <math.h>

@interface SCCaptureManager () <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate>
@property dispatch_queue_t queue;
@property AVCaptureSession *session;
@property AVCapturePhotoOutput *photoOutput;
@property AVCaptureMovieFileOutput *movieOutput;
@property NSURL *movieURL;
@property BOOL recording;
@end

@implementation SCCaptureManager
+ (instancetype)shared { static id x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (instancetype)init { if((self=[super init])) _queue=dispatch_queue_create("com.spark.sneakycam.capture", DISPATCH_QUEUE_SERIAL); return self; }
- (NSDictionary *)prefs { return SCReadPreferences(); }

- (AVCaptureDevice *)videoDevice {
    BOOL wantsFront=[self.prefs[@"CameraDevice"] isEqual:@"AVCaptureDevicePositionFront"];
    AVCaptureDevicePosition wanted=wantsFront?AVCaptureDevicePositionFront:AVCaptureDevicePositionBack;
    AVCaptureDeviceDiscoverySession *discovery=[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
    for(AVCaptureDevice *device in discovery.devices) if(device.position==wanted) return device;
    // iPad、单摄设备或首选镜头暂不可用时，回退到任意可用摄像头。
    AVCaptureDevice *fallback=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    return fallback ?: discovery.devices.firstObject;
}

- (void)selectSupportedPresetForSession:(AVCaptureSession *)session {
    NSString *requested=self.prefs[@"VideoQuality"] ?: AVCaptureSessionPreset1920x1080;
    NSArray<NSString *> *fallbacks=@[requested, AVCaptureSessionPreset3840x2160, AVCaptureSessionPreset1920x1080, AVCaptureSessionPreset1280x720, AVCaptureSessionPreset640x480, AVCaptureSessionPresetMedium, AVCaptureSessionPresetLow];
    NSMutableSet *seen=[NSMutableSet set];
    for(NSString *preset in fallbacks){
        if(!preset || [seen containsObject:preset]) continue;
        [seen addObject:preset];
        if([session canSetSessionPreset:preset]) { session.sessionPreset=preset; return; }
    }
}

- (void)configureFrameRateForDevice:(AVCaptureDevice *)device {
    NSInteger requested=[self.prefs[@"FrameRate"] integerValue];
    if(requested<=0) requested=60;
    AVFrameRateRange *best=nil;
    double selected=0;
    for(AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges){
        double candidate=MIN((double)requested, range.maxFrameRate);
        if(candidate>=range.minFrameRate && candidate>selected){ best=range; selected=candidate; }
    }
    if(!best || selected<=0) return;
    NSError *error=nil;
    if([device lockForConfiguration:&error]){
        CMTime duration=CMTimeMake(1,(int32_t)llround(selected));
        device.activeVideoMinFrameDuration=duration;
        device.activeVideoMaxFrameDuration=duration;
        [device unlockForConfiguration];
    }
}

- (void)addMicrophoneToSession:(AVCaptureSession *)session {
    for(AVCaptureInput *input in session.inputs)
        for(AVCaptureInputPort *port in input.ports)
            if([port.mediaType isEqualToString:AVMediaTypeAudio]) return;
    AVCaptureDevice *microphone=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    NSError *audioError=nil;
    AVCaptureDeviceInput *audioInput=microphone ? [AVCaptureDeviceInput deviceInputWithDevice:microphone error:&audioError] : nil;
    if(audioInput && [session canAddInput:audioInput]) [session addInput:audioInput];
}

- (BOOL)prepare:(BOOL)video {
    if(_session){
        if(video){
            [_session beginConfiguration];
            [self addMicrophoneToSession:_session];
            [_session commitConfiguration];
        }
        return YES;
    }
    AVCaptureDevice *camera=[self videoDevice];
    if(!camera) return NO;
    NSError *videoError=nil;
    AVCaptureDeviceInput *videoInput=[AVCaptureDeviceInput deviceInputWithDevice:camera error:&videoError];
    if(!videoInput) return NO;

    AVCaptureSession *session=[AVCaptureSession new];
    [session beginConfiguration];
    [self selectSupportedPresetForSession:session];
    if(![session canAddInput:videoInput]) { [session commitConfiguration]; return NO; }
    [session addInput:videoInput];

    // AVCaptureMovieFileOutput 只会写入会话中已有输入所对应的轨道。
    // 录像时动态加入当前设备的默认麦克风；麦克风被占用时仍保留无声录像能力。
    if(video) [self addMicrophoneToSession:session];

    AVCapturePhotoOutput *photo=[AVCapturePhotoOutput new];
    if([session canAddOutput:photo]) [session addOutput:photo];
    AVCaptureMovieFileOutput *movie=[AVCaptureMovieFileOutput new];
    if([session canAddOutput:movie]) [session addOutput:movie];
    [session commitConfiguration];

    if((video && ![movie connectionWithMediaType:AVMediaTypeVideo]) || (!video && ![photo connectionWithMediaType:AVMediaTypeVideo])) return NO;
    _session=session; _photoOutput=photo; _movieOutput=movie;
    [self configureFrameRateForDevice:camera];
    [_session startRunning];
    return _session.isRunning;
}

- (void)takePhoto { dispatch_async(_queue, ^{ NSDictionary *p=self.prefs; if(![p[@"Enabled"] ?: @YES boolValue]||![p[@"Photo"] ?: @YES boolValue]||![self prepare:NO])return; AVCapturePhotoSettings *s=[AVCapturePhotoSettings photoSettings]; [self.photoOutput capturePhotoWithSettings:s delegate:self]; }); }
- (void)toggleVideo { dispatch_async(_queue, ^{ NSDictionary *p=self.prefs;if(![p[@"Enabled"] ?: @YES boolValue]||![p[@"Video"] ?: @YES boolValue])return;if(self.movieOutput.isRecording){[self.movieOutput stopRecording];return;}if(![self prepare:YES])return;NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.mov",NSUUID.UUID.UUIDString];self.movieURL=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:n]];[self.movieOutput startRecordingToOutputFileURL:self.movieURL recordingDelegate:self];self.recording=YES; }); }
- (void)saveData:(NSData *)data ext:(NSString *)ext { if([self.prefs[@"SaveToRoot"] boolValue]){NSString *dir=@"/var/mobile/Media/Camera";[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.%@",NSUUID.UUID.UUIDString,ext];[data writeToFile:[dir stringByAppendingPathComponent:n] atomically:YES];return;} [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{PHAssetCreationRequest *r=[PHAssetCreationRequest creationRequestForAsset];[r addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];} completionHandler:nil]; }
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error { NSData *d=photo.fileDataRepresentation;if(d)[self saveData:d ext:@"jpg"];[self stopAndRelease]; }
- (void)captureOutput:(AVCaptureFileOutput *)o didStartRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c { self.recording=YES; }
- (void)captureOutput:(AVCaptureFileOutput *)o didFinishRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c error:(NSError *)e { self.recording=NO;if(!e){if([self.prefs[@"SaveToRoot"] boolValue]){NSString *dir=@"/var/mobile/Media/Camera";[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];[[NSFileManager defaultManager] moveItemAtURL:u toURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:u.lastPathComponent]] error:nil];}else [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{[PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:u];} completionHandler:^(BOOL ok,NSError *x){[[NSFileManager defaultManager] removeItemAtURL:u error:nil];}];}[self stopAndRelease]; }
- (void)stopAndRelease { dispatch_async(_queue, ^{ if(self.movieOutput.isRecording){[self.movieOutput stopRecording];return;}[self.session stopRunning];for(AVCaptureInput *input in self.session.inputs)[self.session removeInput:input];for(AVCaptureOutput *output in self.session.outputs)[self.session removeOutput:output];self.photoOutput=nil;self.movieOutput=nil;self.session=nil;self.movieURL=nil;self.recording=NO; }); }
@end

#import "SCCaptureManager.h"
#import "SCPaths.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>

@interface SCCaptureManager () <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate>
@property dispatch_queue_t queue; @property AVCaptureSession *session; @property AVCapturePhotoOutput *photoOutput; @property AVCaptureMovieFileOutput *movieOutput; @property NSURL *movieURL; @property BOOL recording;
@end
@implementation SCCaptureManager
+ (instancetype)shared { static id x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (instancetype)init { if((self=[super init])) _queue=dispatch_queue_create("com.spark.sneakycam.capture", DISPATCH_QUEUE_SERIAL); return self; }
- (NSDictionary *)prefs { return SCReadPreferences(); }
- (AVCaptureDevice *)device {
    BOOL front=[self.prefs[@"CameraDevice"] isEqual:@"AVCaptureDevicePositionFront"];
    AVCaptureDevicePosition pos=front?AVCaptureDevicePositionFront:AVCaptureDevicePositionBack;
    AVCaptureDeviceDiscoverySession *d=[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:pos]; return d.devices.firstObject;
}
- (BOOL)prepare:(BOOL)video {
    if (_session) return YES; AVCaptureDevice *dev=[self device]; NSError *err=nil; AVCaptureDeviceInput *in=[AVCaptureDeviceInput deviceInputWithDevice:dev error:&err]; if(!in)return NO;
    _session=[AVCaptureSession new]; NSString *preset=self.prefs[@"VideoQuality"] ?: AVCaptureSessionPreset1920x1080; if([_session canSetSessionPreset:preset])_session.sessionPreset=preset;
    if([_session canAddInput:in])[_session addInput:in]; else return NO;
    _photoOutput=[AVCapturePhotoOutput new]; if([_session canAddOutput:_photoOutput])[_session addOutput:_photoOutput];
    _movieOutput=[AVCaptureMovieFileOutput new]; if([_session canAddOutput:_movieOutput])[_session addOutput:_movieOutput];
    NSInteger fps=[self.prefs[@"FrameRate"] integerValue] ?: 60; AVFrameRateRange *chosen=nil; for(AVFrameRateRange *r in dev.activeFormat.videoSupportedFrameRateRanges)if(r.maxFrameRate>=fps){chosen=r;break;} if(chosen&&[dev lockForConfiguration:nil]){dev.activeVideoMinFrameDuration=CMTimeMake(1,(int32_t)fps);dev.activeVideoMaxFrameDuration=CMTimeMake(1,(int32_t)fps);[dev unlockForConfiguration];}
    [_session startRunning]; return YES;
}
- (void)takePhoto { dispatch_async(_queue, ^{ NSDictionary *p=self.prefs; if(![p[@"Enabled"] ?: @YES boolValue]||![p[@"Photo"] ?: @YES boolValue]||![self prepare:NO])return; AVCapturePhotoSettings *s=[AVCapturePhotoSettings photoSettings]; [self.photoOutput capturePhotoWithSettings:s delegate:self]; }); }
- (void)toggleVideo { dispatch_async(_queue, ^{ NSDictionary *p=self.prefs;if(![p[@"Enabled"] ?: @YES boolValue]||![p[@"Video"] ?: @YES boolValue])return;if(self.movieOutput.isRecording){[self.movieOutput stopRecording];return;}if(![self prepare:YES])return;NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.mov",NSUUID.UUID.UUIDString];self.movieURL=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:n]];[self.movieOutput startRecordingToOutputFileURL:self.movieURL recordingDelegate:self];self.recording=YES; }); }
- (void)saveData:(NSData *)data ext:(NSString *)ext {
    if([self.prefs[@"SaveToRoot"] boolValue]){NSString *dir=@"/var/mobile/Media/Camera";[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];NSString *n=[NSString stringWithFormat:@"SneakyCam-%@.%@",NSUUID.UUID.UUIDString,ext];[data writeToFile:[dir stringByAppendingPathComponent:n] atomically:YES];return;}
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{ PHAssetCreationRequest *r=[PHAssetCreationRequest creationRequestForAsset];[r addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];} completionHandler:nil];
}
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error { NSData *d=photo.fileDataRepresentation;if(d)[self saveData:d ext:@"jpg"]; }
- (void)captureOutput:(AVCaptureFileOutput *)o didStartRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c { self.recording=YES; }
- (void)captureOutput:(AVCaptureFileOutput *)o didFinishRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)c error:(NSError *)e { self.recording=NO;if(!e){if([self.prefs[@"SaveToRoot"] boolValue]){NSString *dir=@"/var/mobile/Media/Camera";[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];[[NSFileManager defaultManager] moveItemAtURL:u toURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:u.lastPathComponent]] error:nil];}else [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{[PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:u];} completionHandler:^(BOOL ok,NSError *x){[[NSFileManager defaultManager] removeItemAtURL:u error:nil];}];} }
@end

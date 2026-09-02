#import <Foundation/Foundation.h>
@interface SCCaptureManager : NSObject
+ (instancetype)shared;
- (void)takePhoto;
- (void)toggleVideo;
- (void)toggleAudio;
- (void)terminateAudio;
- (void)terminateCapture;
- (void)stopAndRelease;
@property(nonatomic,readonly,getter=isRecording) BOOL recording;
@end

#import <Foundation/Foundation.h>
@interface SCCaptureManager : NSObject
+ (instancetype)shared;
- (void)takePhoto;
- (void)togglePhoto;
- (void)toggleVideo;
- (void)stopAndRelease;
@property(nonatomic,readonly,getter=isRecording) BOOL recording;
@end

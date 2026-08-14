#import <Foundation/Foundation.h>
@interface SCCaptureManager : NSObject
+ (instancetype)shared;
- (void)takePhoto;
- (void)toggleVideo;
@property(nonatomic,readonly,getter=isRecording) BOOL recording;
@end

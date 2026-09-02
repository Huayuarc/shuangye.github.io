#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <signal.h>
#import <unistd.h>

static volatile sig_atomic_t gStop=0;
static void SCSignalStop(int sig){(void)sig;gStop=1;}

@interface SCAudioCapture : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property(nonatomic,strong) AVCaptureSession *session;
@property(nonatomic,strong) AVCaptureAudioDataOutput *output;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) AVAssetWriter *writer;
@property(nonatomic,strong) AVAssetWriterInput *input;
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,assign) BOOL writerStarted;
@property(nonatomic,assign) BOOL stopping;
@property(nonatomic,assign) NSUInteger packetCount;
@property(nonatomic,strong) NSError *failure;
- (BOOL)startAtPath:(NSString *)path;
- (BOOL)finish;
@end

@implementation SCAudioCapture
- (instancetype)init { if((self=[super init]))_queue=dispatch_queue_create("com.spark.sneakycam.audio.samples",DISPATCH_QUEUE_SERIAL);return self; }
- (BOOL)startAtPath:(NSString *)path {
    self.url=[NSURL fileURLWithPath:path];[[NSFileManager defaultManager]removeItemAtURL:self.url error:nil];
    NSError *error=nil;self.writer=[AVAssetWriter assetWriterWithURL:self.url fileType:AVFileTypeAppleM4A error:&error];
    if(!self.writer){self.failure=error;return NO;}
    AVCaptureDevice *mic=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *micInput=mic?[AVCaptureDeviceInput deviceInputWithDevice:mic error:&error]:nil;
    if(!micInput){self.failure=error;return NO;}
    AVCaptureSession *session=[AVCaptureSession new];[session beginConfiguration];
    if(![session canAddInput:micInput]){[session commitConfiguration];return NO;}[session addInput:micInput];
    self.output=[AVCaptureAudioDataOutput new];if(![session canAddOutput:self.output]){[session commitConfiguration];return NO;}
    [session addOutput:self.output];[self.output setSampleBufferDelegate:self queue:self.queue];[session commitConfiguration];self.session=session;
    [session startRunning];return session.isRunning;
}
- (BOOL)configureWriterFromSample:(CMSampleBufferRef)sample {
    CMFormatDescriptionRef hint=CMSampleBufferGetFormatDescription(sample);const AudioStreamBasicDescription *asbd=hint?CMAudioFormatDescriptionGetStreamBasicDescription(hint):NULL;
    Float64 rate=(asbd&&asbd->mSampleRate>0)?asbd->mSampleRate:48000.0;UInt32 channels=(asbd&&asbd->mChannelsPerFrame>0)?asbd->mChannelsPerFrame:1;
    NSDictionary *settings=@{AVFormatIDKey:@(kAudioFormatMPEG4AAC),AVSampleRateKey:@(rate),AVNumberOfChannelsKey:@(channels),AVEncoderBitRateKey:@128000,AVEncoderAudioQualityKey:@(AVAudioQualityHigh)};
    self.input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings sourceFormatHint:hint];self.input.expectsMediaDataInRealTime=YES;
    if(![self.writer canAddInput:self.input])return NO;[self.writer addInput:self.input];
    if(![self.writer startWriting]){self.failure=self.writer.error;return NO;}
    CMTime pts=CMSampleBufferGetPresentationTimeStamp(sample);[self.writer startSessionAtSourceTime:pts];self.writerStarted=YES;return YES;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    (void)output;(void)connection;if(self.stopping||!CMSampleBufferDataIsReady(sample))return;
    if(!self.writerStarted&&![self configureWriterFromSample:sample]){self.failure=self.writer.error;return;}
    if(self.input.readyForMoreMediaData&&[self.input appendSampleBuffer:sample])self.packetCount++;
    else if(self.writer.status==AVAssetWriterStatusFailed)self.failure=self.writer.error;
}
- (BOOL)finish {
    self.stopping=YES;[self.output setSampleBufferDelegate:nil queue:NULL];if(self.session.isRunning)[self.session stopRunning];
    dispatch_sync(self.queue,^{});
    if(!self.writerStarted||self.packetCount==0){[self.writer cancelWriting];return NO;}
    [self.input markAsFinished];dispatch_semaphore_t sem=dispatch_semaphore_create(0);
    [self.writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(sem);}];
    long waited=dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));
    return waited==0&&self.writer.status==AVAssetWriterStatusCompleted;
}
@end

int main(int argc,const char *argv[]){@autoreleasepool{
    if(argc<2)return 64;NSString *path=[NSString stringWithUTF8String:argv[1]];NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    AVAudioSession *audio=AVAudioSession.sharedInstance;AVAudioSessionCategoryOptions opts=AVAudioSessionCategoryOptionMixWithOthers|AVAudioSessionCategoryOptionAllowBluetooth;
    if(![audio setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:nil]||![audio setActive:YES error:nil])return 65;
    SCAudioCapture *capture=[SCAudioCapture new];if(![capture startAtPath:path]){[audio setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];[fm removeItemAtPath:path error:nil];return 66;}
    signal(SIGINT,SCSignalStop);signal(SIGTERM,SCSignalStop);signal(SIGHUP,SCSignalStop);
    while(!gStop){@autoreleasepool{CFRunLoopRunInMode(kCFRunLoopDefaultMode,.1,true);if(getppid()==1)gStop=1;}}
    BOOL ok=[capture finish];[audio overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
    for(NSInteger i=0;i<5;i++){if([audio setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil])break;usleep(100000);}
    NSDictionary *attrs=[fm attributesOfItemAtPath:path error:nil];if(!ok||[attrs[NSFileSize]unsignedLongLongValue]<1024){[fm removeItemAtPath:path error:nil];return 67;}
    return 0;
}}

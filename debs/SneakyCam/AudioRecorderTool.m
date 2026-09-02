#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <signal.h>
#import <unistd.h>

static AVAudioRecorder *gRecorder;
static volatile sig_atomic_t gStop=0;
static void SCSignalStop(int sig){(void)sig;gStop=1;}

int main(int argc,const char *argv[]){@autoreleasepool{
    if(argc<2)return 64;
    NSString *path=[NSString stringWithUTF8String:argv[1]];
    [[NSFileManager defaultManager]createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    AVAudioSession *session=AVAudioSession.sharedInstance;NSError *error=nil;
    AVAudioSessionCategoryOptions options=AVAudioSessionCategoryOptionMixWithOthers|AVAudioSessionCategoryOptionAllowBluetooth;
    if(![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:options error:&error])return 65;
    if(![session setActive:YES error:&error])return 66;
    NSDictionary *settings=@{AVFormatIDKey:@(kAudioFormatMPEG4AAC),AVSampleRateKey:@44100,AVNumberOfChannelsKey:@1,AVEncoderBitRateKey:@128000,AVEncoderAudioQualityKey:@(AVAudioQualityHigh)};
    gRecorder=[[AVAudioRecorder alloc]initWithURL:[NSURL fileURLWithPath:path] settings:settings error:&error];
    gRecorder.meteringEnabled=YES;
    if(!gRecorder||![gRecorder prepareToRecord]||![gRecorder record]){[session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];return 67;}
    signal(SIGINT,SCSignalStop);signal(SIGTERM,SCSignalStop);signal(SIGHUP,SCSignalStop);
    pid_t parent=getppid();
    while(!gStop&&gRecorder.isRecording){@autoreleasepool{[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];if(parent>1&&kill(parent,0)!=0)gStop=1;}}
    [gRecorder stop];gRecorder=nil;[session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    NSDictionary *attrs=[[NSFileManager defaultManager]attributesOfItemAtPath:path error:nil];if([attrs[NSFileSize]unsignedLongLongValue]<1024){[[NSFileManager defaultManager]removeItemAtPath:path error:nil];return 68;}
    return 0;
}}

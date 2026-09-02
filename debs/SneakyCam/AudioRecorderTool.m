#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <signal.h>
#import <unistd.h>

static const UInt32 kBufferCount=3;
static AudioQueueRef gQueue=NULL;
static AudioQueueBufferRef gBuffers[3]={NULL};
static AudioFileID gFile=NULL;
static AudioStreamBasicDescription gFormat={0};
static SInt64 gPacket=0;
static volatile sig_atomic_t gStop=0;
static volatile sig_atomic_t gStarted=0;

static void SCSignalStop(int sig){(void)sig;gStop=1;}
static void SCCopyMagicCookie(void){
    if(!gQueue||!gFile)return;UInt32 size=0;
    if(AudioQueueGetPropertySize(gQueue,kAudioQueueProperty_MagicCookie,&size)!=noErr||size==0)return;
    void *cookie=malloc(size);if(!cookie)return;
    if(AudioQueueGetProperty(gQueue,kAudioQueueProperty_MagicCookie,cookie,&size)==noErr)
        AudioFileSetProperty(gFile,kAudioFilePropertyMagicCookieData,size,cookie);
    free(cookie);
}
static void SCInputCallback(void *userData,AudioQueueRef queue,AudioQueueBufferRef buffer,const AudioTimeStamp *time,UInt32 packets,const AudioStreamPacketDescription *descs){
    (void)userData;(void)time;
    if(buffer->mAudioDataByteSize>0&&gFile){
        UInt32 count=packets;
        if(count==0&&gFormat.mBytesPerPacket)count=buffer->mAudioDataByteSize/gFormat.mBytesPerPacket;
        if(count>0&&AudioFileWritePackets(gFile,false,buffer->mAudioDataByteSize,descs,gPacket,&count,buffer->mAudioData)==noErr)gPacket+=count;
    }
    if(!gStop)AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
}
static OSStatus SCSetup(NSString *path){
    memset(&gFormat,0,sizeof(gFormat));gFormat.mSampleRate=44100.0;gFormat.mFormatID=kAudioFormatMPEG4AAC;gFormat.mChannelsPerFrame=1;
    UInt32 size=sizeof(gFormat);OSStatus st=AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,0,NULL,&size,&gFormat);if(st!=noErr)return st;
    st=AudioQueueNewInput(&gFormat,SCInputCallback,NULL,NULL,NULL,0,&gQueue);if(st!=noErr)return st;
    UInt32 bitrate=128000;AudioQueueSetProperty(gQueue,kAudioConverterEncodeBitRate,&bitrate,sizeof(bitrate));
    CFURLRef url=(__bridge CFURLRef)[NSURL fileURLWithPath:path];st=AudioFileCreateWithURL(url,kAudioFileM4AType,&gFormat,kAudioFileFlags_EraseFile,&gFile);if(st!=noErr)return st;
    SCCopyMagicCookie();UInt32 bufferSize=32768;
    for(UInt32 i=0;i<kBufferCount;i++){st=AudioQueueAllocateBuffer(gQueue,bufferSize,&gBuffers[i]);if(st!=noErr)return st;st=AudioQueueEnqueueBuffer(gQueue,gBuffers[i],0,NULL);if(st!=noErr)return st;}
    return noErr;
}
static void SCCleanup(BOOL deactivate){
    if(gQueue){AudioQueueStop(gQueue,true);SCCopyMagicCookie();AudioQueueDispose(gQueue,true);gQueue=NULL;}
    if(gFile){AudioFileOptimize(gFile);AudioFileClose(gFile);gFile=NULL;}
    if(deactivate){AVAudioSession *session=AVAudioSession.sharedInstance;[session overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];for(NSInteger i=0;i<5;i++){if([session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil])break;usleep(100000);}}
}
int main(int argc,const char *argv[]){@autoreleasepool{
    if(argc<2)return 64;NSString *path=[NSString stringWithUTF8String:argv[1]];NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    AVAudioSession *session=AVAudioSession.sharedInstance;AVAudioSessionCategoryOptions opts=AVAudioSessionCategoryOptionMixWithOthers|AVAudioSessionCategoryOptionAllowBluetooth;
    if(![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:nil])return 65;
    if(![session setPreferredSampleRate:44100 error:nil]||![session setActive:YES error:nil])return 66;
    OSStatus st=SCSetup(path);if(st!=noErr){SCCleanup(YES);[fm removeItemAtPath:path error:nil];return 67;}
    signal(SIGINT,SCSignalStop);signal(SIGTERM,SCSignalStop);signal(SIGHUP,SCSignalStop);
    st=AudioQueueStart(gQueue,NULL);if(st!=noErr){SCCleanup(YES);[fm removeItemAtPath:path error:nil];return 68;}gStarted=1;
    while(!gStop){@autoreleasepool{CFRunLoopRunInMode(kCFRunLoopDefaultMode,.1,true);if(getppid()==1)gStop=1;}}
    SCCleanup(YES);NSDictionary *attrs=[fm attributesOfItemAtPath:path error:nil];
    if(!gStarted||gPacket<=0||[attrs[NSFileSize]unsignedLongLongValue]<1024){[fm removeItemAtPath:path error:nil];return 69;}
    return 0;
}}

#import <Foundation/Foundation.h>
#import <notify.h>
#import <sys/stat.h>
#import <unistd.h>
#import <CPUthermalPaths.h>
static NSString *RequestDirectory(void){return [[[CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMountRequests")] copy];}
int main(int argc,char *argv[]){@autoreleasepool{
 if(argc<2)return 64;NSString*cmd=S(argv[1]);NSString*path=argc>2?S(argv[2]):nil;
 NSString*dir=RequestDirectory();NSFileManager*fm=NSFileManager.defaultManager;NSError*error=nil;
 if(![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:&error])return 120;chmod(dir.fileSystemRepresentation,0777);
 NSString*identifier=NSUUID.UUID.UUIDString;NSString*request=[dir stringByAppendingPathComponent:[identifier stringByAppendingString:S(".request.plist")]];NSString*response=[dir stringByAppendingPathComponent:[identifier stringByAppendingString:S(".response.plist")]];
 NSMutableDictionary*body=[@{S("command"):cmd}mutableCopy];if(path)body[S("path")]=path;if(![body writeToFile:request atomically:YES])return 121;chmod(request.fileSystemRepresentation,0666);
 // 最长30秒；每0.5秒重发通知，覆盖守护刚启动/通知首次丢失的窗口。
 for(int i=0;i<600;i++){if(i%10==0)notify_post("com.huayuarc.cputhermal/mountRequest");NSDictionary*result=[NSDictionary dictionaryWithContentsOfFile:response];if(result){int code=[result[S("result")]intValue];NSString*storage=[result[S("storagePath")]isKindOfClass:[NSString class]]?result[S("storagePath")]:nil;if([cmd isEqualToString:S("storage-path")]&&code==0&&storage.length)printf("%s\n",storage.UTF8String);[fm removeItemAtPath:response error:nil];return code;}usleep(50000);}
 // 保留 request 供迟到的守护处理，避免客户端超时同时撤销真实操作。
 return 124;
}}

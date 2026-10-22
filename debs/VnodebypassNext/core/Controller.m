// Dopamine rootless only. No implicit vnode hiding or restoration.
// Status may initialize KRW and create the metadata directory/lock, never changes VISSHADOW or reference counts.
#import <Foundation/Foundation.h>
#include "kernel.h"
#include "PathPolicy.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <notify.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *const StateDir=@"/var/run/vnodebypass-next";
static NSString *const Journal=@"/var/run/vnodebypass-next/session.plist";
static NSString *const List=@"/var/jb/usr/share/vnodebypass/hidePathList.plist";
static const uint32_t Shadow=0x8000;
static BOOL kernelReady=NO;
static FILE *protocol=NULL;
static NSString *bootID(void) {
    char s[128]={0}; size_t n=sizeof(s);
    if(sysctlbyname("kern.bootsessionuuid",s,&n,NULL,0)==0 && s[0])return [NSString stringWithUTF8String:s];
    struct timeval tv={0};n=sizeof(tv);
    if(sysctlbyname("kern.boottime",&tv,&n,NULL,0)!=0)return nil;
    return [NSString stringWithFormat:@"%lld:%d",(long long)tv.tv_sec,(int)tv.tv_usec];
}
static int reply(NSString *state,NSString *message,NSUInteger hidden,NSUInteger total,int rc) {
    NSDictionary *v=@{@"state":state,@"message":message?:@"",@"hidden":@(hidden),@"total":@(total),@"version":@"0.4.7-Next-fix1"};
    NSData *d=[NSPropertyListSerialization dataWithPropertyList:v format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    if(!d||!protocol||fwrite(d.bytes,1,d.length,protocol)!=d.length||fflush(protocol)!=0)return 74;
    return rc;
}
static BOOL regularOwned(int fd) {
    struct stat st;return fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==0 && (st.st_mode&0022)==0 && st.st_nlink==1;
}
static NSData *readSecure(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return nil;
    if(!regularOwned(fd)){close(fd);return nil;}
    NSMutableData *d=[NSMutableData data];char b[4096];ssize_t n;
    while((n=read(fd,b,sizeof(b)))>0){[d appendBytes:b length:(NSUInteger)n];if(d.length>4*1024*1024){close(fd);return nil;}}
    close(fd);return n<0?nil:d;
}
static BOOL writeSecure(NSDictionary *j) {
    NSData *d=[NSPropertyListSerialization dataWithPropertyList:j format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!d)return NO;
    NSString *tmp=[StateDir stringByAppendingPathComponent:@"pending.XXXXXX"];
    char name[PATH_MAX];if(![tmp getFileSystemRepresentation:name maxLength:sizeof(name)])return NO;
    int fd=mkstemp(name);if(fd<0)return NO;
    BOOL ok=fchmod(fd,0600)==0;const char *b=d.bytes;size_t left=d.length;
    while(ok&&left){ssize_t n=write(fd,b,left);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}b+=n;left-=(size_t)n;}
    if(ok)ok=fsync(fd)==0;close(fd);
    if(ok)ok=rename(name,Journal.fileSystemRepresentation)==0;
    if(!ok)unlink(name);
    int dir=open(StateDir.fileSystemRepresentation,O_RDONLY|O_DIRECTORY);if(dir>=0){if(fsync(dir)!=0)ok=NO;close(dir);}
    return ok;
}
static BOOL initBackend(void) {
    if(!kernelReady)kernelReady=init_kernel()==0;
    return kernelReady;
}
static BOOL ptrOK(uint64_t p){return (p>>48)==0xffff && (p&7)==0 && p<UINT64_MAX-0x1000 && p>=0xffff000000001000ULL;}
static BOOL pathAllowed(NSString *p) {
    if(![p isKindOfClass:NSString.class]||![p hasPrefix:@"/"]||[p containsString:@".."]||[p containsString:@"\n"]||[p containsString:@"\r"])return NO;
    // Do not shadow broad roots, live bootstrap/runtime dependencies, or Apple binaries.
    if([p hasPrefix:@"/var/jb/"]||[p isEqual:@"/var/jb"]||[p hasPrefix:@"/private/preboot"]||[p hasPrefix:@"/System/"]||[p hasPrefix:@"/bin/"]||[p hasPrefix:@"/sbin/"]||[p hasPrefix:@"/usr/bin/"]||[p hasPrefix:@"/usr/sbin/"]||[p hasPrefix:@"/usr/lib/"]||[p hasPrefix:@"/Library/MobileSubstrate"]||[p hasPrefix:@"/Library/PreferenceBundles"]||[p hasPrefix:@"/Library/BawAppie"]||[p hasPrefix:@"/var/mobile/Library/Preferences/"]||[p hasPrefix:@"/private/var/mobile/Library/Preferences/"]||[p hasPrefix:@"/var/lib/dpkg"]||[p hasPrefix:@"/private/var/lib/dpkg"]||[p hasPrefix:@"/var/lib/apt"]||[p hasPrefix:@"/private/var/lib/apt"]||[p hasPrefix:@"/var/run/"]||[p hasPrefix:@"/tmp/"]||[p hasPrefix:@"/private/var/tmp/"])return NO;
    NSSet *roots=[NSSet setWithArray:@[@"/",@"/var",@"/private",@"/private/var",@"/usr",@"/usr/lib",@"/usr/libexec",@"/Library",@"/Applications",@"/var/lib",@"/var/mobile",@"/var/mobile/Library",@"/var/mobile/Library/Preferences",@"/var/mobile/Library/Caches",@"/var/containers",@"/var/containers/Bundle",@"/etc",@"/private/var/Users"]];
    return ![roots containsObject:p] && VBReviewedPath(p);
}
static NSMutableDictionary *loadJournal(BOOL *exists) {
    struct stat st;*exists=lstat(Journal.fileSystemRepresentation,&st)==0;
    if(!*exists){if(errno!=ENOENT)*exists=YES;return nil;}
    NSData *d=readSecure(Journal);if(!d)return nil;
    id j=[NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
    if(![j isKindOfClass:NSMutableDictionary.class]||![j[@"schema"] isEqual:@1]||![j[@"entries"] isKindOfClass:NSArray.class]||![j[@"boot"] isKindOfClass:NSString.class])return nil;
    if([j[@"entries"] count]>1024)return nil;
    return j;
}
static BOOL entriesValid(NSDictionary *j) {
    NSMutableSet *seen=[NSMutableSet set];
    for(id row in j[@"entries"]){
        if(![row isKindOfClass:NSDictionary.class]||![row[@"vnode"] isKindOfClass:NSNumber.class]||![row[@"flags"] isKindOfClass:NSNumber.class]||![row[@"path"] isKindOfClass:NSString.class]||![row[@"phase"] isKindOfClass:NSString.class]||!ptrOK([row[@"vnode"] unsignedLongLongValue])||[seen containsObject:row[@"vnode"]])return NO;
        if(![@[@"retained",@"hidden",@"released"] containsObject:row[@"phase"]])return NO;
        if([j[@"stage"] isEqual:@"stable"]&&(![row[@"phase"] isEqual:@"hidden"]||([row[@"flags"] unsignedIntValue]&Shadow)))return NO;
        [seen addObject:row[@"vnode"]];
    }
    return YES;
}
static BOOL countHidden(NSDictionary *j,NSUInteger *hidden,NSUInteger *total) {
    *hidden=0;*total=0;
    if(!entriesValid(j)||!initBackend())return NO;
    for(NSDictionary *row in j[@"entries"]){
        if([row[@"phase"] isEqual:@"released"])continue;
        uint64_t v=[row[@"vnode"] unsignedLongLongValue];
        uint32_t use=kread32(v+off_vnode_usecount),io=kread32(v+off_vnode_iocount);
        if(use==0||io==0||use>0x1000000||io>0x1000000)return NO;
        if(kread32(v+off_vnode_vflags)&Shadow)(*hidden)++;
        (*total)++;
    }
    return YES;
}
static int status(NSMutableDictionary *j) {
    if(!j)return reply(@"disabled",@"未启用",0,0,0);
    if(![j[@"stage"] isEqual:@"stable"])return reply(@"error",@"上次操作被中断；保留恢复记录，请完整重启后重新越狱",0,[j[@"entries"] count],1);
    NSUInteger h=0,t=0;if(!countHidden(j,&h,&t))return reply(@"error",@"内核状态核验失败，未把路径不可达当作启用",0,0,1);
    return reply(h==0?@"disabled":h==t?@"enabled":@"mixed",h==0?@"未启用":h==t?@"已启用":@"部分隐藏，建议关闭恢复",h,t,0);
}

static int enable(NSMutableDictionary *old) {
    if(old){NSUInteger h=0,t=0;if(!countHidden(old,&h,&t))return reply(@"error",@"现有恢复记录核验失败",0,0,1);if(h==t&&t)return reply(@"enabled",@"已启用，无重复操作",h,t,0);return reply(@"error",@"存在恢复记录，请先关闭",h,t,1);}
    NSData *listData=readSecure(List);
    NSArray *paths=listData?[NSPropertyListSerialization propertyListWithData:listData options:0 format:NULL error:nil]:nil;
    if(![paths isKindOfClass:NSArray.class]||paths.count==0||paths.count>1024)return reply(@"error",@"路径列表无效",0,0,1);
    if(!initBackend())return reply(@"error",@"Dopamine 内核接口初始化失败",0,0,1);
    NSMutableDictionary *j=[@{@"schema":@1,@"boot":bootID(),@"stage":@"preparing",@"entries":[NSMutableArray array]} mutableCopy];
    if(!writeSecure(j))return reply(@"error",@"创建恢复记录失败，未执行隐藏",0,0,1);
    NSMutableArray *rows=j[@"entries"];NSMutableSet *vnodes=[NSMutableSet set];
    for(NSString *path in paths){
        if(!pathAllowed(path))continue;
        char real[PATH_MAX];if(!realpath(path.fileSystemRepresentation,real))continue;
        NSString *resolved=[NSString stringWithUTF8String:real];if(!pathAllowed(resolved))continue;
        int held=open(real,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
        if(held<0)continue;
        struct stat opened;char actual[PATH_MAX];
        if(fstat(held,&opened)!=0||(!S_ISREG(opened.st_mode)&&!S_ISDIR(opened.st_mode))||fcntl(held,F_GETPATH,actual)!=0||!pathAllowed([NSString stringWithUTF8String:actual])){close(held);continue;}
        uint64_t v=getVnodeAtFD(held);
        if(!ptrOK(v)){close(held);continue;}
        if([vnodes containsObject:@(v)]){close(held);continue;}
        uint32_t f=kread32(v+off_vnode_vflags),u=kread32(v+off_vnode_usecount),io=kread32(v+off_vnode_iocount);
        if((f&Shadow)||!u||!io||u>=0x1000000||io>=0x1000000){close(held);continue;}
        // The vnode reference primitive remains the upstream implementation.
        // Mark the whole transaction non-replayable before any counter write.
        if(kwrite32(v+off_vnode_usecount,u+1)!=0||kwrite32(v+off_vnode_iocount,io+1)!=0){close(held);return reply(@"error",@"保留引用写入失败；需完整重启",0,rows.count,1);}
        if(kread32(v+off_vnode_usecount)!=u+1||kread32(v+off_vnode_iocount)!=io+1){close(held);return reply(@"error",@"引用计数核验失败；保留记录，需完整重启",0,rows.count,1);}
        close(held);
        [vnodes addObject:@(v)];
        [rows addObject:[@{@"path":path,@"vnode":@(v),@"flags":@(f),@"phase":@"retained"} mutableCopy]];
        if(!writeSecure(j))return reply(@"error",@"写入恢复记录失败；需完整重启",0,rows.count,1);
    }
    for(NSMutableDictionary *row in rows){
        uint64_t v=[row[@"vnode"] unsignedLongLongValue];
        if(hide_path(v)!=0)return reply(@"error",@"隐藏写入失败；需完整重启",0,rows.count,1);
        if(!(kread32(v+off_vnode_vflags)&Shadow))return reply(@"error",@"隐藏标志写回核验失败；保留记录",0,rows.count,1);
        row[@"phase"]=@"hidden";
        if(!writeSecure(j))return reply(@"error",@"隐藏记录落盘失败；需完整重启",0,rows.count,1);
    }
    j[@"stage"]=@"stable";
    if(!writeSecure(j))return reply(@"error",@"提交操作状态失败",0,rows.count,1);
    if(rows.count==0){unlink(Journal.fileSystemRepresentation);return reply(@"disabled",@"没有找到可隐藏的非系统路径",0,0,1);}
    notify_post("kr.xsf1re.vnodebypass.next.statechange");return status(j);
}
static int disable(NSMutableDictionary *j) {
    if(!j)return reply(@"disabled",@"未启用，无恢复操作",0,0,0);
    NSUInteger h=0,t=0;if(!countHidden(j,&h,&t))return reply(@"error",@"恢复前核验失败；未释放引用",0,0,1);
    j[@"stage"]=@"restoring";if(!writeSecure(j))return reply(@"error",@"写入恢复事务失败",h,t,1);
    // First restore EVERY visibility bit; only then release retained references.
    for(NSMutableDictionary *row in j[@"entries"]){
        uint64_t v=[row[@"vnode"] unsignedLongLongValue];if(show_path(v)!=0)return reply(@"error",@"可见性恢复写入失败；未释放引用",h,t,1);
        if(kread32(v+off_vnode_vflags)&Shadow)return reply(@"error",@"可见性恢复失败；未释放引用",h,t,1);
    }
    for(NSMutableDictionary *row in j[@"entries"]){
        uint64_t v=[row[@"vnode"] unsignedLongLongValue];
        uint32_t u=kread32(v+off_vnode_usecount),io=kread32(v+off_vnode_iocount);
        if(!u||!io)return reply(@"error",@"引用计数异常，停止恢复",0,t,1);
        if(kwrite32(v+off_vnode_iocount,io-1)!=0||kwrite32(v+off_vnode_usecount,u-1)!=0)return reply(@"error",@"释放引用写入失败；保留记录，请完整重启",0,t,1);
        row[@"phase"]=@"released";
        if(!writeSecure(j))return reply(@"error",@"恢复提交中断；请完整重启，不重复扣减",0,t,1);
    }
    if(unlink(Journal.fileSystemRepresentation)!=0)return reply(@"error",@"恢复记录删除失败；请完整重启",0,t,1);
    notify_post("kr.xsf1re.vnodebypass.next.statechange");return reply(@"disabled",@"已关闭并恢复可见性",0,0,0);
}
int main(int argc,char **argv) {@autoreleasepool {
    int output=dup(STDOUT_FILENO);if(output<0)return 74;
    fcntl(output,F_SETFD,FD_CLOEXEC);protocol=fdopen(output,"w");
    if(!protocol||dup2(STDERR_FILENO,STDOUT_FILENO)<0)return 74;
    if(argc!=2)return reply(@"error",@"Usage: vnodebypass status|enable|disable",0,0,64);
    NSString *cmd=[NSString stringWithUTF8String:argv[1]];
    if(![@[@"status",@"enable",@"disable"] containsObject:cmd])return reply(@"error",@"不支持旧版分步命令",0,0,64);
    if(getuid()!=0||getgid()!=0||geteuid()!=0||getegid()!=0)return reply(@"error",@"需要 persona root 身份",0,0,77);
    struct stat st;
    if(mkdir(StateDir.fileSystemRepresentation,0700)!=0&&errno!=EEXIST)return reply(@"error",@"状态目录创建失败",0,0,1);
    if(lstat(StateDir.fileSystemRepresentation,&st)!=0||!S_ISDIR(st.st_mode)||st.st_uid!=0||(st.st_mode&0077))return reply(@"error",@"状态目录权限异常",0,0,1);
    NSString *lock=[StateDir stringByAppendingPathComponent:@"operation.lock"];
    int fd=open(lock.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0||!regularOwned(fd))return reply(@"error",@"操作锁无效",0,0,1);
    if(flock(fd,LOCK_EX|LOCK_NB)!=0){close(fd);return reply(@"busy",@"另一操作正在进行",0,0,75);}
    BOOL exists=NO;NSMutableDictionary *j=loadJournal(&exists);
    if(exists&&!j){close(fd);return reply(@"error",@"恢复文件损坏；保留原件，请完整重启后排查",0,0,1);}
    NSString *boot=bootID();if(!boot){close(fd);return reply(@"error",@"读取启动会话失败",0,0,1);}
    if(j&&![j[@"boot"] isEqual:boot]){
        // Never replay kernel pointers from a different boot.
        if([cmd isEqual:@"status"]){close(fd);return reply(@"disabled",@"旧启动记录已失效；当前未启用",0,0,0);}
        NSString *archive=[StateDir stringByAppendingPathComponent:@"previous-boot.plist"];
        if(rename(Journal.fileSystemRepresentation,archive.fileSystemRepresentation)!=0){close(fd);return reply(@"error",@"旧启动记录归档失败",0,0,1);}j=nil;
    }
    if(j&&(![j[@"stage"] isEqual:@"stable"]||!entriesValid(j))){close(fd);return reply(@"error",@"上次事务未完整结束；请完整重启后重新越狱，不回放裸地址",0,0,1);}
    // Uploaded release journals have no boot ID. Do not replay or remove them.
    if(lstat("/tmp/vnodebypass.txt",&st)==0){close(fd);return reply(@"legacy",@"发现旧版恢复记录；请先用旧版关闭，再完整重启并重新越狱",0,0,1);}
    if(stat("/var/jb/basebin/libjailbreak.dylib",&st)!=0||!S_ISREG(st.st_mode)||st.st_uid!=0||(st.st_mode&0022)){close(fd);return reply(@"error",@"/var/jb 不可达；未当作启用，请在 Dopamine 中恢复越狱环境",0,0,1);}
    int rc=[cmd isEqual:@"status"]?status(j):[cmd isEqual:@"enable"]?enable(j):disable(j);
    flock(fd,LOCK_UN);close(fd);return rc;
}}

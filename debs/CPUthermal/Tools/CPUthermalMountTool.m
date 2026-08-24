#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

typedef int (*StealUcredFn)(uint64_t, uint64_t *);
typedef int (*InitPPLRWFn)(void);
static NSString *MountListPath(void) { return [CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent].length ? [[[CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMounts.plist")] copy] : nil; }
static NSString *StandardPath(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSString *p = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByStandardizingPath];
    if (![p hasPrefix:S("/")] || [p isEqualToString:S("/")] || [p hasPrefix:S("/var/mobile/Containers/Shared/AppGroup/.jbroot-")]) return nil;
    NSArray *blocked = @[S("/System"), S("/private/preboot"), S("/var/jb"), S("/Applications")];
    for (NSString *root in blocked) if ([p isEqualToString:root]) return nil;
    return p;
}
static NSMutableArray *LoadPaths(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:MountListPath()];
    NSArray *a = [d[S("paths")] isKindOfClass:[NSArray class]] ? d[S("paths")] : nil;
    return a ? [a mutableCopy] : [NSMutableArray array];
}
static BOOL SavePaths(NSArray *paths) {
    NSString *file = MountListPath();
    if (!file) return NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:[file stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    return [@{S("paths"): paths ?: @[]} writeToFile:file atomically:YES];
}
static NSString *StoragePath(NSString *path) {
    NSString *root = CPUthermalCurrentRootHideRoot();
    if (!root.length) return nil;
    return [[root stringByAppendingPathComponent:S("var/lib/cputhermal-mount")] stringByAppendingPathComponent:[path substringFromIndex:1]];
}
static BOOL IsMounted(NSString *path, BOOL ownOnly) {
    struct statfs info = {0};
    if (statfs(path.fileSystemRepresentation, &info) != 0) return NO;
    BOOL point = strcmp(info.f_mntonname, path.fileSystemRepresentation) == 0;
    if (!ownOnly) return point;
    NSString *src = [NSString stringWithUTF8String:info.f_mntfromname];
    NSString *storage = StoragePath(path);
    return point && strcmp(info.f_fstypename, "bindfs") == 0 && storage.length && [[src stringByStandardizingPath] isEqualToString:[storage stringByStandardizingPath]];
}
static int MakeStorageWritable(NSString *storage) {
    NSFileManager *fm=[NSFileManager defaultManager]; NSArray *items=[@[storage] arrayByAddingObjectsFromArray:[fm subpathsAtPath:storage]?:@[]];
    for(NSString *relative in items) {
        NSString *item=[relative isEqualToString:storage]?storage:[storage stringByAppendingPathComponent:relative]; struct stat st={0};
        if(lstat(item.fileSystemRepresentation,&st)!=0)continue; if(S_ISLNK(st.st_mode))continue;
        mode_t mode=st.st_mode&07777; mode|=S_IWUSR|S_IWGRP|S_IWOTH; if(S_ISDIR(st.st_mode))mode|=S_IXUSR|S_IXGRP|S_IXOTH;
        if(chmod(item.fileSystemRepresentation,mode)!=0)return errno;
    }
    return 0;
}
static int PrepareStorage(NSString *path) {
    NSString *storage = StoragePath(path);
    if (!storage.length) return 80;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL directory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&directory] || !directory) return ENOENT;
    if ([fm fileExistsAtPath:storage]) return MakeStorageWritable(storage);
    NSError *error = nil;
    if (![fm createDirectoryAtPath:[storage stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error]) return (int)(error.code ?: EIO);
    NSString *tmp = [storage stringByAppendingString:S(".mounting")];
    [fm removeItemAtPath:tmp error:nil];
    if (![fm copyItemAtPath:path toPath:tmp error:&error]) return (int)(error.code ?: EIO);
    int permissions=MakeStorageWritable(tmp); if(permissions){[fm removeItemAtPath:tmp error:nil];return permissions;}
    if (![fm moveItemAtPath:tmp toPath:storage error:&error]) { [fm removeItemAtPath:tmp error:nil]; return (int)(error.code ?: EIO); }
    return 0;
}
static void *OpenLibjailbreak(void) {
    const char *candidates[] = { jbroot("/basebin/libjailbreak.dylib"), jbroot("/usr/lib/libjailbreak.dylib"), "/var/jb/basebin/libjailbreak.dylib", "/var/jb/usr/lib/libjailbreak.dylib", NULL };
    for (int i=0; candidates[i]; i++) if (access(candidates[i], R_OK)==0) { void *h=dlopen(candidates[i],RTLD_NOW|RTLD_LOCAL); if(h) return h; }
    return NULL;
}
static int WithKernelCredentials(int (^op)(void)) {
    void *h=OpenLibjailbreak(); if(!h) return 90;
    InitPPLRWFn init=(InitPPLRWFn)dlsym(h,"jbdInitPPLRW"); if(init) init();
    StealUcredFn steal=(StealUcredFn)dlsym(h,"jbclient_root_steal_ucred"); if(!steal){dlclose(h);return 91;}
    uint64_t old=0; int r=steal(0,&old); if(r==0){r=op(); int rr=steal(old,NULL); if(r==0&&rr)r=92;} dlclose(h); return r;
}
static NSString *JbctlPath(void) {
    const char *candidates[]={jbroot("/basebin/jbctl"),jbroot("/usr/bin/jbctl"),"/var/jb/basebin/jbctl","/var/jb/usr/bin/jbctl",NULL};
    for(int i=0;candidates[i];i++)if(access(candidates[i],X_OK)==0)return S(candidates[i]); return nil;
}
static int RunJbctl(NSString *command,NSString *path) {
    NSString *tool=JbctlPath(); if(!tool.length)return 230; pid_t pid=0; int status=0;
    char *args[]={(char*)"jbctl",(char*)"internal",(char*)command.UTF8String,(char*)path.fileSystemRepresentation,NULL};
    int r=posix_spawn(&pid,tool.fileSystemRepresentation,NULL,NULL,args,NULL); if(r)return 231; if(waitpid(pid,&status,0)<0)return 232;
    return WIFEXITED(status)?WEXITSTATUS(status):233;
}
static BOOL IsBindfsMounted(NSString *path) { struct statfs i={0}; return statfs(path.fileSystemRepresentation,&i)==0&&strcmp(i.f_mntonname,path.fileSystemRepresentation)==0&&strcmp(i.f_fstypename,"bindfs")==0; }
static int UnmountPath(NSString *path);
static int MountPath(NSString *path) {
    if (!CPUthermalCurrentRootHideRoot().length) return 79;
    if (IsBindfsMounted(path)) {
        // 旧版本使用 MNT_RDONLY；重新挂载时先卸载，切换为可读写 bindfs。
        struct statfs current={0}; if(statfs(path.fileSystemRepresentation,&current)==0&&(current.f_flags&MNT_RDONLY)) { int u=UnmountPath(path); if(u)return u; } else { int p=MakeStorageWritable(StoragePath(path)); return p?100+p:0; }
    }
    if (IsMounted(path,NO)) return EBUSY;
    NSString *storage=StoragePath(path);
    int direct=WithKernelCredentials(^int{ int p=PrepareStorage(path); if(p)return 100+p; int m=mount("bindfs",path.fileSystemRepresentation,0,(void *)storage.fileSystemRepresentation); return m==0?0:200+errno; });
    return (direct==0&&IsBindfsMounted(path))?0:direct;
}
static int UnmountPath(NSString *path) {
    if (!IsMounted(path,NO)) return 0; if(!IsBindfsMounted(path))return EBUSY;
    int official=RunJbctl(S("unmount"),path); if(official==0&&!IsMounted(path,NO))return 0;
    int direct=WithKernelCredentials(^int{ return unmount(path.fileSystemRepresentation,MNT_FORCE)==0?0:200+errno; });
    if(direct==0)return 0; if(official==255||official==64||official==42||official==230)return direct; return official;
}
static int AddPath(NSString *path) { NSMutableArray *a=LoadPaths(); if(![a containsObject:path])[a addObject:path]; if(!SavePaths(a))return EIO; return MountPath(path); }
static int RemovePath(NSString *path) { int r=UnmountPath(path); if(r)return r; NSMutableArray *a=LoadPaths(); [a removeObject:path]; return SavePaths(a)?0:EIO; }
static int RemountAll(void) { int last=0; for(NSString *p in LoadPaths()){int r=MountPath(p);if(r)last=r;} return last; }
static NSString *RequestDirectory(void) { return [[MountListPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMountRequests")]; }
static int ExecuteCommand(NSString *cmd, NSString *rawPath) {
    if ([cmd isEqualToString:S("remount-all")]) return RemountAll();
    NSString *p=StandardPath(rawPath); if(!p)return EINVAL;
    if([cmd isEqualToString:S("add")])return AddPath(p); if([cmd isEqualToString:S("remove")])return RemovePath(p);
    if([cmd isEqualToString:S("mount")])return MountPath(p); if([cmd isEqualToString:S("unmount")])return UnmountPath(p);
    if([cmd isEqualToString:S("status")])return IsMounted(p,YES)?0:1; return 64;
}
static void ProcessRequests(void) {
    NSFileManager *fm=[NSFileManager defaultManager]; NSString *dir=RequestDirectory();
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil]; chmod(dir.fileSystemRepresentation,0777);
    for(NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if(![name hasSuffix:S(".request.plist")])continue; NSString *request=[dir stringByAppendingPathComponent:name];
        NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:request]; if(!d)continue;
        NSString *cmd=[d[S("command")] isKindOfClass:[NSString class]]?d[S("command")]:nil;
        NSString *path=[d[S("path")] isKindOfClass:[NSString class]]?d[S("path")]:nil;
        int result=ExecuteCommand(cmd,path); NSString *base=[name substringToIndex:name.length-[S(".request.plist") length]];
        NSString *response=[dir stringByAppendingPathComponent:[base stringByAppendingString:S(".response.plist")]];
        [@{S("result"):@(result)} writeToFile:response atomically:YES]; chmod(response.fileSystemRepresentation,0666); [fm removeItemAtPath:request error:nil];
    }
}
static void RequestNotification(CFNotificationCenterRef c,void *o,CFStringRef n,const void *x,CFDictionaryRef u){ ProcessRequests(); }
static int Serve(void) {
    if(geteuid()!=0)return EPERM;
    NSFileManager *fm=[NSFileManager defaultManager]; NSString *parent=[RequestDirectory() stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil]; chmod(parent.fileSystemRepresentation,0777);
    RemountAll(); ProcessRequests();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,RequestNotification,(__bridge CFStringRef)S("com.huayuarc.cputhermal/mountRequest"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    CFRunLoopRun(); return 0;
}
int main(int argc,char *argv[]){ @autoreleasepool {
    if(argc<2)return 64; NSString *cmd=S(argv[1]); if([cmd isEqualToString:S("serve")])return Serve();
    if(geteuid()!=0)return EPERM;
    if([cmd isEqualToString:S("list")]){for(NSString *p in LoadPaths())printf("%s\t%s\n",IsMounted(p,YES)?"mounted":"saved",p.UTF8String);return 0;}
    if([cmd isEqualToString:S("remount-all")])return RemountAll(); if(argc!=3)return 64; return ExecuteCommand(cmd,S(argv[2]));
} }

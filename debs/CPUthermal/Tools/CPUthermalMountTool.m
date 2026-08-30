#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <spawn.h>
#import <stdlib.h>
#import <sys/wait.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

typedef int (*StealUcredFn)(uint64_t, uint64_t *);
typedef int (*InitPPLRWFn)(void);
static NSString *MountListPath(void) {
    NSString *currentPref=CPUthermalCurrentPrefPath();
    NSString *current=[[currentPref stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMounts.plist")];
    NSFileManager *fm=[NSFileManager defaultManager];
    if ([fm fileExistsAtPath:current]) return current;
    // RootHide UUID 变化时，挂载记录与偏好相邻存储；从所有旧 UUID 根中取最新有效记录迁移。
    NSString *newest=nil; NSDate *newestDate=nil;
    for (NSString *oldPref in CPUthermalLegacyPrefPaths()) {
        NSString *candidate=[[oldPref stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMounts.plist")];
        NSDictionary *list=[NSDictionary dictionaryWithContentsOfFile:candidate];
        if (![list[S("paths")] isKindOfClass:[NSArray class]]) continue;
        NSDate *date=[fm attributesOfItemAtPath:candidate error:nil][NSFileModificationDate]?:[NSDate distantPast];
        if (!newest || [date compare:newestDate]==NSOrderedDescending) { newest=candidate; newestDate=date; }
    }
    if (newest) { [fm createDirectoryAtPath:[current stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil]; [fm copyItemAtPath:newest toPath:current error:nil]; }
    return current;
}
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
static NSString *MountStorageRoot(void) {
#ifdef CPUTHERMAL_ROOTLESS_MOUNT
    return S("/var/jb");
#else
    return CPUthermalCurrentRootHideRoot();
#endif
}
static NSString *StoragePath(NSString *path) {
    NSString *root = MountStorageRoot();
    if (!root.length || ![path hasPrefix:S("/")]) return nil;
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
    if (!MountStorageRoot().length) return 79;
    if (IsBindfsMounted(path)) {
        struct statfs current={0}; statfs(path.fileSystemRepresentation,&current);
        NSString *source=S(current.f_mntfromname); NSString *expected=StoragePath(path);
        // UUID 变化后旧 bindfs 后备源不能继续沿用：先卸载并在当前动态根重建。
        BOOL sourceMatches=source.length&&expected.length&&[[source stringByStandardizingPath] isEqualToString:[expected stringByStandardizingPath]];
        if ((current.f_flags&MNT_RDONLY)||!sourceMatches) { int u=UnmountPath(path); if(u)return u; }
        else { int p=MakeStorageWritable(expected); return p?100+p:0; }
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
static NSString *SchedulerBackupRoot(void){NSString *root=MountStorageRoot();return root.length?[root stringByAppendingPathComponent:S("var/lib/cputhermal-scheduler-backup")]:nil;}
static void SetExisting(NSMutableDictionary*d,NSString*k,id v){if([d isKindOfClass:NSMutableDictionary.class]&&d[k]!=nil)d[k]=v;}
static id MutableTree(id v){if([v isKindOfClass:NSDictionary.class]){NSMutableDictionary*d=[NSMutableDictionary dictionary];for(id k in v)d[k]=MutableTree(v[k])?:NSNull.null;return d;}if([v isKindOfClass:NSArray.class]){NSMutableArray*a=[NSMutableArray array];for(id x in v)[a addObject:MutableTree(x)?:NSNull.null];return a;}return v;}
static NSMutableArray *FilledNumericArray(NSArray *source, NSNumber *value, BOOL preserveNonPositive) {
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:source.count];
    for(id item in source) {
        if([item isKindOfClass:NSNumber.class] && (!preserveNonPositive || [item doubleValue]>0.0)) [result addObject:value];
        else [result addObject:item?:NSNull.null];
    }
    return result;
}
static NSMutableArray *TemplateMaxLIs(NSArray *source) {
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:source.count];
    NSUInteger positiveIndex=0;
    for(id item in source) {
        if([item isKindOfClass:NSNumber.class] && [item doubleValue]>0.0) {
            [result addObject:positiveIndex++==0?@120:@118];
        } else [result addObject:item?:NSNull.null];
    }
    return result;
}
static void TuneAntiDownclock(id v){
    if([v isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary*d=v;
        // 只覆盖已存在字段，不删除、不新增产品节点，保留 Sensors/hotspots/DecisionTreeTable 的原始规模。
        for(NSString*k in @[S("CPUMaxPower"),S("GPUMaxPower"),S("PackageMaxPower")]) SetExisting(d,k,@65000);
        SetExisting(d,S("dtThermalLevel"),@0);
        // 附件 powerZoneParams 明确关闭 Package 温控控制。
        SetExisting(d,S("usesPackageControl"),@NO);
        // 附件 D64 的防降频目标：热点/强制级别保持 120°C，热陷阱保持 100°C。
        for(NSString*k in @[S("target"),S("alternateTarget"),S("ForcedThermalLevelTarget0"),S("ForcedThermalLevelTarget1"),S("ForcedThermalPressureLevelLightTarget")]) SetExisting(d,k,@120);
        for(NSString*k in @[S("THERMAL_TRAP_LOAD"),S("THERMAL_TRAP_SLEEP")]) SetExisting(d,k,@100);

        // 映射附件高阈值后同时中和 PID，确保热点控制不再输出降频力度。
        if(d[S("target")]!=nil && (d[S("kp")]!=nil || d[S("ki")]!=nil)) {
            SetExisting(d,S("kp"),@0);
            SetExisting(d,S("ki"),@0);
        }
        // 决策树保持数组长度和节点结构，按附件顺序映射为 [120,118,0]；控制力度归零。
        if([d[S("maxLIs")] isKindOfClass:NSArray.class])
            d[S("maxLIs")]=TemplateMaxLIs(d[S("maxLIs")]);
        if([d[S("controlEfforts")] isKindOfClass:NSArray.class])
            d[S("controlEfforts")]=FilledNumericArray(d[S("controlEfforts")],@0,NO);
        // 所有原机型已存在的低功耗/功率目标提升到无限制哨兵，不新增跨机型字段。
        for(NSString*k in d.allKeys) if([k isKindOfClass:NSString.class]) {
            NSString*lower=[k lowercaseString]; id value=d[k];
            BOOL numeric=[value isKindOfClass:NSNumber.class];
            BOOL powerTarget=([lower containsString:S("power")] || [lower containsString:S("wra")]) &&
                ([lower containsString:S("target")] || [lower containsString:S("limit")] ||
                 [lower containsString:S("maximum")] || [lower containsString:S("maxpower")]);
            BOOL lowPowerTarget=[lower containsString:S("lowpowertarget")];
            if(numeric && (powerTarget || lowPowerTarget)) d[k]=@65000;
            if([lower containsString:S("chem")] && [value isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary*limits=[value isKindOfClass:NSMutableDictionary.class] ? value : [value mutableCopy];
                for(id limitKey in limits.allKeys) if([limits[limitKey] isKindOfClass:NSNumber.class]) limits[limitKey]=@65000;
                d[k]=limits;
            }

            // 已存在的热限帧/刷新率上限解除到 120Hz；不触碰时长、采样率等无关字段。
            BOOL frameRate=([lower containsString:S("framerate")] || [lower containsString:S("refresh") ] ||
                            [lower containsString:S("fps")]) &&
                           ([lower containsString:S("limit")] || [lower containsString:S("max")] ||
                            [lower containsString:S("min")] || [lower containsString:S("target")]);
            if(numeric && frameRate) d[k]=@120;
        }
        // 背光热控制保持附件的 101 高阈值和满亮输出。
        if(d[S("level")]!=nil && (d[S("up")]!=nil || d[S("down")]!=nil)) {
            SetExisting(d,S("up"),@101); SetExisting(d,S("down"),@101); SetExisting(d,S("level"),@101);
        }
        for(id x in [d.allValues copy]) TuneAntiDownclock(x);
    } else if([v isKindOfClass:NSArray.class]) for(id x in v) TuneAntiDownclock(x);
}
static BOOL BackupOnce(NSString*f,NSString*n){NSString*d=SchedulerBackupRoot();if(!d.length)return NO;NSFileManager*fm=NSFileManager.defaultManager;[fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];NSString*b=[d stringByAppendingPathComponent:n];return [fm fileExistsAtPath:b]||[fm copyItemAtPath:f toPath:b error:nil];}
static NSString *KillallPath(void) {
    return CPUthermalExistingExecutablePath("/usr/bin/killall", @[
        S("/var/jb/usr/bin/killall"), S("/var/jb/bin/killall"),
        S("/usr/bin/killall"), S("/bin/killall")
    ]);
}
static int RestartThermalMonitor(void){
    NSString *tool=KillallPath(); if(!tool.length)return 2;
    pid_t p=0; char*a[]={(char*)"killall",(char*)"-q",(char*)"thermalmonitord",NULL};
    int r=posix_spawn(&p,tool.fileSystemRepresentation,NULL,NULL,a,NULL);
    // 调度文件已原子写入；只需成功派发重启，不能在守护自身请求线程 waitpid。
    return r;
}
static NSString *CurrentHardwareModel(void) {
    size_t size=0; if(sysctlbyname("hw.model",NULL,&size,NULL,0)!=0 || size<2)return nil;
    char *buffer=calloc(1,size); if(!buffer)return nil;
    NSString *model=nil; if(sysctlbyname("hw.model",buffer,&size,NULL,0)==0 && buffer[0])model=S(buffer);
    free(buffer); return model;
}
static NSString *ModelFile(NSString*t){
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray *names=[fm contentsOfDirectoryAtPath:t error:nil];
    NSString *hardware=CurrentHardwareModel();
    if(hardware.length) {
        NSString *exact=[hardware stringByAppendingString:S("-Info.plist")];
        if([names containsObject:exact])return[t stringByAppendingPathComponent:exact];
    }
    // 目录中只有一份 AP-Info 时安全回退；多份时拒绝猜测，避免修改错误机型。
    NSMutableArray *matches=[NSMutableArray array];
    for(NSString*n in names)if([n hasSuffix:S("AP-Info.plist")])[matches addObject:n];
    return matches.count==1?[t stringByAppendingPathComponent:matches.firstObject]:nil;
}
static BOOL WriteBinaryPlistAtomically(id plist, NSString *path) {
    NSError *error=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
}
static int ApplyAntiDownclockSchedule(void){NSString*t=StoragePath(S("/System/Library/ThermalMonitor"));if(!IsBindfsMounted(S("/System/Library/ThermalMonitor")))return 70;NSString*m=ModelFile(t);if(!m)return 71;if(!BackupOnce(m,S("ThermalModel.original.plist")))return 73;id d=MutableTree([NSDictionary dictionaryWithContentsOfFile:m]);if(![d isKindOfClass:NSMutableDictionary.class])return 74;TuneAntiDownclock(d);if(!WriteBinaryPlistAtomically(d,m))return 75;MakeStorageWritable(t);return RestartThermalMonitor();}
static NSString *BundledD64Path(void){const char*c=jbroot("/usr/local/share/CPUthermal/D64AP-Info.plist");NSMutableArray*a=[NSMutableArray array];if(c&&strlen(c))[a addObject:S(c)];[a addObjectsFromArray:@[S("/var/jb/usr/local/share/CPUthermal/D64AP-Info.plist"),S("/usr/local/share/CPUthermal/D64AP-Info.plist")]];for(NSString*p in a)if([NSFileManager.defaultManager fileExistsAtPath:p])return p;return nil;}
static int ReplaceWithBundledD64(void){NSString*t=StoragePath(S("/System/Library/ThermalMonitor"));if(!IsBindfsMounted(S("/System/Library/ThermalMonitor")))return 70;NSString*m=ModelFile(t),*src=BundledD64Path();if(!m)return 71;if(!src)return 80;NSDictionary*v=[NSDictionary dictionaryWithContentsOfFile:src];if(!v[S("DecisionTreeTable")]||!v[S("Sensors")])return 81;if(!BackupOnce(m,S("ThermalModel.original.plist")))return 73;NSFileManager*fm=NSFileManager.defaultManager;NSString*tmp=[m stringByAppendingString:S(".cputhermal-new")];[fm removeItemAtPath:tmp error:nil];if(![fm copyItemAtPath:src toPath:tmp error:nil])return 85;if(![fm removeItemAtPath:m error:nil]||![fm moveItemAtPath:tmp toPath:m error:nil]){[fm removeItemAtPath:tmp error:nil];return 85;}MakeStorageWritable(t);return RestartThermalMonitor();}
static int RestoreThermalSchedule(void){NSString*d=SchedulerBackupRoot(),*t=StoragePath(S("/System/Library/ThermalMonitor")),*m=ModelFile(t),*b=[d stringByAppendingPathComponent:S("ThermalModel.original.plist")];if(!m||![NSFileManager.defaultManager fileExistsAtPath:b])return 78;[NSFileManager.defaultManager removeItemAtPath:m error:nil];if(![NSFileManager.defaultManager copyItemAtPath:b toPath:m error:nil])return 79;MakeStorageWritable(t);return RestartThermalMonitor();}
static int ExecuteCommand(NSString *cmd, NSString *rawPath) {
    if ([cmd isEqualToString:S("remount-all")]) return RemountAll();
    if ([cmd isEqualToString:S("apply-anti-downclock")]) return ApplyAntiDownclockSchedule();
    if ([cmd isEqualToString:S("replace-bundled-d64")]) return ReplaceWithBundledD64();
    if ([cmd isEqualToString:S("restore-thermal-schedule")]) return RestoreThermalSchedule();
    NSString *p=StandardPath(rawPath); if(!p)return EINVAL;
    if([cmd isEqualToString:S("storage-path")])return StoragePath(p).length?0:ENOENT;
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
        NSMutableDictionary *reply=[@{S("result"):@(result)} mutableCopy]; if(path.length)reply[S("storagePath")]=StoragePath(path)?:S("");
        [reply writeToFile:response atomically:YES]; chmod(response.fileSystemRepresentation,0666); [fm removeItemAtPath:request error:nil];
    }
}
static void RequestNotification(CFNotificationCenterRef c,void *o,CFStringRef n,const void *x,CFDictionaryRef u){ ProcessRequests(); }
static int Serve(void) {
    if(geteuid()!=0)return EPERM;
    NSFileManager *fm=[NSFileManager defaultManager]; NSString *parent=[RequestDirectory() stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil]; chmod(parent.fileSystemRepresentation,0777);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,RequestNotification,(__bridge CFStringRef)S("com.huayuarc.cputhermal/mountRequest"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    // 先接收设置页请求，再后台恢复旧记录；首次大目录复制不阻塞 IPC 监听。
    ProcessRequests();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{ RemountAll(); });
    CFRunLoopRun(); return 0;
}
int main(int argc,char *argv[]){ @autoreleasepool {
    if(argc<2)return 64; NSString *cmd=S(argv[1]); if([cmd isEqualToString:S("serve")])return Serve();
    if(geteuid()!=0)return EPERM;
    if([cmd isEqualToString:S("list")]){for(NSString *p in LoadPaths())printf("%s\t%s\n",IsMounted(p,YES)?"mounted":"saved",p.UTF8String);return 0;}
    if([cmd isEqualToString:S("remount-all")])return RemountAll(); if(argc!=3)return 64; return ExecuteCommand(cmd,S(argv[2]));
} }

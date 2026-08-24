#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mount.h>
#import <sys/stat.h>
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
static int PrepareStorage(NSString *path) {
    NSString *storage = StoragePath(path);
    if (!storage.length) return 80;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL directory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&directory] || !directory) return ENOENT;
    if ([fm fileExistsAtPath:storage]) return 0;
    NSError *error = nil;
    if (![fm createDirectoryAtPath:[storage stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error]) return (int)(error.code ?: EIO);
    NSString *tmp = [storage stringByAppendingString:S(".mounting")];
    [fm removeItemAtPath:tmp error:nil];
    if (![fm copyItemAtPath:path toPath:tmp error:&error]) return (int)(error.code ?: EIO);
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
static int MountPath(NSString *path) {
    if (!CPUthermalCurrentRootHideRoot().length) return 79;
    if (IsMounted(path,YES)) return 0;
    if (IsMounted(path,NO)) return EBUSY;
    NSString *storage=StoragePath(path);
    int r=WithKernelCredentials(^int{ int p=PrepareStorage(path); if(p)return p; return mount("bindfs",path.fileSystemRepresentation,MNT_RDONLY,(void *)storage.fileSystemRepresentation)==0?0:errno; });
    return r ?: (IsMounted(path,YES)?0:99);
}
static int UnmountPath(NSString *path) {
    if (!IsMounted(path,NO)) return 0;
    if (!IsMounted(path,YES)) return EBUSY;
    int r=WithKernelCredentials(^int{ return unmount(path.fileSystemRepresentation,MNT_FORCE)==0?0:errno; });
    return r;
}
static int AddPath(NSString *path) { NSMutableArray *a=LoadPaths(); if(![a containsObject:path])[a addObject:path]; if(!SavePaths(a))return EIO; return MountPath(path); }
static int RemovePath(NSString *path) { int r=UnmountPath(path); if(r)return r; NSMutableArray *a=LoadPaths(); [a removeObject:path]; return SavePaths(a)?0:EIO; }
static int RemountAll(void) { int last=0; for(NSString *p in LoadPaths()){int r=MountPath(p);if(r)last=r;} return last; }
int main(int argc,char *argv[]){ @autoreleasepool {
    if(argc<2)return 64; NSString *cmd=S(argv[1]);
    if([cmd isEqualToString:S("list")]){for(NSString *p in LoadPaths())printf("%s\t%s\n",IsMounted(p,YES)?"mounted":"saved",p.UTF8String);return 0;}
    if([cmd isEqualToString:S("remount-all")])return RemountAll();
    if(argc!=3)return 64; NSString *p=StandardPath(S(argv[2])); if(!p)return EINVAL;
    if([cmd isEqualToString:S("add")])return AddPath(p); if([cmd isEqualToString:S("remove")])return RemovePath(p); if([cmd isEqualToString:S("mount")])return MountPath(p); if([cmd isEqualToString:S("unmount")])return UnmountPath(p); if([cmd isEqualToString:S("status")])return IsMounted(p,YES)?0:1; return 64;
} }

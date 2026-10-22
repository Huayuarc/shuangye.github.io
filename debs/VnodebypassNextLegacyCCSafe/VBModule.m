#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/file.h>
#import <dlfcn.h>
#import <objc/message.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
extern const mach_port_t kIOMainPortDefault;
extern io_registry_entry_t IORegistryEntryFromPath(mach_port_t,const char *);
extern CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t,CFStringRef,CFAllocatorRef,UInt32);
extern kern_return_t IOObjectRelease(io_object_t);

@interface CCUIToggleModule : NSObject
@property(assign,getter=isSelected,nonatomic) BOOL selected;
- (void)refreshState;
@end
@interface UIApplication (VBPrivateEvent)
- (UIEvent *)_currentEvent;
- (UIEvent *)currentEvent;
@end

#define PERSONA_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, gid_t);

static dispatch_queue_t VBQueue;
static BOOL VBBusy;
static NSString *VBHelperPath;

static NSString *VBHex(NSData *data) {
    if(!data.length)return nil;const unsigned char *b=data.bytes;
    NSMutableString *s=[NSMutableString stringWithCapacity:data.length*2];
    for(NSUInteger i=0;i<data.length;i++)[s appendFormat:@"%02lX",(unsigned long)b[i]];
    return s;
}
static NSString *VBLocateHelper(void) {
    io_registry_entry_t e=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/chosen");
    if(!e)return @"/var/jb/usr/bin/vnodebypass";
    CFTypeRef v=IORegistryEntryCreateCFProperty(e,CFSTR("boot-manifest-hash"),NULL,0);IOObjectRelease(e);
    NSString *hash=VBHex(CFBridgingRelease(v));if(!hash)return @"/var/jb/usr/bin/vnodebypass";
    NSString *base=[@"/private/preboot" stringByAppendingPathComponent:hash];
    NSArray *items=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
    for(NSString *n in items)if([n hasPrefix:@"dopamine-"]){
        NSString *p=[[[base stringByAppendingPathComponent:n] stringByAppendingPathComponent:@"procursus/usr/bin"] stringByAppendingPathComponent:@"vnodebypass"];
        if([[NSFileManager defaultManager] isExecutableFileAtPath:p])return p;
    }
    return @"/var/jb/usr/bin/vnodebypass";
}
static int VBRun(NSString *arg) {
    NSString *p=VBHelperPath.length?VBHelperPath:VBLocateHelper();
    if(![[NSFileManager defaultManager] isExecutableFileAtPath:p])return ENOENT;
    posix_spawnattr_t a;int rc=posix_spawnattr_init(&a);if(rc)return rc;
    if(!(rc=posix_spawnattr_set_persona_np(&a,99,PERSONA_OVERRIDE)))rc=posix_spawnattr_set_persona_uid_np(&a,0);
    if(!rc)rc=posix_spawnattr_set_persona_gid_np(&a,0);
    pid_t pid=-1;char *argv[]={(char *)"vnodebypass",(char *)arg.UTF8String,NULL};
    char *env[]={(char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin",NULL};
    if(!rc)rc=posix_spawn(&pid,p.fileSystemRepresentation,NULL,&a,argv,env);
    posix_spawnattr_destroy(&a);if(rc)return rc;
    int st=0;pid_t w;do{w=waitpid(pid,&st,0);}while(w<0&&errno==EINTR);
    if(w<0)return errno;if(WIFSIGNALED(st))return 128+WTERMSIG(st);
    return WIFEXITED(st)?WEXITSTATUS(st):EIO;
}
static UIEvent *VBEvent(void) {
    UIApplication *a=UIApplication.sharedApplication;
    if([a respondsToSelector:@selector(_currentEvent)])return ((id(*)(id,SEL))objc_msgSend)(a,@selector(_currentEvent));
    if([a respondsToSelector:@selector(currentEvent)])return ((id(*)(id,SEL))objc_msgSend)(a,@selector(currentEvent));
    return nil;
}
static BOOL VBRealModuleTouch(void) {
    UIEvent *e=VBEvent();if(!e||e.type!=UIEventTypeTouches)return NO;
    for(UITouch *t in e.allTouches)if(t.phase==UITouchPhaseEnded)return YES;
    return NO;
}

@interface VBModule : CCUIToggleModule @end
@implementation VBModule
+ (void)initialize {if(self==VBModule.class){VBQueue=dispatch_queue_create("kr.xsf1re.vnodebypass.cc.explicit",DISPATCH_QUEUE_SERIAL);VBHelperPath=VBLocateHelper();}}
- (UIImage *)iconGlyph{return [UIImage imageNamed:@"disabled" inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil];}
- (UIImage *)selectedIconGlyph{return [UIImage imageNamed:@"enabled" inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil];}
- (UIColor *)selectedColor{return UIColor.blackColor;}
- (BOOL)isSelected{return access("/var/jb/bin/bash",F_OK)!=0;}
- (void)setSelected:(BOOL)selected {
    // Programmatic state restoration has no ended touch in the current event.
    if(!VBRealModuleTouch())return;
    @synchronized(VBModule.class){if(VBBusy)return;VBBusy=YES;}
    dispatch_async(VBQueue,^{
        int a=0,b=0;
        if(selected){a=VBRun(@"-s");if(!a)b=VBRun(@"-h");}
        else{a=VBRun(@"-xr");if(!a)b=VBRun(@"-R");}
        dispatch_async(dispatch_get_main_queue(),^{
            @synchronized(VBModule.class){VBBusy=NO;}
            [self refreshState];
            (void)a;(void)b;
        });
    });
}
@end

#import <Foundation/Foundation.h>
#import "SJGPaths.h"
#import "SJGSettings.h"
#import "ScriptFeatures.h"
#import "MemoryTrimEngine.h"
#include <notify.h>
#include <stdatomic.h>
#include <sys/stat.h>
#define main SJGBaseMain
#include "main.c"
#undef main
static atomic_bool reloadRequested=true,cleanRequested=false,normalTrimRequested=false,deepTrimRequested=false,autoTrimRequested=false;
static int serviceKQ=-1;
static void wake_helper(void) {
 if(serviceKQ<0) return;
 struct kevent e;EV_SET(&e,1,EVFILT_USER,0,NOTE_TRIGGER,0,NULL);
 (void)kevent(serviceKQ,&e,1,NULL,0,NULL);
}
static int32_t selected_target(NSDictionary *settings,uint64_t ram) {
 (void)settings;
 return sjg_target(ram);
}
static void save_status(NSMutableDictionary *status,pid_t pid,int32_t target,BOOL enabled,NSString *result) {
 status[@"enabled"]=@(enabled);status[@"pid"]=@(pid);status[@"targetMiB"]=@(target);
 status[@"result"]=result;status[@"helper_stopped"]=@([result isEqualToString:@"helper_stopped"]);
 status[@"lastUpdated"]=[NSDate date];status[@"helperPID"]=@(getpid());
 SJGLimits limits={0};SJGProc p;
 if(pid>0 && identity(pid,&p) && read_limits(pid,&limits)==0) {
  status[@"activeMiB"]=@(limits.active);status[@"inactiveMiB"]=@(limits.inactive);
  status[@"activeAttr"]=@(limits.active_attr);status[@"inactiveAttr"]=@(limits.inactive_attr);
 } else { [status removeObjectForKey:@"activeMiB"];[status removeObjectForKey:@"inactiveMiB"]; }
 status[@"script"]=SJGScriptStatus()?:@{};
 NSString *path=SJGStatusPath();
 if(path && SJGWriteStatus(status,NULL)) {
  (void)chmod(path.fileSystemRepresentation,0644);
  (void)notify_post("com.huayuarc.sbjetsamguard.statuschanged");
 }
}
int main(int argc,char **argv) {
 @autoreleasepool {
  if(argc>1) return SJGBaseMain(argc,argv);
  if(geteuid()!=0) return 77;
  listfn=(ListFn)dlsym(RTLD_DEFAULT,"proc_listpids");infofn=(InfoFn)dlsym(RTLD_DEFAULT,"proc_pidinfo");
  pathfn=(PathFn)dlsym(RTLD_DEFAULT,"proc_pidpath");memfn=(MemFn)dlsym(RTLD_DEFAULT,"memorystatus_control");
  if(!listfn||!infofn||!pathfn||!memfn)return 69;
  uint64_t ram=0;size_t size=sizeof(ram);
  if(sysctlbyname("hw.memsize",&ram,&size,NULL,0)!=0 || !sjg_target(ram))return 69;
  struct sigaction sa={0};sa.sa_handler=stop_requested;sigemptyset(&sa.sa_mask);
  sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL);
  serviceKQ=kqueue();if(serviceKQ<0)return 71;
  struct kevent user;EV_SET(&user,1,EVFILT_USER,EV_ADD|EV_CLEAR,0,0,NULL);
  if(kevent(serviceKQ,&user,1,NULL,0,NULL)<0){close(serviceKQ);return 71;}
  dispatch_queue_t notifications=dispatch_queue_create("com.huayuarc.sbjetsamguard.notifications",DISPATCH_QUEUE_SERIAL);
  int settingsToken=-1,cleanToken=-1,normalTrimToken=-1,deepTrimToken=-1,autoTrimToken=-1;
  if(notify_register_dispatch("com.huayuarc.sbjetsamguard.settingschanged",&settingsToken,notifications,^(int token){(void)token;atomic_store(&reloadRequested,true);wake_helper();})!=NOTIFY_STATUS_OK)settingsToken=-1;
  if(notify_register_dispatch("com.huayuarc.sbjetsamguard.cleanCaches",&cleanToken,notifications,^(int token){(void)token;atomic_store(&cleanRequested,true);wake_helper();})!=NOTIFY_STATUS_OK)cleanToken=-1;
  if(notify_register_dispatch("com.huayuarc.sbjetsamguard.trim.normal",&normalTrimToken,notifications,^(int token){(void)token;atomic_store(&normalTrimRequested,true);wake_helper();})!=NOTIFY_STATUS_OK)normalTrimToken=-1;
  if(notify_register_dispatch("com.huayuarc.sbjetsamguard.trim.deep",&deepTrimToken,notifications,^(int token){(void)token;atomic_store(&deepTrimRequested,true);wake_helper();})!=NOTIFY_STATUS_OK)deepTrimToken=-1;
  if(notify_register_dispatch("com.huayuarc.sbjetsamguard.trim.auto",&autoTrimToken,notifications,^(int token){(void)token;atomic_store(&autoTrimRequested,true);wake_helper();})!=NOTIFY_STATUS_OK)autoTrimToken=-1;
  NSDictionary *settings=@{};NSMutableDictionary *status=[NSMutableDictionary dictionary];
  SJGProc tracked={0};pid_t trackedpid=0;unsigned attempts=0;BOOL done=NO,enabled=YES,exitEvents=YES;
  NSTimeInterval lastSettingsPoll=0;
  int32_t target=sjg_target(ram);NSString *result=@"starting";NSDate *lastCleanup=nil;int exitCode=0;
  while(!quitting) {
   @autoreleasepool {
    BOOL refresh=atomic_exchange(&reloadRequested,false);
    NSTimeInterval now=[NSDate date].timeIntervalSince1970;
    if(settingsToken<0 && now-lastSettingsPoll>=60) {refresh=YES;lastSettingsPoll=now;}
    if(refresh) {
     NSDictionary *updated=SJGReadSettings()?:@{};
     if(![updated isEqual:settings]) {attempts=0;done=NO;}
     settings=updated;enabled=settings[@"enabled"]?[settings[@"enabled"] boolValue]:YES;
     target=selected_target(settings,ram);
     SJGApplyScriptSettings(settings);
    }
    SJGProc p;pid_t pid=find_sb(&p);
    if(quitting)break;
    if(pid && (pid!=trackedpid || !same_process(p,tracked))) {
     if(trackedpid){struct kevent e;EV_SET(&e,(uintptr_t)trackedpid,EVFILT_PROC,EV_DELETE,0,0,NULL);(void)kevent(serviceKQ,&e,1,NULL,0,NULL);}
     tracked=p;trackedpid=pid;attempts=0;done=NO;
     struct kevent e;EV_SET(&e,(uintptr_t)pid,EVFILT_PROC,EV_ADD|EV_ONESHOT,NOTE_EXIT,0,NULL);
     exitEvents=kevent(serviceKQ,&e,1,NULL,0,NULL)==0;
     status[@"exitEventUnavailable"]=@(!exitEvents);
    }
    if(!enabled){done=YES;result=@"disabled_next_process_uses_original_limits";}
    else if(!pid){result=@"waiting_for_springboard";}
    else if(!done && attempts<4) {
     SJGLimits before={0},written={0};attempts++;int r=apply(pid,p,target,&before,&written);
     if(r==-1){done=YES;result=@"verified_raised";}
     else if(r==-2){done=YES;result=@"write_sent_verification_failed";}
     else if(r==0){done=YES;result=@"unchanged_existing_or_special_limit";}
     else {
      result=[NSString stringWithFormat:@"error_%d",r];
      if(r==EPERM||r==EACCES||r==ENOSYS||r==EINVAL||r==ECANCELED)done=YES;
     }
     if(attempts>=4){done=YES;if([result hasPrefix:@"error_"])result=[result stringByAppendingString:@"_retry_exhausted"];}
    }
    BOOL deepPending=atomic_exchange(&deepTrimRequested,false);
    BOOL normalPending=atomic_exchange(&normalTrimRequested,false);
    BOOL autoPending=atomic_exchange(&autoTrimRequested,false);
    if((deepPending || normalPending || autoPending) && !quitting) {
     NSString *trimMode=deepPending?@"deep":@"normal";
     NSMutableDictionary *trim=[SJGRunMemoryTrim(trimMode) mutableCopy];
     trim[@"trigger"]=autoPending?@"automatic":@"manual";
     status[@"memoryTrim"]=trim?:@{};
    }
    if(atomic_exchange(&cleanRequested,false) && !quitting) {
     if(lastCleanup && -lastCleanup.timeIntervalSinceNow<60)status[@"cleanup"]=@{@"result":@"rate_limited_wait_60s"};
     else {lastCleanup=[NSDate date];status[@"cleanup"]=SJGCleanCaches(settings)?:@{};}
    }
    if(quitting)break;
    status[@"attempts"]=@(attempts);save_status(status,pid,target,enabled,result);
    struct timespec timeout={done?(exitEvents?60:15):5,0};struct kevent event;
    int n=kevent(serviceKQ,NULL,0,&event,1,&timeout);
    if(n>0 && event.filter==EVFILT_PROC && event.ident==(uintptr_t)trackedpid && (event.fflags&NOTE_EXIT)){trackedpid=0;done=NO;}
    if(n<0 && errno!=EINTR){exitCode=71;break;}
   }
  }
  if(settingsToken>=0)notify_cancel(settingsToken);if(cleanToken>=0)notify_cancel(cleanToken);
  if(normalTrimToken>=0)notify_cancel(normalTrimToken);if(deepTrimToken>=0)notify_cancel(deepTrimToken);
  if(autoTrimToken>=0)notify_cancel(autoTrimToken);
  dispatch_sync(notifications,^{}); /* drain any callback before closing kqueue */
  SJGRestoreScriptSettings();
  save_status(status,trackedpid,target,NO,@"helper_stopped");
  close(serviceKQ);serviceKQ=-1;return exitCode;
 }
}

/* Root launchd helper. No injected dylib, Objective-C UI hooks or signal interception. */
#include "Policy.h"
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/event.h>
#include <sys/time.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
/* Private libproc ABI from XNU 8792.61.2; not available in every public iOS SDK. */
typedef struct {
 uint32_t flags,status,xstatus,pid,ppid;
 uid_t uid; gid_t gid; uid_t ruid; gid_t rgid; uid_t svuid; gid_t svgid;
 uint32_t reserved; char comm[16]; char name[32];
 uint32_t nfiles,pgid,pjobc,tdev,tpgid; int32_t nice;
 uint64_t start_sec,start_usec;
} SJGProc;
_Static_assert(sizeof(SJGProc)==136,"proc_bsdinfo ABI");
typedef int (*ListFn)(uint32_t,uint32_t,void *,int);
typedef int (*InfoFn)(int,int,uint64_t,void *,int);
typedef int (*PathFn)(int,void *,uint32_t);
typedef int (*MemFn)(uint32_t,int,int32_t,void *,size_t);
static ListFn listfn; static InfoFn infofn; static PathFn pathfn; static MemFn memfn;
static const char *sbpath="/System/Library/CoreServices/SpringBoard.app/SpringBoard";
static volatile sig_atomic_t quitting;
static void stop_requested(int sig) { (void)sig; quitting=1; }
static bool identity(pid_t pid,SJGProc *p) {
 char path[4096]; memset(p,0,sizeof(*p)); memset(path,0,sizeof(path));
    return infofn(pid,3,0,p,sizeof(*p))==(int)sizeof(*p) && p->pid==(uint32_t)pid && p->uid==501 &&
        pathfn(pid,path,sizeof(path))>0 && strcmp(path,sbpath)==0;
}
static bool same_process(SJGProc a,SJGProc b) { return a.pid==b.pid && a.start_sec==b.start_sec && a.start_usec==b.start_usec; }
static pid_t find_sb(SJGProc *p) {
 int needed=listfn(1,0,NULL,0);
 if(needed<=0 || needed>1024*1024) return 0;
 int bytes=needed+4096; pid_t *ids=calloc(1,(size_t)bytes);
 if(!ids) return 0;
 int count=listfn(1,0,ids,bytes); pid_t found=0;
 if(count<0 || count>bytes) {free(ids);return 0;}
 for(int i=0; i<count/(int)sizeof(pid_t); i++) if(ids[i]>1 && identity(ids[i],p)) {found=ids[i];break;}
 free(ids); return found;
}
static int read_limits(pid_t pid,SJGLimits *p) {return memfn(8,pid,0,p,sizeof(*p));}
/* Always re-read both identity and limits immediately before writes. */
static int apply(pid_t pid,SJGProc expected,int32_t target,SJGLimits *original,SJGLimits *written) {
 SJGProc now; SJGLimits old,again,next;
 if(quitting) return ECANCELED;
 if(!identity(pid,&now) || !same_process(now,expected)) return ESRCH;
 if(read_limits(pid,&old)!=0) return errno?errno:EIO;
 if(!sjg_plan(old,target,&next)) return 0;
 if(!identity(pid,&now) || !same_process(now,expected)) return ESRCH;
 if(read_limits(pid,&again)!=0) return errno?errno:EIO;
 if(!sjg_equal(old,again)) return EAGAIN; /* Another manager changed limits: retry later. */
 if(quitting) return ECANCELED;
 if(memfn(7,pid,0,&next,sizeof(next))!=0) return errno?errno:EIO;
 *original=old; *written=next;
 SJGLimits verify;
 if(!identity(pid,&now) || !same_process(now,expected)) return -2;
 if(read_limits(pid,&verify)!=0) return -2;
 if(!sjg_equal(verify,next)) return -2; /* Written but unverified: stop, do not repeatedly increase. */
 return -1;
}
int main(int argc,char **argv) {
 bool status=argc==2 && strcmp(argv[1],"--status")==0;
 if(argc>1 && !status) return 64;
 if(geteuid()!=0) {if(status) fprintf(stderr,"root required\n");return 77;}
 listfn=(ListFn)dlsym(RTLD_DEFAULT,"proc_listpids");
 infofn=(InfoFn)dlsym(RTLD_DEFAULT,"proc_pidinfo");
 pathfn=(PathFn)dlsym(RTLD_DEFAULT,"proc_pidpath");
 memfn=(MemFn)dlsym(RTLD_DEFAULT,"memorystatus_control");
 if(!listfn || !infofn || !pathfn || !memfn) return 69;
 uint64_t ram=0; size_t size=sizeof(ram);
 if(sysctlbyname("hw.memsize",&ram,&size,NULL,0)!=0) return 69;
 int32_t target=sjg_target(ram);
 if(target==0) return 69;
 if(status) {
   SJGProc p;SJGLimits limits;pid_t pid=find_sb(&p);
   if(!pid) return 3;
   if(read_limits(pid,&limits)!=0) {perror("GET_MEMLIMIT_PROPERTIES");return 4;}
   printf("SpringBoard pid=%d RAM_MiB=%llu target_MiB=%d active_MiB=%d active_attr=%u inactive_MiB=%d inactive_attr=%u\n",pid,(unsigned long long)(ram/(1024ULL*1024ULL)),target,limits.active,limits.active_attr,limits.inactive,limits.inactive_attr);
   return 0;
 }
 struct sigaction sa;memset(&sa,0,sizeof(sa));sa.sa_handler=stop_requested;sigemptyset(&sa.sa_mask);
 sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL); /* Only helper shutdown, not SpringBoard signals. */
 int kq=kqueue();if(kq<0) return 71;
 SJGProc tracked={0};pid_t trackedpid=0;unsigned attempts=0;bool done=false;
 SJGLimits original={0},written={0};
 while(!quitting) {
   SJGProc p;pid_t pid=find_sb(&p);
   if(pid && (pid!=trackedpid || !same_process(p,tracked))) {
     if(trackedpid) {struct kevent del;EV_SET(&del,(uintptr_t)trackedpid,EVFILT_PROC,EV_DELETE,0,0,NULL);(void)kevent(kq,&del,1,NULL,0,NULL);}
     tracked=p;trackedpid=pid;attempts=0;done=false;
     struct kevent add;EV_SET(&add,(uintptr_t)pid,EVFILT_PROC,EV_ADD|EV_ONESHOT,NOTE_EXIT,0,NULL);
     (void)kevent(kq,&add,1,NULL,0,NULL);
   }
   if(pid && !done && attempts<4) {
     attempts++;int result=apply(pid,p,target,&original,&written);
     if(result==-1 || result==-2) {done=true;}
     else if(result==0 || result==EPERM || result==EACCES || result==ENOSYS || result==EINVAL) done=true;
     if(attempts>=4) done=true;
   }
   if(quitting) break;
   struct timespec timeout={done?60:5,0};struct kevent event;
   int n=kevent(kq,NULL,0,&event,1,&timeout);
   if(n>0 && event.filter==EVFILT_PROC && (event.fflags&NOTE_EXIT)) {trackedpid=0;done=false;}
   if(n<0 && errno!=EINTR) break;
 }
 /* No lowering on uninstall: could immediately kill an over-limit SpringBoard. */
 close(kq);return 0;
}

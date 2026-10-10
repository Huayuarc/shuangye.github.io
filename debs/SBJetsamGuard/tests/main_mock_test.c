/* Includes production main.c with all external OS entrypoints renamed.
 * No Darwin syscall, process inspection, signal installation or real close.
 * Tests use deterministic state/events; static production helpers stay visible. */
#define _POSIX_C_SOURCE 200809L
#define main sjg_daemon_main
#define dlsym mock_dlsym
#define sysctlbyname mock_sysctlbyname
#define geteuid mock_geteuid
#define sigaction mock_sigaction
#define kqueue mock_kqueue
#define kevent mock_kevent
#define close mock_close
#include "../main.c"
typedef struct kevent TestEvent;
typedef struct sigaction TestAction;
#undef main
#undef dlsym
#undef sysctlbyname
#undef geteuid
#undef sigaction
#undef kqueue
#undef kevent
#undef close
#include <assert.h>
#include <limits.h>
static unsigned checks, scenarios, risks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
#define CASE() do { ++scenarios; reset(); } while (0)
#define RISK(name,x) do { CHECK(x); ++risks; printf("KNOWN-RISK reproduced: %s\n",name); } while (0)
static SJGProc proc;
static SJGLimits limits;
static pid_t ids[16];
static int nids, needed_override, count_override;
static int info_calls, path_calls, reads, writes, list_calls;
static int info_bad_size, path_missing, read_errno, read_fail_at, write_errno;
static int info_mutate_at, read_mutate_at, write_reuse, write_rival, verify_mismatch;
static int info_stop_at;
static uid_t effective_uid;
static int symbol_missing, sysctl_error, kqueue_error;
static uint64_t ram;
static int waits, stop_wait, event_exit_wait, replace_wait, replace_same_pid;
static int wait_error_at, wait_errno, additions, deletions, closes, add_errno;
static int wait_durations[16], installed_signals;
static void (*term_handler)(int);
static int mock_list(uint32_t type,uint32_t subtype,void *out,int size) {
 CHECK(type==1 && subtype==0); ++list_calls;
 if(!out) return needed_override!=INT_MIN?needed_override:nids*(int)sizeof(pid_t);
 CHECK(size>=nids*(int)sizeof(pid_t)); memcpy(out,ids,(size_t)nids*sizeof(pid_t));
 return count_override!=INT_MIN?count_override:nids*(int)sizeof(pid_t);
}
static int mock_info(int pid,int flavor,uint64_t arg,void *out,int size) {
 CHECK(flavor==3 && arg==0 && size==(int)sizeof(SJGProc)); ++info_calls;
 if(info_calls==info_mutate_at) ++proc.start_usec;
 if(info_calls==info_stop_at) stop_requested(SIGTERM);
 if(pid!=(int)proc.pid) return 0;
 memcpy(out,&proc,sizeof(proc)); return info_bad_size?size-1:size;
}
static int mock_path(int pid,void *out,uint32_t size) {
 ++path_calls; if(pid!=(int)proc.pid || path_missing==1) return 0;
 const char *p=path_missing==-1?"/tmp/SpringBoard":sbpath;
 /* Alternate exact-path test uses path_missing=2 below. */
 if(path_missing==2) p="/System/Library/CoreServices/SpringBoard.app/SpringBoard.other";
 CHECK(strlen(p)+1<=size); memcpy(out,p,strlen(p)+1); return (int)strlen(p);
}
static int mock_mem(uint32_t command,int pid,int32_t flags,void *out,size_t size) {
 CHECK(pid>1 && flags==0 && size==16);
 if(command==8) {
  ++reads;
  if(reads==read_mutate_at) ++limits.active;
  if(read_errno && (!read_fail_at || reads==read_fail_at)) { errno=read_errno; return -1; }
  memcpy(out,&limits,16); return 0;
 }
 CHECK(command==7); ++writes;
 if(write_reuse) ++proc.start_usec;
 if(write_rival) limits.active=4096;
 if(write_errno) { errno=write_errno; return -1; }
 memcpy(&limits,out,16); if(verify_mismatch) ++limits.inactive;
 return 0;
}
void *mock_dlsym(void *handle,const char *symbol) {
 (void)handle; if(symbol_missing) return NULL;
 if(!strcmp(symbol,"proc_listpids")) return (void *)mock_list;
 if(!strcmp(symbol,"proc_pidinfo")) return (void *)mock_info;
 if(!strcmp(symbol,"proc_pidpath")) return (void *)mock_path;
 if(!strcmp(symbol,"memorystatus_control")) return (void *)mock_mem;
 CHECK(0); return NULL;
}
uid_t mock_geteuid(void) { return effective_uid; }
int mock_sysctlbyname(const char *name,void *out,size_t *size,void *in,size_t insize) {
 CHECK(!strcmp(name,"hw.memsize") && *size==8 && !in && !insize);
 if(sysctl_error) return -1;
 memcpy(out,&ram,8); return 0;
}
int mock_sigaction(int sig,const TestAction *action,TestAction *old) {
 CHECK(!old && (sig==SIGTERM || sig==SIGINT)); ++installed_signals;
 if(sig==SIGTERM) term_handler=action->sa_handler;
 return 0;
}
int mock_kqueue(void) { return kqueue_error?-1:99; }
int mock_close(int fd) { CHECK(fd==99); ++closes; return 0; }
int mock_kevent(int fd,const TestEvent *ch,int nc,TestEvent *ev,int ne,const struct timespec *timeout) {
 CHECK(fd==99);
 if(nc) {
  CHECK(nc==1 && !ev && !ne && !timeout && ch->filter==EVFILT_PROC);
  if(ch->flags&EV_ADD) { ++additions; CHECK(ch->fflags==NOTE_EXIT && (ch->flags&EV_ONESHOT)); }
  if(ch->flags&EV_DELETE) ++deletions;
  if(add_errno) { errno=add_errno; return -1; } return 0;
 }
 CHECK(!ch && ne==1 && timeout); ++waits;
 CHECK(waits<16); wait_durations[waits]=(int)timeout->tv_sec;
 if(waits==replace_wait) { ++proc.start_usec; if(!replace_same_pid) { ++proc.pid; ids[0]=(pid_t)proc.pid; } }
 if(waits==stop_wait) { CHECK(term_handler!=NULL); term_handler(SIGTERM); }
 if(waits==wait_error_at) { errno=wait_errno; return -1; }
 if(waits==event_exit_wait) { *ev=(TestEvent){proc.pid,EVFILT_PROC,0,NOTE_EXIT,0,NULL}; return 1; }
 return 0;
}
static void reset(void) {
 memset(&proc,0,sizeof(proc)); proc.pid=42;proc.uid=501;proc.start_sec=100;proc.start_usec=12;
 limits=(SJGLimits){128,1,256,0}; ids[0]=42;nids=1;needed_override=INT_MIN;count_override=INT_MIN;
 info_calls=path_calls=reads=writes=list_calls=0;info_bad_size=path_missing=read_errno=read_fail_at=write_errno=0;
 info_mutate_at=read_mutate_at=write_reuse=write_rival=verify_mismatch=info_stop_at=0;
 effective_uid=0;symbol_missing=sysctl_error=kqueue_error=0;ram=4ULL*1024*1024*1024;
 waits=0;stop_wait=1;event_exit_wait=replace_wait=replace_same_pid=0;
 wait_error_at=0;wait_errno=0;additions=deletions=closes=add_errno=installed_signals=0;
 memset(wait_durations,0,sizeof(wait_durations));term_handler=NULL;quitting=0;errno=0;
 listfn=mock_list;infofn=mock_info;pathfn=mock_path;memfn=mock_mem;
}
static int run(void) { char *argv[]={"sbjetsamguard",NULL}; return sjg_daemon_main(1,argv); }
int main(void) {
 SJGProc p,expected; SJGLimits old,written;
 CASE(); CHECK(sizeof(SJGProc)==136 && offsetof(SJGProc,start_sec)==120 && offsetof(SJGProc,start_usec)==128);
 CHECK(find_sb(&p)==42 && path_calls==1 && same_process(p,proc));
 CASE(); ids[0]=0;ids[1]=1;ids[2]=-1;ids[3]=41;ids[4]=42;nids=5;CHECK(find_sb(&p)==42 && info_calls==2);
 CASE(); proc.uid=0;CHECK(find_sb(&p)==0 && path_calls==0);
 CASE(); path_missing=-1;CHECK(find_sb(&p)==0);
 CASE(); path_missing=2;CHECK(find_sb(&p)==0);
 CASE(); path_missing=1;CHECK(find_sb(&p)==0);
 CASE(); info_bad_size=1;CHECK(find_sb(&p)==0 && path_calls==0);
 CASE(); nids=0;CHECK(find_sb(&p)==0 && list_calls==1);
 CASE(); needed_override=-1;CHECK(find_sb(&p)==0);
 CASE(); needed_override=1024*1024+1;CHECK(find_sb(&p)==0);
 CASE(); count_override=-1;CHECK(find_sb(&p)==0);
 CASE(); count_override=5000;CHECK(find_sb(&p)==0);
 CASE(); count_override=5;CHECK(find_sb(&p)==42); /* trailing partial pid ignored */
 CASE(); expected=proc;CHECK(apply(42,expected,1024,&old,&written)==-1);
 CHECK(reads==3 && writes==1 && limits.active==1024 && limits.inactive==1024);
 CHECK(limits.active_attr==1 && limits.inactive_attr==0 && old.active==128 && sjg_equal(limits,written));
 CASE(); expected=proc;expected.start_usec++;CHECK(apply(42,expected,1024,&old,&written)==ESRCH && !reads && !writes);
 CASE(); expected=proc;info_mutate_at=2;CHECK(apply(42,expected,1024,&old,&written)==ESRCH && !writes);
 CASE(); expected=proc;read_mutate_at=2;CHECK(apply(42,expected,1024,&old,&written)==EAGAIN && !writes);
 CASE(); expected=proc;read_errno=EIO;CHECK(apply(42,expected,1024,&old,&written)==EIO && !writes);
 CASE(); expected=proc;read_errno=EIO;read_fail_at=2;CHECK(apply(42,expected,1024,&old,&written)==EIO && !writes);
 CASE(); expected=proc;write_errno=EPERM;CHECK(apply(42,expected,1024,&old,&written)==EPERM && writes==1);
 CASE(); expected=proc;read_errno=EIO;read_fail_at=3;CHECK(apply(42,expected,1024,&old,&written)==-2 && writes==1);
 CASE(); expected=proc;verify_mismatch=1;CHECK(apply(42,expected,1024,&old,&written)==-2 && writes==1);
 CASE(); expected=proc;limits=(SJGLimits){2048,0,-1,1};CHECK(apply(42,expected,1024,&old,&written)==0 && !writes);
 CASE(); CHECK(run()==0 && writes==1 && reads==3 && limits.active==1024 && closes==1);
 CHECK(installed_signals==2 && additions==1 && wait_durations[1]==60);
 /* SIGTERM must NOT lower a live SpringBoard's raised limits. */
 CHECK(limits.inactive==1024 && limits.active_attr==1);
 CASE(); read_errno=EIO;stop_wait=6;CHECK(run()==0 && reads==4 && !writes && waits==6);
 CHECK(wait_durations[1]==5 && wait_durations[3]==5 && wait_durations[4]==60);
 CASE(); write_errno=EAGAIN;stop_wait=6;CHECK(run()==0 && writes==4 && reads==8);
 CASE(); read_errno=EPERM;stop_wait=3;CHECK(run()==0 && reads==1 && !writes && wait_durations[1]==60);
 CASE(); verify_mismatch=1;stop_wait=4;CHECK(run()==0 && writes==1 && reads==3);
 CASE(); read_errno=EIO;replace_wait=4;stop_wait=8;CHECK(run()==0 && reads==8 && additions==2 && deletions==1);
 CASE(); read_errno=EIO;replace_wait=4;replace_same_pid=1;stop_wait=8;CHECK(run()==0 && reads==8 && additions==2);
 CASE(); read_errno=EIO;event_exit_wait=4;replace_wait=4;stop_wait=8;CHECK(run()==0 && reads==8 && additions==2);
 CASE(); nids=0;stop_wait=2;CHECK(run()==0 && !reads && !writes && !additions && wait_durations[1]==5);
 CASE(); effective_uid=501;CHECK(run()==77 && !list_calls && !writes && !installed_signals);
 CASE(); symbol_missing=1;CHECK(run()==69 && !list_calls && !writes);
 CASE(); sysctl_error=1;CHECK(run()==69 && !list_calls && !writes);
 CASE(); ram=0;CHECK(run()==69 && !list_calls && !writes);
 CASE(); kqueue_error=1;CHECK(run()==71 && !list_calls && !writes);
 CASE(); { char *argv[]={"sbjetsamguard","--bad",NULL};CHECK(sjg_daemon_main(2,argv)==64 && !list_calls); }
 CASE(); { char *argv[]={"sbjetsamguard","--status",NULL};CHECK(sjg_daemon_main(2,argv)==0 && reads==1 && !writes && !installed_signals); }
 CASE(); { char *argv[]={"sbjetsamguard","--status",NULL};nids=0;CHECK(sjg_daemon_main(2,argv)==3 && !writes); }
 CASE(); wait_error_at=1;wait_errno=EINTR;stop_wait=2;CHECK(run()==0 && writes==1 && waits==2);
 /* Deterministic reproductions: these characterize defects, not safety claims. */
 CASE(); expected=proc;write_reuse=1;int result=apply(42,expected,1024,&old,&written);
 RISK("PID reused after last identity check: cmd7 reaches replacement before verify rejects it",result==-2 && writes==1 && limits.active==1024);
 CASE(); expected=proc;write_rival=1;result=apply(42,expected,1024,&old,&written);
 RISK("external higher limit between final GET and SET is overwritten",result==-1 && limits.active==1024);
 CASE(); add_errno=ESRCH;CHECK(run()==0);
 RISK("kqueue registration failure ignored; helper still writes and sleeps 60s",writes==1 && wait_durations[1]==60);
 CASE(); wait_error_at=1;wait_errno=EBADF;stop_wait=0;result=run();
 RISK("fatal event-loop failure reported as successful exit (launchd will not restart)",result==0 && closes==1);
 CASE(); info_stop_at=1;result=run();
 CHECK(result==0 && writes==0 && !waits); /* Fixed: stop observed before command 7. */
 printf("main mock: %u scenarios, %u checks PASS; %u known-risk reproductions\n",scenarios,checks,risks);
 return 0;
}

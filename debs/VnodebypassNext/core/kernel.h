#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <inttypes.h>
#include <mach-o/loader.h>

extern uint32_t off_p_pid;
extern uint32_t off_p_pfd;
extern uint32_t off_fd_ofiles;
extern uint32_t off_fp_fglob;
extern uint32_t off_fg_data;
extern uint32_t off_vnode_iocount;
extern uint32_t off_vnode_usecount;
extern uint32_t off_vnode_vflags;

extern uint64_t ourproc;

int offset_init();

uint64_t proc_find(pid_t pidToFind);

//get vnode
uint64_t getVnodeAtPath(const char*);
uint64_t getVnodeAtFD(int fd);

//hide and show file using vnode
int hide_path(uint64_t);
int show_path(uint64_t);

//kernel write
int kwrite32(uint64_t va, uint32_t v);
void kwrite64(uint64_t va, uint64_t v);
//kernel read
uint64_t kread64(uint64_t va);
uint32_t kread32(uint64_t va);

int init_kernel(void);
bool isArm64e(void);


NSString *locateJailbreakRoot(void);
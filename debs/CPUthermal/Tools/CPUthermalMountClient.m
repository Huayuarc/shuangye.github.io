#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <CPUthermalPaths.h>
static NSString *ToolPath(void){ return CPUthermalExistingExecutablePath("/usr/local/bin/CPUthermalMountTool",@[S("/var/jb/usr/local/bin/CPUthermalMountTool"),S("/usr/local/bin/CPUthermalMountTool")]); }
int main(int argc,char *argv[]){@autoreleasepool{
 if(argc<2)return 64; NSString *tool=ToolPath(); if(!tool.length)return 127;
 char **args=calloc((size_t)argc+1,sizeof(char*)); args[0]=(char*)"CPUthermalMountTool"; for(int i=1;i<argc;i++)args[i]=argv[i];
 pid_t pid=0; int r=posix_spawn(&pid,tool.fileSystemRepresentation,NULL,NULL,args,NULL); free(args); if(r)return 126; int status=0;if(waitpid(pid,&status,0)<0)return 125;return WIFEXITED(status)?WEXITSTATUS(status):status;
}}

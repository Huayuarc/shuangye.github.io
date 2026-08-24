#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <CPUthermalPaths.h>

@interface CPUthermalMountListController : PSListController
@property(nonatomic,strong) NSArray<NSString*> *paths;
@end
@implementation CPUthermalMountListController
- (NSString *)listPath { return [[CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMounts.plist")]; }
- (NSArray *)loadPaths { NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:[self listPath]]; NSArray *a=[d[S("paths")] isKindOfClass:[NSArray class]]?d[S("paths")]:nil; return a?:@[]; }
- (NSString *)clientPath { return CPUthermalExistingExecutablePath("/usr/local/bin/CPUthermalMountClient",@[S("/var/jb/usr/local/bin/CPUthermalMountClient"),S("/usr/local/bin/CPUthermalMountClient")]); }
- (int)run:(const char *)command path:(NSString *)path {
 NSString *client=[self clientPath]; if(!client.length)return 127; pid_t pid=0; int status=0;
 char *args[4]={(char*)"CPUthermalMountClient",(char*)command,path?(char*)path.fileSystemRepresentation:NULL,NULL};
 int r=posix_spawn(&pid,client.fileSystemRepresentation,NULL,NULL,args,NULL); if(r)return 126; if(waitpid(pid,&status,0)<0)return 125; return WIFEXITED(status)?WEXITSTATUS(status):status;
}
- (BOOL)isMounted:(NSString *)path { return [self run:"status" path:path]==0; }
- (void)reloadList { self.paths=[self loadPaths]; _specifiers=nil; [self reloadSpecifiers]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadList]; }
- (void)alert:(NSString *)title message:(NSString *)message { UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
- (void)addMountPath {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:S("添加挂载路径") message:S("输入 RootHide 中需要持久化的目录绝对路径。首次挂载会复制当前目录内容到隐藏根存储，并以只读 bindfs 挂载。") preferredStyle:UIAlertControllerStyleAlert];
 [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=S("例如 /var/mobile/Library/SomeDirectory");f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
 [a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:S("添加并挂载") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ NSString *p=[[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] stringByStandardizingPath]; int r=[self run:"add" path:p]; if(r) [self alert:S("挂载失败") message:[NSString stringWithFormat:S("返回代码 %d。请确认目录存在、设备运行 RootHide，且该路径未被其他组件挂载。"),r]]; [self reloadList]; }]];
 [self presentViewController:a animated:YES completion:nil];
}
- (void)remountAll { int r=[self run:"remount-all" path:nil]; [self alert:r?S("重新挂载未完成"):S("重新挂载完成") message:r?[NSString stringWithFormat:S("返回代码 %d，请逐项检查路径。"),r]:S("所有已保存路径均已检查并恢复。")]; [self reloadList]; }
- (void)pathTapped:(PSSpecifier *)sp { NSString *p=[sp propertyForKey:S("mountPath")]; BOOL mounted=[self isMounted:p]; UIAlertController *a=[UIAlertController alertControllerWithTitle:p message:mounted?S("该路径当前由 CPUthermal bindfs 挂载。"):S("该路径已保存，但当前未挂载。") preferredStyle:UIAlertControllerStyleActionSheet];
 if(mounted)[a addAction:[UIAlertAction actionWithTitle:S("卸载但保留记录") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){int r=[self run:"unmount" path:p];if(r)[self alert:S("卸载失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];[self reloadList];}]];
 else [a addAction:[UIAlertAction actionWithTitle:S("立即挂载") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){int r=[self run:"mount" path:p];if(r)[self alert:S("挂载失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];[self reloadList];}]];
 [a addAction:[UIAlertAction actionWithTitle:S("卸载并移除记录") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*x){int r=[self run:"remove" path:p];if(r)[self alert:S("移除失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];[self reloadList];}]];
 [a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
- (NSArray *)specifiers { if(!_specifiers){ NSMutableArray *s=[NSMutableArray array]; PSSpecifier *g=[PSSpecifier groupSpecifierWithName:S("RootHide 路径挂载")]; [g setProperty:S("将指定目录的当前内容复制到动态 .jbroot-* 存储，然后以只读 bindfs 挂载；保存的原始路径会在用户空间启动后自动恢复。仅 RootHide 环境启用。") forKey:S("footerText")]; [s addObject:g]; PSSpecifier *add=[PSSpecifier preferenceSpecifierNamed:S("添加挂载路径") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; add->action=@selector(addMountPath); [s addObject:add]; PSSpecifier *remount=[PSSpecifier preferenceSpecifierNamed:S("重新挂载全部") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; remount->action=@selector(remountAll); [s addObject:remount]; self.paths=[self loadPaths]; [s addObject:[PSSpecifier groupSpecifierWithName:[NSString stringWithFormat:S("已保存路径（%lu）"),(unsigned long)self.paths.count]]]; for(NSString *p in self.paths){PSSpecifier *s1=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:S("%@  %@"),[self isMounted:p]?S("●"):S("○"),p] target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];s1->action=@selector(pathTapped:);[s1 setProperty:p forKey:S("mountPath")];[s addObject:s1];} if(!self.paths.count){PSSpecifier *e=[PSSpecifier groupSpecifierWithName:nil];[e setProperty:S("尚未添加路径。") forKey:S("footerText")];[s addObject:e];} _specifiers=[s copy]; } return _specifiers; }
@end

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/mount.h>
#import <string.h>
#import <CPUthermalPaths.h>

@interface CPUthermalMountListController : PSListController
@property(nonatomic,strong) NSArray<NSString*> *paths;
@end
@implementation CPUthermalMountListController
- (BOOL)isRootlessMountBuild {
#ifdef CPUTHERMAL_ROOTLESS_MOUNT
 return YES;
#else
 return NO;
#endif
}
- (NSString *)listPath { return [[CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMounts.plist")]; }
- (NSString *)mountRoot {
#ifdef CPUTHERMAL_ROOTLESS_MOUNT
 return S("/var/jb");
#else
 return CPUthermalCurrentRootHideRoot();
#endif
}
- (NSString *)storagePath:(NSString *)path { NSString *root=[self mountRoot]; return (root.length&&[path hasPrefix:S("/")])?[[root stringByAppendingPathComponent:S("var/lib/cputhermal-mount")] stringByAppendingPathComponent:[path substringFromIndex:1]]:nil; }
- (NSArray *)loadPaths { NSDictionary*d=[NSDictionary dictionaryWithContentsOfFile:[self listPath]]; NSArray*a=[d[S("paths")] isKindOfClass:NSArray.class]?d[S("paths")]:nil; return a?:@[]; }
- (NSString *)clientPath { return CPUthermalExistingExecutablePath("/usr/local/bin/CPUthermalMountClient",@[S("/var/jb/usr/local/bin/CPUthermalMountClient"),S("/usr/local/bin/CPUthermalMountClient")]); }
- (int)run:(const char *)cmd path:(NSString *)path { NSString*c=[self clientPath];if(!c.length)return 127;pid_t pid=0;int st=0;char*args[4]={(char*)"CPUthermalMountClient",(char*)cmd,path?(char*)path.fileSystemRepresentation:NULL,NULL};int r=posix_spawn(&pid,c.fileSystemRepresentation,NULL,NULL,args,NULL);if(r)return 126;if(waitpid(pid,&st,0)<0)return 125;return WIFEXITED(st)?WEXITSTATUS(st):st; }
// 页面状态绝不调用 MountClient status/IPC：避免 Settings 主线程等待 daemon。
- (BOOL)isMounted:(NSString *)path { if(!path.length)return NO;struct statfs s={0};if(statfs(path.fileSystemRepresentation,&s))return NO;if(strcmp(s.f_fstypename,"bindfs")||strcmp(s.f_mntonname,path.fileSystemRepresentation))return NO;NSString*source=S(s.f_mntfromname);NSString*storage=[self storagePath:path];return source.length&&storage.length&&[[source stringByStandardizingPath] isEqualToString:[storage stringByStandardizingPath]]; }
- (void)reloadList { self.paths=[self loadPaths];_specifiers=nil;[self reloadSpecifiers]; }
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self reloadList];}
- (void)alert:(NSString *)t message:(NSString *)m {UIAlertController*a=[UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (void)addThermalMountPaths {int r=[self run:"add" path:S("/System/Library/ThermalMonitor")];[self reloadList];[self alert:r?S("挂载失败"):S("温控路径挂载完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("ThermalMonitor 已保存；用户空间重启或 RootHide UUID 变化后会自动重新建立挂载。")];}
- (void)addMountPath {UIAlertController*a=[UIAlertController alertControllerWithTitle:S("添加其他挂载路径") message:S("首次挂载会复制目录到当前动态隐根后备目录，再以可读写 bindfs 关联。") preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField*f){f.placeholder=S("例如 /var/mobile/Library/SomeDirectory");f.autocapitalizationType=UITextAutocapitalizationTypeNone;}];[a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:S("添加并挂载") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){NSString*p=[[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]stringByStandardizingPath];int r=[self run:"add" path:p];[self reloadList];if(r)[self alert:S("挂载失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];}]];[self presentViewController:a animated:YES completion:nil];}
- (void)remountAll {int r=[self run:"remount-all" path:nil];[self reloadList];[self alert:r?S("重新挂载未完成"):S("重新挂载完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("当前 UUID 的所有保存路径已检查并恢复。")];}
- (void)applyMountedPerformance {int r=[self run:"apply-mounted-performance" path:nil];[self alert:r?S("补丁失败"):S("补丁完成") message:r?[NSString stringWithFormat:S("返回代码 %d；请先确认 ThermalMonitor 已挂载。"),r]:S("当前机型 CPU/GPU/Package 与 ThermalMonitor 配置补丁已应用，并启用解除温控＋高性能模式。")];}
- (void)replaceBundledD64 {int r=[self run:"replace-bundled-d64" path:nil];[self alert:r?S("替换失败"):S("替换完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("内置温控文件已写入当前机型后备目录并重启 thermalmonitord。")];}
- (void)restoreThermalSchedule {int r=[self run:"restore-thermal-schedule" path:nil];[self alert:r?S("恢复失败"):S("恢复完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("已恢复一键替换前的当前机型温控配置并重启 thermalmonitord。")];}
- (void)pathTapped:(PSSpecifier *)sp {NSString*p=[sp propertyForKey:S("mountPath")];BOOL mounted=[self isMounted:p];UIAlertController*a=[UIAlertController alertControllerWithTitle:p message:mounted?S("当前由 CPUthermal 可读写 bindfs 挂载。") : S("已保存但当前未挂载。") preferredStyle:UIAlertControllerStyleActionSheet];[a addAction:[UIAlertAction actionWithTitle:S("在 Filza 中编辑后备目录") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){NSString*storage=[self storagePath:p];NSURL*u=[NSURL URLWithString:[S("filza://view") stringByAppendingString:[storage stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]?:S("")]];if(u)[UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];}]];[a addAction:[UIAlertAction actionWithTitle:mounted?S("卸载但保留记录"):S("立即挂载") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){int r=[self run:mounted?"unmount":"mount" path:p];[self reloadList];if(r)[self alert:S("操作失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];}]];[a addAction:[UIAlertAction actionWithTitle:S("卸载并移除记录") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction*x){int r=[self run:"remove" path:p];[self reloadList];if(r)[self alert:S("移除失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];}]];[a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (NSArray *)specifiers {if(!_specifiers){NSMutableArray*s=[NSMutableArray array];PSSpecifier*g=[PSSpecifier groupSpecifierWithName:[self isRootlessMountBuild]?S("rootless 路径挂载"):S("RootHide 路径挂载")];[g setProperty:S("挂载记录和后备目录会在每次启动时按当前动态 .jbroot-UUID 重新解析。页面状态使用本地 statfs，不会等待守护。") forKey:S("footerText")];[s addObject:g];PSSpecifier*t=[PSSpecifier preferenceSpecifierNamed:S("一键挂载温控路径") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];t->action=@selector(addThermalMountPaths);[s addObject:t];PSSpecifier*a=[PSSpecifier preferenceSpecifierNamed:S("添加其他挂载路径") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];a->action=@selector(addMountPath);[s addObject:a];PSSpecifier*r=[PSSpecifier preferenceSpecifierNamed:S("重新挂载全部") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];r->action=@selector(remountAll);[s addObject:r];[s addObject:[PSSpecifier groupSpecifierWithName:S("温控性能调度")]];PSSpecifier*patch=[PSSpecifier preferenceSpecifierNamed:S("应用 CPU/GPU 与温控配置补丁") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];patch->action=@selector(applyMountedPerformance);[s addObject:patch];PSSpecifier*replace=[PSSpecifier preferenceSpecifierNamed:S("一键替换为内置 温控文件 配置") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];replace->action=@selector(replaceBundledD64);[s addObject:replace];PSSpecifier*restore=[PSSpecifier preferenceSpecifierNamed:S("恢复调度前配置") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];restore->action=@selector(restoreThermalSchedule);[s addObject:restore];self.paths=[self loadPaths];[s addObject:[PSSpecifier groupSpecifierWithName:[NSString stringWithFormat:S("已保存路径（%lu）"),(unsigned long)self.paths.count]]];for(NSString*p in self.paths){PSSpecifier*x=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:S("%@ %@"),[self isMounted:p]?S("●"):S("○"),p] target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];x->action=@selector(pathTapped:);[x setProperty:p forKey:S("mountPath")];[s addObject:x];}_specifiers=[s copy];}return _specifiers;}
@end

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
- (void)optimizeThermal {int r=[self run:"optimize-thermal" path:nil];[self reloadList];[self alert:r?S("优化失败"):S("温控优化完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("已挂载当前机型 ThermalMonitor 后备目录，并用内置优化规则解除 CPU/GPU/Package 功率墙、缓解等级与帧率限制；原配置已备份，可随时恢复。")];}
- (void)cleanupAll {int r=[self run:"cleanup-all" path:nil];[self reloadList];[self alert:r?S("清理未完成"):S("清理完成") message:r?[NSString stringWithFormat:S("返回代码 %d；仍有挂载点未能卸载，后备目录未删除。"),r]:S("已卸载全部 CPUthermal 挂载，并删除记录、调度备份、后备文件夹与临时请求目录。系统原目录未删除。")];}
- (void)restoreThermalSchedule {int r=[self run:"restore-thermal-schedule" path:nil];[self alert:r?S("恢复失败"):S("恢复完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("已恢复一键替换前的当前机型温控配置并重启 thermalmonitord。")];}
- (void)pathTapped:(PSSpecifier *)sp {NSString*p=[sp propertyForKey:S("mountPath")];BOOL mounted=[self isMounted:p];UIAlertController*a=[UIAlertController alertControllerWithTitle:p message:mounted?S("当前由 CPUthermal 可读写 bindfs 挂载。") : S("已保存但当前未挂载。") preferredStyle:UIAlertControllerStyleActionSheet];[a addAction:[UIAlertAction actionWithTitle:S("在 Filza 中编辑后备目录") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){NSString*storage=[self storagePath:p];NSURL*u=[NSURL URLWithString:[S("filza://view") stringByAppendingString:[storage stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]?:S("")]];if(u)[UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];}]];[a addAction:[UIAlertAction actionWithTitle:mounted?S("卸载但保留记录"):S("立即挂载") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){int r=[self run:mounted?"unmount":"mount" path:p];[self reloadList];if(r)[self alert:S("操作失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];}]];[a addAction:[UIAlertAction actionWithTitle:S("卸载并删除记录及后备文件") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction*x){int r=[self run:"remove" path:p];[self reloadList];if(r)[self alert:S("移除失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];}]];[a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (NSArray *)specifiers {if(!_specifiers){NSMutableArray*s=[NSMutableArray array];PSSpecifier*g=[PSSpecifier groupSpecifierWithName:[self isRootlessMountBuild]?S("rootless 路径挂载"):S("RootHide 路径挂载")];[g setProperty:S("记录与后备目录按当前动态 .jbroot-UUID 解析。单项移除会同时删除后备文件夹；“清理全部”会卸载并删除记录、备份与临时请求。") forKey:S("footerText")];[s addObject:g];PSSpecifier*t=[PSSpecifier preferenceSpecifierNamed:S("一键挂载温控路径") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];t->action=@selector(addThermalMountPaths);[s addObject:t];PSSpecifier*a=[PSSpecifier preferenceSpecifierNamed:S("添加其他挂载路径") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];a->action=@selector(addMountPath);[s addObject:a];PSSpecifier*r=[PSSpecifier preferenceSpecifierNamed:S("重新挂载全部") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];r->action=@selector(remountAll);[s addObject:r];PSSpecifier*pg=[PSSpecifier groupSpecifierWithName:S("温控性能调度")];[pg setProperty:S("使用当前机型原始 ThermalMonitor 文件生成后备副本，再应用内置 CPU/GPU/Package 防降频规则；不再用其他机型 D64 文件覆盖。") forKey:S("footerText")];[s addObject:pg];PSSpecifier*opt=[PSSpecifier preferenceSpecifierNamed:S("一键挂载并优化温控") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];opt->action=@selector(optimizeThermal);[s addObject:opt];PSSpecifier*restore=[PSSpecifier preferenceSpecifierNamed:S("恢复优化前配置") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];restore->action=@selector(restoreThermalSchedule);[s addObject:restore];PSSpecifier*clean=[PSSpecifier preferenceSpecifierNamed:S("清理全部挂载与后备文件") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];clean->action=@selector(cleanupAll);[s addObject:clean];self.paths=[self loadPaths];[s addObject:[PSSpecifier groupSpecifierWithName:[NSString stringWithFormat:S("已保存路径（%lu）"),(unsigned long)self.paths.count]]];for(NSString*p in self.paths){PSSpecifier*x=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:S("%@ %@"),[self isMounted:p]?S("●"):S("○"),p] target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];x->action=@selector(pathTapped:);[x setProperty:p forKey:S("mountPath")];[s addObject:x];}_specifiers=[s copy];}return _specifiers;}
@end

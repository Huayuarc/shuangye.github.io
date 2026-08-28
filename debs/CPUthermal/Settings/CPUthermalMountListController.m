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
@property(nonatomic,assign) BOOL operationRunning;
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
- (NSString *)mountStorageRoot {
#ifdef CPUTHERMAL_ROOTLESS_MOUNT
 return S("/var/jb");
#else
 return CPUthermalCurrentRootHideRoot();
#endif
}
- (NSString *)storagePathForMountPath:(NSString *)path { NSString *root=[self mountStorageRoot]; if(!root.length||![path hasPrefix:S("/")])return nil; return [[root stringByAppendingPathComponent:S("var/lib/cputhermal-mount")] stringByAppendingPathComponent:[path substringFromIndex:1]]; }
- (NSArray *)loadPaths { NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:[self listPath]]; NSArray *a=[d[S("paths")] isKindOfClass:[NSArray class]]?d[S("paths")]:nil; return a?:@[]; }
- (NSString *)clientPath { return CPUthermalExistingExecutablePath("/usr/local/bin/CPUthermalMountClient",@[S("/var/jb/usr/local/bin/CPUthermalMountClient"),S("/usr/local/bin/CPUthermalMountClient")]); }
- (int)run:(const char *)command path:(NSString *)path {
 NSString *client=[self clientPath]; if(!client.length)return 127; pid_t pid=0; int status=0;
 char *args[4]={(char*)"CPUthermalMountClient",(char*)command,path?(char*)path.fileSystemRepresentation:NULL,NULL};
 int r=posix_spawn(&pid,client.fileSystemRepresentation,NULL,NULL,args,NULL); if(r)return 126; if(waitpid(pid,&status,0)<0)return 125; return WIFEXITED(status)?WEXITSTATUS(status):status;
}
- (BOOL)isMounted:(NSString *)path {
 if(!path.length)return NO; struct statfs info={0};
 if(statfs(path.fileSystemRepresentation,&info)!=0)return NO;
 if(strcmp(info.f_mntonname,path.fileSystemRepresentation)!=0||strcmp(info.f_fstypename,"bindfs")!=0)return NO;
 NSString *source=[NSString stringWithUTF8String:info.f_mntfromname];
 NSString *storage=[self storagePathForMountPath:path];
 return source.length&&storage.length&&[[source stringByStandardizingPath] isEqualToString:[storage stringByStandardizingPath]];
}
- (void)reloadList { self.paths=[self loadPaths]; _specifiers=nil; [self reloadSpecifiers]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadList]; }
- (void)alert:(NSString *)title message:(NSString *)message { UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
- (void)performCommand:(const char *)command path:(NSString *)path completion:(void(^)(int))completion {
 if(self.operationRunning)return;self.operationRunning=YES;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{int result=[self run:command path:path];dispatch_async(dispatch_get_main_queue(),^{self.operationRunning=NO;if(completion)completion(result);});});
}
- (void)addMountPath {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:S("添加挂载路径") message:S("输入 RootHide 中需要持久化的目录绝对路径。首次挂载会复制当前目录内容到隐藏根存储，为后备副本增加写权限，并以可读写 bindfs 挂载。") preferredStyle:UIAlertControllerStyleAlert];
 [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=S("例如 /var/mobile/Library/SomeDirectory");f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
 [a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:S("添加并挂载") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ NSString *p=[[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] stringByStandardizingPath]; [self performCommand:"add" path:p completion:^(int r){if(r)[self alert:S("挂载失败") message:[NSString stringWithFormat:S("返回代码 %d。请确认挂载守护已加载且目录未被占用。"),r]];[self reloadList];}]; }]];
 [self presentViewController:a animated:YES completion:nil];
}
- (void)addThermalMountPaths {
 [self performCommand:"add" path:S("/System/Library/LaunchDaemons") completion:^(int first){if(first){[self alert:S("温控路径挂载未完成") message:[NSString stringWithFormat:S("LaunchDaemons 返回代码 %d"),first]];return;}[self performCommand:"add" path:S("/System/Library/ThermalMonitor") completion:^(int second){[self reloadList];[self alert:second?S("温控路径挂载未完成"):S("温控路径挂载完成") message:second?[NSString stringWithFormat:S("ThermalMonitor 返回代码 %d"),second]:S("两个温控路径已挂载。")];}];}];
}
- (void)remountAll { [self performCommand:"remount-all" path:nil completion:^(int r){[self alert:r?S("重新挂载未完成"):S("重新挂载完成") message:r?[NSString stringWithFormat:S("返回代码 %d，请逐项检查路径。"),r]:S("所有已保存路径均已检查并恢复。")];[self reloadList];}]; }
- (void)applyThermalSchedule { UIAlertController *a=[UIAlertController alertControllerWithTitle:S("应用温控性能调度") message:S("将备份后备目录中的机型温控 plist，抑制热暗屏与性能目标限制，并重启 thermalmonitord。要求 LaunchDaemons 与 ThermalMonitor 两个目录均已挂载。") preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:S("应用调度") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*x){[self performCommand:"apply-thermal-schedule" path:nil completion:^(int r){[self alert:r?S("调度失败"):S("调度完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("操作已完成。")];}];}]];[self presentViewController:a animated:YES completion:nil]; }
- (void)applyAntiDownclock { UIAlertController *a=[UIAlertController alertControllerWithTitle:S("应用防降频增强调度") message:S("在现有防暗屏/防掉帧基础上，进一步统一机型 DecisionTree 的性能目标、热等级和功率预算；保留设备原始 maxCPU/maxGPU 索引及空闲 DVFS。") preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:S("应用增强") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*x){[self performCommand:"apply-anti-downclock" path:nil completion:^(int r){[self alert:r?S("增强失败"):S("增强完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("操作已完成。")];}];}]];[self presentViewController:a animated:YES completion:nil]; }
- (void)replaceBundledD64 { UIAlertController *a=[UIAlertController alertControllerWithTitle:S("一键替换内置温控文件配置") message:S("将内置完整温控文件内容写入当前后备目录中的 D*AP-Info.plist，保持设备原文件名；替换前会备份并在完成后重启 thermalmonitord。内置资源通过当前 RootHide 的 jbroot 动态路径读取，适用于对应 D64AP 机型。") preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:S("确认替换") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*x){[self performCommand:"replace-bundled-d64" path:nil completion:^(int r){[self alert:r?S("替换失败"):S("替换完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("操作已完成。")];}];}]];[self presentViewController:a animated:YES completion:nil]; }
- (void)restoreThermalSchedule { [self performCommand:"restore-thermal-schedule" path:nil completion:^(int r){[self alert:r?S("恢复失败"):S("恢复完成") message:r?[NSString stringWithFormat:S("返回代码 %d"),r]:S("操作已完成。")];}]; }
- (void)pathTapped:(PSSpecifier *)sp { NSString *p=[sp propertyForKey:S("mountPath")]; BOOL mounted=[self isMounted:p]; UIAlertController *a=[UIAlertController alertControllerWithTitle:p message:mounted?S("该路径当前由 CPUthermal 可读写 bindfs 挂载。"):S("该路径已保存，但当前未挂载。") preferredStyle:UIAlertControllerStyleActionSheet];
 [a addAction:[UIAlertAction actionWithTitle:S("在 Filza 中编辑后备目录") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){ NSString *storage=[self storagePathForMountPath:p]; if(!storage.length){[self alert:S("后备目录未解析") message:[self isRootlessMountBuild]?S("请确认 /var/jb 已挂载且 rootless 环境已启动。"):S("请确认当前 RootHide 环境已启动。")];return;} NSString *escaped=[storage stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]; NSURL *url=[NSURL URLWithString:[S("filza://view") stringByAppendingString:escaped?:S("")]]; if(url)[UIApplication.sharedApplication openURL:url options:[NSDictionary dictionary] completionHandler:nil]; }]];
 if(mounted)[a addAction:[UIAlertAction actionWithTitle:S("卸载但保留记录") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){[self performCommand:"unmount" path:p completion:^(int r){if(r)[self alert:S("卸载失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];[self reloadList];}];}]];
 else [a addAction:[UIAlertAction actionWithTitle:S("立即挂载") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){[self performCommand:"mount" path:p completion:^(int r){if(r)[self alert:S("挂载失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];[self reloadList];}];}]];
 [a addAction:[UIAlertAction actionWithTitle:S("卸载并移除记录") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*x){[self performCommand:"remove" path:p completion:^(int r){if(r)[self alert:S("移除失败") message:[NSString stringWithFormat:S("返回代码 %d"),r]];[self reloadList];}];}]];
 [a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
- (NSArray *)specifiers { if(!_specifiers){ NSMutableArray *s=[NSMutableArray array]; PSSpecifier *g=[PSSpecifier groupSpecifierWithName:[self isRootlessMountBuild]?S("rootless 路径挂载"):S("RootHide 路径挂载")]; [g setProperty:[self isRootlessMountBuild]?S("将系统目录复制到 /var/jb/var/lib/cputhermal-mount 后备目录，再通过可读写 bindfs 关联到原路径；用户空间启动后自动恢复挂载。"):S("将指定系统目录复制到动态 .jbroot-* 中另建的 CPUthermal 后备目录，再通过可读写 bindfs 关联到原路径。请在“Filza 中编辑后备目录”，不要编辑受系统保护的原路径；用户空间启动后会自动恢复挂载。仅 RootHide 环境启用。") forKey:S("footerText")]; [s addObject:g]; PSSpecifier *thermalMount=[PSSpecifier preferenceSpecifierNamed:S("一键挂载温控路径") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; thermalMount->action=@selector(addThermalMountPaths); [s addObject:thermalMount]; PSSpecifier *add=[PSSpecifier preferenceSpecifierNamed:S("添加其他挂载路径") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; add->action=@selector(addMountPath); [s addObject:add]; PSSpecifier *remount=[PSSpecifier preferenceSpecifierNamed:S("重新挂载全部") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; remount->action=@selector(remountAll); [s addObject:remount]; [s addObject:[PSSpecifier groupSpecifierWithName:S("温控性能调度")]]; PSSpecifier *apply=[PSSpecifier preferenceSpecifierNamed:S("应用防暗屏 / 防掉帧调度") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; apply->action=@selector(applyThermalSchedule); [s addObject:apply]; PSSpecifier *anti=[PSSpecifier preferenceSpecifierNamed:S("应用防降频增强调度") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; anti->action=@selector(applyAntiDownclock); [s addObject:anti]; PSSpecifier *replace=[PSSpecifier preferenceSpecifierNamed:S("一键替换为内置 温控文件 配置") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; replace->action=@selector(replaceBundledD64); [s addObject:replace]; PSSpecifier *restore=[PSSpecifier preferenceSpecifierNamed:S("恢复调度前配置") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; restore->action=@selector(restoreThermalSchedule); [s addObject:restore]; self.paths=[self loadPaths]; [s addObject:[PSSpecifier groupSpecifierWithName:[NSString stringWithFormat:S("已保存路径（%lu）"),(unsigned long)self.paths.count]]]; for(NSString *p in self.paths){PSSpecifier *s1=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:S("%@  %@"),[self isMounted:p]?S("●"):S("○"),p] target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];s1->action=@selector(pathTapped:);[s1 setProperty:p forKey:S("mountPath")];[s addObject:s1];} if(!self.paths.count){PSSpecifier *e=[PSSpecifier groupSpecifierWithName:nil];[e setProperty:S("尚未添加路径。") forKey:S("footerText")];[s addObject:e];} _specifiers=[s copy]; } return _specifiers; }
@end

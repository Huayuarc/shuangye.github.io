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
- (NSString *)listPath { return [[CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalMounts.plist")]; }
- (NSString *)storagePathForMountPath:(NSString *)path { NSString *root=CPUthermalCurrentRootHideRoot(); if(!root.length||![path hasPrefix:S("/")])return nil; return [[root stringByAppendingPathComponent:S("var/lib/cputhermal-mount")] stringByAppendingPathComponent:[path substringFromIndex:1]]; }
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
 BOOL point=strcmp(info.f_mntonname,path.fileSystemRepresentation)==0;
 if(!point||strcmp(info.f_fstypename,"bindfs")!=0)return NO;
 NSString *source=[NSString stringWithUTF8String:info.f_mntfromname];
 NSString *storage=[self storagePathForMountPath:path];
 return source.length&&storage.length&&[[source stringByStandardizingPath] isEqualToString:[storage stringByStandardizingPath]];
}
- (void)reloadList { self.paths=[self loadPaths]; _specifiers=nil; [self reloadSpecifiers]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadList]; }
- (void)alert:(NSString *)title message:(NSString *)message { UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
- (NSString *)messageForCode:(int)code { switch(code){case 22:return S("路径格式无效，请输入已存在目录的绝对路径。");case 79:return S("未找到当前 RootHide 动态根。");case 124:return S("操作仍未返回，请确认挂载守护已启动。");case 127:return S("挂载客户端未安装。");case 2:case 102:return S("目标目录不存在。");case 16:return S("目标路径已被其他文件系统占用。");default:return [NSString stringWithFormat:S("返回代码 %d。请确认 RootHide 已启动，路径存在且未被其他组件挂载。"),code];} }
- (void)performTitle:(NSString *)title work:(int(^)(void))work completion:(void(^)(int))completion {
 if(self.operationRunning)return; self.operationRunning=YES;
 UIAlertController *progress=[UIAlertController alertControllerWithTitle:title message:S("首次复制大型系统目录可能需要几十秒，请保持此页面开启。") preferredStyle:UIAlertControllerStyleAlert]; UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]; [spinner startAnimating]; [progress.view addSubview:spinner]; spinner.translatesAutoresizingMaskIntoConstraints=NO; [NSLayoutConstraint activateConstraints:@[[spinner.centerXAnchor constraintEqualToAnchor:progress.view.centerXAnchor],[spinner.bottomAnchor constraintEqualToAnchor:progress.view.bottomAnchor constant:-18]]];
 // 操作立即开始；只有超过 0.6 秒仍未完成才显示等待框。已挂载快路径保持原来的即时反馈。
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(self.operationRunning&&self.presentedViewController==nil)[self presentViewController:progress animated:YES completion:nil];});
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{int result=work();dispatch_async(dispatch_get_main_queue(),^{self.operationRunning=NO;void(^finish)(void)=^{if(completion)completion(result);};if(progress.presentingViewController)[progress dismissViewControllerAnimated:YES completion:finish];else finish();});});
}
- (void)addMountPath { UIAlertController *a=[UIAlertController alertControllerWithTitle:S("添加挂载路径") message:S("首次挂载会复制目录内容到隐藏根后备存储，并以可读写 bindfs 挂载。") preferredStyle:UIAlertControllerStyleAlert]; [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=S("例如 /var/mobile/Library/SomeDirectory");f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}]; [a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]]; [a addAction:[UIAlertAction actionWithTitle:S("添加并挂载") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){NSString*p=[[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] stringByStandardizingPath];[self performTitle:S("正在复制并挂载") work:^int{return [self run:"add" path:p];} completion:^(int r){[self reloadList];[self alert:r?S("挂载未完成"):S("挂载完成") message:r?[self messageForCode:r]:S("路径已保存并挂载。")];}];}]]; [self presentViewController:a animated:YES completion:nil]; }
- (void)addThermalMountPaths { [self performTitle:S("正在挂载温控路径") work:^int{for(NSString*p in @[S("/System/Library/LaunchDaemons"),S("/System/Library/ThermalMonitor")]){int r=[self run:"add" path:p];if(r)return r;}return 0;} completion:^(int r){[self reloadList];[self alert:r?S("温控路径挂载未完成"):S("温控路径挂载完成") message:r?[self messageForCode:r]:S("两个目录已保存并挂载；用户空间启动后会自动恢复。")];}]; }
- (void)remountAll { [self performTitle:S("正在检查全部路径") work:^int{return [self run:"remount-all" path:nil];} completion:^(int r){[self reloadList];[self alert:r?S("重新挂载未完成"):S("重新挂载完成") message:r?[self messageForCode:r]:S("所有已保存路径均已检查并恢复。")];}]; }
- (void)runNamed:(const char*)cmd title:(NSString*)title success:(NSString*)success { [self performTitle:title work:^int{return [self run:cmd path:nil];} completion:^(int r){[self alert:r?S("操作未完成"):success message:r?[self messageForCode:r]:S("配置已写入；相关服务将重新读取。")];}]; }
- (void)applyThermalSchedule {[self runNamed:"apply-thermal-schedule" title:S("正在应用防暗屏调度") success:S("调度完成")];}
- (void)applyAntiDownclock {[self runNamed:"apply-anti-downclock" title:S("正在应用防降频调度") success:S("增强完成")];}
- (void)replaceBundledD64 {[self runNamed:"replace-bundled-d64" title:S("正在替换温控配置") success:S("替换完成")];}
- (void)restoreThermalSchedule {[self runNamed:"restore-thermal-schedule" title:S("正在恢复原配置") success:S("恢复完成")];}
- (void)pathTapped:(PSSpecifier *)sp { NSString*p=[sp propertyForKey:S("mountPath")];BOOL mounted=[[sp propertyForKey:S("mounted")] boolValue];UIAlertController*a=[UIAlertController alertControllerWithTitle:p message:mounted?S("当前由 CPUthermal 可读写 bindfs 挂载。"):S("路径已保存，当前未挂载。") preferredStyle:UIAlertControllerStyleActionSheet];[a addAction:[UIAlertAction actionWithTitle:S("在 Filza 中编辑后备目录") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){NSString*storage=[self storagePathForMountPath:p];if(!storage.length){[self alert:S("后备目录未解析") message:S("请确认当前 RootHide 环境已启动。")];return;}NSString*escaped=[storage stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];NSURL*url=[NSURL URLWithString:[S("filza://view") stringByAppendingString:escaped?:S("")]];if(url)[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];}]];const char*cmd=mounted?"unmount":"mount";[a addAction:[UIAlertAction actionWithTitle:mounted?S("卸载但保留记录"):S("立即挂载") style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){[self performTitle:mounted?S("正在卸载"):S("正在挂载") work:^int{return [self run:cmd path:p];} completion:^(int r){[self reloadList];if(r)[self alert:S("操作未完成") message:[self messageForCode:r]];}];}]];[a addAction:[UIAlertAction actionWithTitle:S("卸载并移除记录") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*x){[self performTitle:S("正在移除") work:^int{return [self run:"remove" path:p];} completion:^(int r){[self reloadList];if(r)[self alert:S("移除未完成") message:[self messageForCode:r]];}];}]];[a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil]; }
- (NSArray *)specifiers { if(!_specifiers){NSMutableArray*s=[NSMutableArray array];PSSpecifier*g=[PSSpecifier groupSpecifierWithName:S("RootHide 路径挂载")];[g setProperty:S("已挂载路径重复操作会立即完成；仅首次建立后备副本时可能需要几十秒。蓝色实心圆表示挂载生效。") forKey:S("footerText")];[s addObject:g];for(NSArray*item in @[@[S("一键挂载温控路径"),S("addThermalMountPaths")],@[S("添加其他挂载路径"),S("addMountPath")],@[S("重新挂载全部"),S("remountAll")]]){PSSpecifier*b=[PSSpecifier preferenceSpecifierNamed:item[0] target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];b->action=NSSelectorFromString(item[1]);[s addObject:b];}[s addObject:[PSSpecifier groupSpecifierWithName:S("温控性能调度")]];for(NSArray*item in @[@[S("应用防暗屏 / 防掉帧调度"),S("applyThermalSchedule")],@[S("应用防降频增强调度"),S("applyAntiDownclock")],@[S("一键替换为内置 温控文件 配置"),S("replaceBundledD64")],@[S("恢复调度前配置"),S("restoreThermalSchedule")]]){PSSpecifier*b=[PSSpecifier preferenceSpecifierNamed:item[0] target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];b->action=NSSelectorFromString(item[1]);[s addObject:b];}self.paths=[self loadPaths];NSMutableDictionary*states=[NSMutableDictionary dictionary];for(NSString*p in self.paths)states[p]=@([self isMounted:p]);[s addObject:[PSSpecifier groupSpecifierWithName:[NSString stringWithFormat:S("已保存路径（%lu）"),(unsigned long)self.paths.count]]];for(NSString*p in self.paths){BOOL mounted=[states[p] boolValue];PSSpecifier*row=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:S("%@  %@"),mounted?S("●"):S("○"),p] target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];row->action=@selector(pathTapped:);[row setProperty:p forKey:S("mountPath")];[row setProperty:@(mounted) forKey:S("mounted")];[s addObject:row];}if(!self.paths.count){PSSpecifier*e=[PSSpecifier groupSpecifierWithName:nil];[e setProperty:S("尚未添加路径。") forKey:S("footerText")];[s addObject:e];}_specifiers=[s copy];}return _specifiers;}
@end

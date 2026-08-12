#import "PMOriginal.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>

static NSInteger PMSlot(NSString *identifier){NSInteger n=[identifier componentsSeparatedByString:@"."].lastObject.integerValue;return MAX(1,MIN(5,n));}
static NSString *PMRoot(void){NSString *p=[[NSFileManager defaultManager]fileExistsAtPath:@"/var/jb"]?@"/var/jb/var/mobile/Library/PictureModule":@"/var/mobile/Library/PictureModule";[[NSFileManager defaultManager]createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0775} error:nil];return p;}

@interface PMOriginalListController()<PHPickerViewControllerDelegate>
@property(nonatomic,strong) NSString *identifier;
@end
@implementation PMOriginalListController
- (instancetype)initWithIdentifier:(NSString *)i{if((self=[super init]))_identifier=i;return self;}
- (NSArray *)specifiers{if(!_specifiers)_specifiers=[[self loadSpecifiersFromPlistName:@"ModulePrefs" target:self]mutableCopy];return _specifiers;}
- (void)viewDidLoad{[super viewDidLoad];self.title=[NSString stringWithFormat:@"图片模块（%ld）",(long)PMSlot(_identifier)];}
- (void)chooseImage{PHPickerConfiguration *c=[[PHPickerConfiguration alloc]init];c.selectionLimit=1;c.filter=[PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter,PHPickerFilter.videosFilter]];PHPickerViewController *p=[[PHPickerViewController alloc]initWithConfiguration:c];p.delegate=self;[self presentViewController:p animated:YES completion:nil];}
- (void)showError:(NSString *)message{dispatch_async(dispatch_get_main_queue(),^{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"保存失败" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];});}
- (void)finishKind:(NSString *)kind slot:(NSInteger)n{NSUserDefaults *d=[[NSUserDefaults alloc]initWithSuiteName:_identifier];[d setObject:kind forKey:@"type"];[d synchronize];NSString *legacy=[NSString stringWithFormat:@"com.4nni3.picturemodule_%ld",(long)n];NSUserDefaults *old=[[NSUserDefaults alloc]initWithSuiteName:legacy];[old setObject:kind forKey:@"type"];[old synchronize];notify_post([[_identifier stringByAppendingString:@"/updatePicture"]UTF8String]);notify_post([[legacy stringByAppendingString:@"/updatePicture"]UTF8String]);}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results{[picker dismissViewControllerAnimated:YES completion:nil];NSItemProvider *p=results.firstObject.itemProvider;if(!p)return;NSInteger n=PMSlot(_identifier);NSString *root=PMRoot();NSString *base=[NSString stringWithFormat:@"com.4nni3.picturemodule_%ld",(long)n];
 if([p hasItemConformingToTypeIdentifier:UTTypeImage.identifier]){[p loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSData *x,NSError *e){NSString *dst=[root stringByAppendingPathComponent:[base stringByAppendingString:@"_img.dat"]];BOOL ok=x&&[x writeToFile:dst options:NSDataWritingAtomic error:&e];if(!ok){[self showError:e.localizedDescription?:@"图片文件写入失败，请检查目录权限。"];return;}[[NSFileManager defaultManager]removeItemAtPath:[root stringByAppendingPathComponent:[base stringByAppendingString:@"_video.mp4"]] error:nil];[self finishKind:@"image" slot:n];}];}
 else if([p hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]){[p loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *u,NSError *e){NSString *dst=[root stringByAppendingPathComponent:[base stringByAppendingString:@"_video.mp4"]];[[NSFileManager defaultManager]removeItemAtPath:dst error:nil];BOOL ok=u&&[[NSFileManager defaultManager]copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:&e];if(!ok){[self showError:e.localizedDescription?:@"视频文件写入失败，请检查目录权限。"];return;}[self finishKind:@"video" slot:n];}];}}
@end

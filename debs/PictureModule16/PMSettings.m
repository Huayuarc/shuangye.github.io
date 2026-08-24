#import "PMOriginal.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>
#import "PMPaths.h"

static NSInteger PMSlot(NSString *identifier){NSString *tail=[identifier componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"._"]].lastObject;NSInteger n=tail.integerValue;return MAX(1,MIN(5,n));}
static NSString *PMRoot(void){PMPrepareAndMigrate();return PMDataRoot();}

@interface PMOriginalListController()<PHPickerViewControllerDelegate>
@property(nonatomic,strong) NSString *identifier;
@end
@implementation PMOriginalListController
- (instancetype)initWithIdentifier:(NSString *)i{if((self=[super init]))_identifier=i;return self;}
- (NSArray *)specifiers{if(!_specifiers){NSString *name=[NSString stringWithFormat:@"ModulePrefs%ld",(long)PMSlot(_identifier)];_specifiers=[[self loadSpecifiersFromPlistName:name target:self]mutableCopy];if(!_specifiers.count)_specifiers=[[self loadSpecifiersFromPlistName:@"ModulePrefs" target:self]mutableCopy];}return _specifiers;}
- (id)readPreferenceValue:(PSSpecifier *)specifier{NSString *key=[specifier propertyForKey:@"key"];id value=PMReadDomain(_identifier)[key];return value?:[specifier propertyForKey:@"default"];}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier{NSString *key=[specifier propertyForKey:@"key"];if(key)PMWriteDomainValue(_identifier,key,value);notify_post(_identifier.UTF8String);NSString *post=[specifier propertyForKey:@"PostNotification"];if(post.length)notify_post(post.UTF8String);}
- (void)viewDidLoad{[super viewDidLoad];self.title=[NSString stringWithFormat:@"图片视频模块（%ld）",(long)PMSlot(_identifier)];}
- (void)chooseImage{PHPickerConfiguration *c=[[PHPickerConfiguration alloc]init];c.selectionLimit=1;c.filter=[PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter,PHPickerFilter.videosFilter]];PHPickerViewController *p=[[PHPickerViewController alloc]initWithConfiguration:c];p.delegate=self;[self presentViewController:p animated:YES completion:nil];}
- (void)showError:(NSString *)message{dispatch_async(dispatch_get_main_queue(),^{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"保存失败" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];});}
- (void)finishKind:(NSString *)kind slot:(NSInteger)n{PMWriteDomainValue(_identifier,@"type",kind);NSString *legacy=[NSString stringWithFormat:@"com.4nni3.picturemodule_%ld",(long)n];PMWriteDomainValue(legacy,@"type",kind);notify_post([[_identifier stringByAppendingString:@"/updatePicture"]UTF8String]);notify_post([[legacy stringByAppendingString:@"/updatePicture"]UTF8String]);}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results{[picker dismissViewControllerAnimated:YES completion:nil];NSItemProvider *p=results.firstObject.itemProvider;if(!p)return;NSInteger n=PMSlot(_identifier);NSString *root=PMRoot();NSString *base=[NSString stringWithFormat:@"com.4nni3.picturemodule_%ld",(long)n];
 if([p hasItemConformingToTypeIdentifier:UTTypeImage.identifier]){[p loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSData *x,NSError *e){NSString *dst=[root stringByAppendingPathComponent:[base stringByAppendingString:@"_img.dat"]];BOOL ok=x&&[x writeToFile:dst options:NSDataWritingAtomic error:&e];if(!ok){[self showError:e.localizedDescription?:@"图片文件写入失败，请检查目录权限。"];return;}[[NSFileManager defaultManager]removeItemAtPath:[root stringByAppendingPathComponent:[base stringByAppendingString:@"_video.mp4"]] error:nil];[self finishKind:@"image" slot:n];}];}
 else if([p hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]){[p loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *u,NSError *e){NSString *dst=[root stringByAppendingPathComponent:[base stringByAppendingString:@"_video.mp4"]];[[NSFileManager defaultManager]removeItemAtPath:dst error:nil];BOOL ok=u&&[[NSFileManager defaultManager]copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:&e];if(!ok){[self showError:e.localizedDescription?:@"视频文件写入失败，请检查目录权限。"];return;}[self finishKind:@"video" slot:n];}];}}
@end

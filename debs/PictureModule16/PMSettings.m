#import "PMOriginal.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>

@interface PMOriginalListController()<PHPickerViewControllerDelegate>
@property(nonatomic,strong) NSString *identifier;
@end
@implementation PMOriginalListController
- (instancetype)initWithIdentifier:(NSString *)i{if((self=[super init]))_identifier=i;return self;}
- (NSArray *)specifiers{if(!_specifiers)_specifiers=[[self loadSpecifiersFromPlistName:@"ModulePrefs" target:self]mutableCopy];return _specifiers;}
- (void)viewDidLoad{[super viewDidLoad];self.title=[NSString stringWithFormat:@"PictureModule (%ld)",(long)MAX(1,self.identifier.lastPathComponent.integerValue)];}
- (void)chooseImage{PHPickerConfiguration *c=[[PHPickerConfiguration alloc]init];c.selectionLimit=1;c.filter=[PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter,PHPickerFilter.videosFilter]];PHPickerViewController *p=[[PHPickerViewController alloc]initWithConfiguration:c];p.delegate=self;[self presentViewController:p animated:YES completion:nil];}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results{[picker dismissViewControllerAnimated:YES completion:nil];NSItemProvider *p=results.firstObject.itemProvider;if(!p)return;NSInteger n=MAX(1,self.identifier.lastPathComponent.integerValue);NSString *root=[[NSFileManager defaultManager]fileExistsAtPath:@"/var/jb"]?@"/var/jb/var/mobile/Library/PictureModule":@"/var/mobile/Library/PictureModule";[[NSFileManager defaultManager]createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];NSUserDefaults *d=[[NSUserDefaults alloc]initWithSuiteName:self.identifier];
 if([p hasItemConformingToTypeIdentifier:UTTypeImage.identifier])[p loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSData *x,NSError *e){if(!x)return;[x writeToFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"com.4nni3.picturemodule_%ld_img.dat",(long)n]] atomically:YES];[d setObject:@"image" forKey:@"type"];[d synchronize];notify_post([[self.identifier stringByAppendingString:@"/updatePicture"]UTF8String]);}];
 else if([p hasItemConformingToTypeIdentifier:UTTypeMovie.identifier])[p loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *u,NSError *e){if(!u)return;NSString *dst=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"com.4nni3.picturemodule_%ld_video.mp4",(long)n]];[[NSFileManager defaultManager]removeItemAtPath:dst error:nil];[[NSFileManager defaultManager]copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:nil];[d setObject:@"video" forKey:@"type"];[d synchronize];notify_post([[self.identifier stringByAppendingString:@"/updatePicture"]UTF8String]);}];}
@end

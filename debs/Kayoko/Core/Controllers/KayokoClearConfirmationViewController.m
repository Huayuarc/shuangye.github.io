//
//  KayokoClearConfirmationViewController.m
//  Kayoko
//

#import "KayokoClearConfirmationViewController.h"

#import "KayokoClearConfirmationView.h"
#import "KayokoPasteboardManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface KayokoClearConfirmationViewController ()
@property(nonatomic, strong, readwrite) KayokoClearConfirmationView *confirmationView;
@end

NS_ASSUME_NONNULL_END

@implementation KayokoClearConfirmationViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _confirmationView = [[KayokoClearConfirmationView alloc] init];
        [self setView:_confirmationView];
        [[_confirmationView cancelButton] addTarget:self
                                             action:@selector(handleCancel)
                                   forControlEvents:UIControlEventTouchUpInside];
        [[_confirmationView confirmButton] addTarget:self
                                              action:@selector(handleConfirm)
                                    forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)beginWithHistoryKey:(NSString *)historyKey {
    [self beginWithHistoryKey:historyKey imagesOnly:NO];
}

- (void)beginWithHistoryKey:(NSString *)historyKey imagesOnly:(BOOL)imagesOnly {
    [self setHistoryKey:historyKey];
    [self setImagesOnly:imagesOnly];
    [[self confirmationView] updateWithHistoryKey:historyKey imagesOnly:imagesOnly];
    [[[self confirmationView] cancelButton] setEnabled:YES];
    [[[self confirmationView] confirmButton] setEnabled:YES];
}

- (void)handleCancel {
    [[self delegate] clearConfirmationViewControllerDidCancel:self];
}

- (void)handleConfirm {
    NSString *historyKey = [self historyKey];
    if ([historyKey length] == 0) {
        return;
    }

    [[[self confirmationView] cancelButton] setEnabled:NO];
    [[[self confirmationView] confirmButton] setEnabled:NO];
    void (^completion)(BOOL) = ^(BOOL success) {
      if (success) {
          [[self delegate] clearConfirmationViewControllerDidClearHistoryKey:historyKey];
      } else {
          [[[self confirmationView] cancelButton] setEnabled:YES];
          [[[self confirmationView] confirmButton] setEnabled:YES];
          [[self delegate] clearConfirmationViewController:self didFailClearingHistoryKey:historyKey];
      }
    };
    if ([self isImagesOnly]) {
        [[KayokoPasteboardManager sharedInstance] removeImagePasteboardItemsFromHistoryWithKey:historyKey
                                                                       postsChangeNotification:NO
                                                                                    completion:completion];
    } else {
        [[KayokoPasteboardManager sharedInstance] removeAllPasteboardItemsFromHistoryWithKey:historyKey
                                                                          shouldRemoveImages:YES
                                                                     postsChangeNotification:NO
                                                                                  completion:completion];
    }
}

@end

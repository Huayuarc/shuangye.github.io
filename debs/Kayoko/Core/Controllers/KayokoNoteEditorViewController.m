//
//  KayokoNoteEditorViewController.m
//  Kayoko
//

#import "KayokoNoteEditorViewController.h"

#import "KayokoApplicationMetadataProvider.h"
#import "KayokoNoteEditorView.h"
#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"
#import "KayokoTagCatalog.h"
#import "KayokoTagChipBarView.h"
#import "KayokoTableViewCell.h"

@interface UIPeripheralHost : NSObject
+ (instancetype)sharedInstance;
+ (NSArray<NSValue *> *)allVisiblePeripheralFrames;
- (BOOL)isOnScreen;
@end

static CGFloat const kKayokoKeyboardFrameEdgeTolerance = 1.0;

static CGFloat kayokoBottomInsetForDockedKeyboardFrame(CGRect keyboardFrame, UIWindow *window) {
    if (CGRectIsNull(keyboardFrame) || CGRectIsEmpty(keyboardFrame) || !window) {
        return 0;
    }

    CGRect windowBounds = [window bounds];
    CGFloat windowBottom = CGRectGetMaxY(windowBounds);
    if (CGRectGetMinY(keyboardFrame) >= windowBottom - kKayokoKeyboardFrameEdgeTolerance ||
        fabs(CGRectGetMaxY(keyboardFrame) - windowBottom) > kKayokoKeyboardFrameEdgeTolerance) {
        return 0;
    }
    return windowBottom - CGRectGetMinY(keyboardFrame);
}

NS_ASSUME_NONNULL_BEGIN

@interface KayokoNoteEditorViewController () <UITextFieldDelegate>

@property(nonatomic, strong, readwrite) KayokoNoteEditorView *noteEditorView;
@property(nonatomic, strong, readwrite, nullable) KayokoPasteboardItem *item;
@property(nonatomic, strong) KayokoApplicationMetadataProvider *metadataProvider;
@property(nonatomic, copy) NSString *sourceDisplayName;
@property(nonatomic, assign, getter=isSaving) BOOL saving;
@property(nonatomic, assign) CGFloat currentKeyboardBottomInset;
@property(nonatomic, copy, nullable) NSString *selectedTagUUID;

@end

@implementation KayokoNoteEditorViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _metadataProvider = [[KayokoApplicationMetadataProvider alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleKeyboardWillChangeFrameNotification:)
                                                     name:UIKeyboardWillChangeFrameNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleKeyboardWillHideNotification:)
                                                     name:UIKeyboardWillHideNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    KayokoNoteEditorView *noteEditorView = [[KayokoNoteEditorView alloc] initWithFrame:CGRectZero];
    [self setNoteEditorView:noteEditorView];
    [self setView:noteEditorView];

    NSBundle *bundle = [KayokoPasteboardManager localizationBundle];
    [[noteEditorView textField] setPlaceholder:[bundle localizedStringForKey:@"Note" value:nil table:@"Tweak"]];
    [[noteEditorView textField] setDelegate:self];
    [[noteEditorView textField] addTarget:self
                                   action:@selector(handleTextFieldEditingChanged:)
                         forControlEvents:UIControlEventEditingChanged];
    [[noteEditorView saveButton] setTitle:[bundle localizedStringForKey:@"Save" value:nil table:@"Tweak"]
                                 forState:UIControlStateNormal];
    [[noteEditorView saveButton] addTarget:self
                                    action:@selector(handleSaveButtonPressed)
                          forControlEvents:UIControlEventTouchUpInside];
    [[noteEditorView cancelButton] setTitle:[bundle localizedStringForKey:@"Cancel" value:nil table:@"Tweak"]
                                   forState:UIControlStateNormal];
    [[noteEditorView cancelButton] addTarget:self
                                      action:@selector(handleCancelButtonPressed)
                            forControlEvents:UIControlEventTouchUpInside];
}

- (nullable NSString *)normalizedNote {
    NSString *note = [[[self noteEditorView] textField].text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [note length] > 0 ? note : nil;
}

- (void)updatePreview {
    NSString *displayName = [self normalizedNote] ?: [self sourceDisplayName] ?: @"";
    UILabel *headerLabel = [[[self noteEditorView] previewCell] headerLabel];
    [headerLabel setAttributedText:nil];
    [headerLabel setText:displayName];
}

- (void)setSelectedTagUUIDAndUpdateTagBar:(NSString *)tagUUID {
    NSString *normalizedTagUUID = [tagUUID length] > 0 ? tagUUID : nil;
    [self setSelectedTagUUID:normalizedTagUUID];
    [[[self noteEditorView] tagChipBarView] setSelectedTagUUID:normalizedTagUUID];
}

- (void)configureTagBarForItem:(KayokoPasteboardItem *)item {
    [self setSelectedTagUUIDAndUpdateTagBar:[item tagUUID]];

    __weak typeof(self) weakSelf = self;
    [[self noteEditorView] configureTagBarWithTags:[[KayokoTagCatalog sharedCatalog] reloadTags]
                                 selectedTagUUID:[self selectedTagUUID]
                                selectionHandler:^(NSString *tagUUID) {
                                  __strong typeof(weakSelf) strongSelf = weakSelf;
                                  if (!strongSelf || [strongSelf isSaving]) {
                                      return;
                                  }
                                  [strongSelf setSelectedTagUUIDAndUpdateTagBar:tagUUID];
                                  [[strongSelf delegate] noteEditorViewController:strongSelf didSelectTagUUID:tagUUID];
                                }];
}

- (void)restorePreviewToSavedState {
    NSString *savedNote = [[[self item] note]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *displayName = [savedNote length] > 0 ? savedNote : ([self sourceDisplayName] ?: @"");
    UILabel *headerLabel = [[[self noteEditorView] previewCell] headerLabel];
    [headerLabel setAttributedText:nil];
    [headerLabel setText:displayName];
    // Keep the text field in sync so a cancelled editor does not flash dirty text again.
    [[[self noteEditorView] textField] setText:[[self item] note] ?: @""];
    [self setSelectedTagUUIDAndUpdateTagBar:[[self item] tagUUID]];
}

- (void)prepareForItem:(KayokoPasteboardItem *)item
       presentationCell:(KayokoTableViewCell *)presentationCell
             cellHeight:(CGFloat)cellHeight
    keyboardBottomInset:(CGFloat)keyboardBottomInset {
    [self loadViewIfNeeded];
    [self setItem:item];
    [self setSourceDisplayName:[[self metadataProvider] displayNameForBundleIdentifier:[item bundleIdentifier]]];
    [[[self noteEditorView] textField] setText:[item note] ?: @""];
    [[self noteEditorView] setPreviewCellHeight:cellHeight];
    [[self noteEditorView] setPreviewCell:presentationCell];
    [self configureTagBarForItem:item];
    // The editor card itself is lifted above the keyboard. Keep the form compact and top-anchored
    // inside that card instead of giving the editor a keyboard-height spacer of its own.
    [self setCurrentKeyboardBottomInset:MAX(keyboardBottomInset, 0)];
    [[self noteEditorView] setAnchorsEditingContentToTop:YES];
    [[self noteEditorView] setKeyboardBottomInset:0];
    [self setSaving:NO];
    [self updatePreview];
}

- (CGFloat)visibleKeyboardBottomInset {
    KayokoNoteEditorView *noteEditorView = [self noteEditorView];
    UIWindow *window = [noteEditorView window] ?: [[noteEditorView superview] window];
    if (!window) {
        return 0;
    }

    Class hostClass = NSClassFromString(@"UIPeripheralHost");
    if ([hostClass respondsToSelector:@selector(sharedInstance)] &&
        [hostClass respondsToSelector:@selector(allVisiblePeripheralFrames)]) {
        UIPeripheralHost *host = [(id)hostClass sharedInstance];
        if ([host respondsToSelector:@selector(isOnScreen)] && ![host isOnScreen]) {
            return 0;
        }

        CGRect keyboardFrame = CGRectNull;
        NSArray<NSValue *> *visibleFrames = [(id)hostClass allVisiblePeripheralFrames];
        for (NSValue *frameValue in visibleFrames) {
            if (![frameValue respondsToSelector:@selector(CGRectValue)]) {
                continue;
            }
            CGRect frame = [frameValue CGRectValue];
            if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) {
                continue;
            }
            keyboardFrame = CGRectIsNull(keyboardFrame) ? frame : CGRectUnion(keyboardFrame, frame);
        }
        if (!CGRectIsNull(keyboardFrame) && !CGRectIsEmpty(keyboardFrame)) {
            CGRect keyboardFrameInWindow = [window convertRect:keyboardFrame fromWindow:nil];
            return kayokoBottomInsetForDockedKeyboardFrame(keyboardFrameInWindow, window);
        }
    }

    return 0;
}

- (void)beginEditing {
    KayokoNoteEditorView *noteEditorView = [self noteEditorView];
    [noteEditorView layoutIfNeeded];

    UIWindow *window = [noteEditorView window];
    if (window && ![window isKeyWindow]) {
        [window makeKeyWindow];
    }

    UITextField *textField = [noteEditorView textField];
    if ([textField becomeFirstResponder]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self item] || [noteEditorView isHidden] || ![noteEditorView window] || [textField isFirstResponder]) {
          return;
      }
      [[noteEditorView window] makeKeyWindow];
      [textField becomeFirstResponder];
    });
}

- (void)resignEditing {
    [[[self noteEditorView] textField] resignFirstResponder];
}

- (void)setSaving:(BOOL)saving {
    _saving = saving;
    [[[self noteEditorView] textField] setEnabled:!saving];
    [[[self noteEditorView] saveButton] setEnabled:!saving];
    [[[self noteEditorView] saveButton] setAlpha:saving ? 0.55 : 1.0];
    [[[self noteEditorView] cancelButton] setEnabled:!saving];
    [[[self noteEditorView] cancelButton] setAlpha:saving ? 0.55 : 1.0];
    [[[self noteEditorView] tagChipBarView] setUserInteractionEnabled:!saving];
}

- (void)reset {
    [self resignEditing];
    [self setSaving:NO];
    [self setItem:nil];
    [self setSourceDisplayName:@""];
    [self setSelectedTagUUID:nil];
    [[[self noteEditorView] textField] setText:@""];
    [[self noteEditorView] configureTagBarWithTags:@[] selectedTagUUID:nil selectionHandler:nil];
    [self setCurrentKeyboardBottomInset:0];
    [[self noteEditorView] setKeyboardBottomInset:0];
    [[self noteEditorView] setAnchorsEditingContentToTop:NO];
    [[self noteEditorView] setPreviewCell:nil];
}

- (void)handleTextFieldEditingChanged:(UITextField *)textField {
    (void)textField;
    [self updatePreview];
}

- (void)requestSave {
    if ([self isSaving] || ![self item]) {
        return;
    }
    [self setSaving:YES];
    [[self delegate] noteEditorViewController:self
                           didRequestSaveNote:[self normalizedNote]
                                    tagUUID:[self selectedTagUUID]];
}

- (void)handleSaveButtonPressed {
    [self requestSave];
}

- (void)requestCancel {
    if ([self isSaving] || ![self item]) {
        return;
    }
    [[self delegate] noteEditorViewControllerDidRequestCancel:self];
}

- (void)handleCancelButtonPressed {
    [self requestCancel];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [self requestSave];
    return NO;
}

- (BOOL)shouldHandleKeyboardNotification:(NSNotification *)notification {
    if (![self item] || [[[self noteEditorView] window] isHidden] || [[self noteEditorView] isHidden]) {
        return NO;
    }
    return [notification.userInfo[UIKeyboardIsLocalUserInfoKey] boolValue];
}

- (void)updateKeyboardBottomInset:(CGFloat)keyboardBottomInset
    withAnimationParametersFromNotification:(NSNotification *)notification {
    // The compact editor never stores keyboard padding in its view. Track the last delivered
    // notification separately so a manual keyboard dismissal still moves the card back down.
    keyboardBottomInset = MAX(keyboardBottomInset, 0);
    if (fabs([self currentKeyboardBottomInset] - keyboardBottomInset) <= 0.5) {
        return;
    }
    [self setCurrentKeyboardBottomInset:keyboardBottomInset];

    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve =
        (UIViewAnimationCurve)[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    UIViewAnimationOptions options = (UIViewAnimationOptions)(curve << 16) |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction;
    [[self delegate] noteEditorViewController:self
                 didUpdateKeyboardBottomInset:keyboardBottomInset
                            animationDuration:duration
                                      options:options];
}

- (void)handleKeyboardWillChangeFrameNotification:(NSNotification *)notification {
    if (![notification.userInfo[UIKeyboardIsLocalUserInfoKey] boolValue]) {
        return;
    }

    CGRect keyboardEndFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIWindow *window = [[self noteEditorView] window] ?: [[[self noteEditorView] superview] window];
    if (!window) {
        return;
    }
    CGRect keyboardFrameInWindow = [window convertRect:keyboardEndFrame fromWindow:nil];
    CGFloat keyboardBottomInset = kayokoBottomInsetForDockedKeyboardFrame(keyboardFrameInWindow, window);
    if (![self shouldHandleKeyboardNotification:notification]) {
        return;
    }
    [self updateKeyboardBottomInset:keyboardBottomInset withAnimationParametersFromNotification:notification];
}

- (void)handleKeyboardWillHideNotification:(NSNotification *)notification {
    if (![self item]) {
        return;
    }
    [self updateKeyboardBottomInset:0 withAnimationParametersFromNotification:notification];
}

@end

NS_ASSUME_NONNULL_END

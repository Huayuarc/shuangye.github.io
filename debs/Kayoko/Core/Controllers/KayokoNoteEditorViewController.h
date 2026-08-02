//
//  KayokoNoteEditorViewController.h
//  Kayoko
//

#import <UIKit/UIKit.h>

@class KayokoNoteEditorView;
@class KayokoNoteEditorViewController;
@class KayokoPasteboardItem;
@class KayokoTableViewCell;

NS_ASSUME_NONNULL_BEGIN

@protocol KayokoNoteEditorViewControllerDelegate <NSObject>

- (void)noteEditorViewController:(KayokoNoteEditorViewController *)controller
              didRequestSaveNote:(nullable NSString *)note
                       tagUUID:(nullable NSString *)tagUUID;
- (void)noteEditorViewControllerDidRequestCancel:(KayokoNoteEditorViewController *)controller;
- (void)noteEditorViewController:(KayokoNoteEditorViewController *)controller
                 didSelectTagUUID:(nullable NSString *)tagUUID;
- (void)noteEditorViewController:(KayokoNoteEditorViewController *)controller
    didUpdateKeyboardBottomInset:(CGFloat)keyboardBottomInset
               animationDuration:(NSTimeInterval)animationDuration
                         options:(UIViewAnimationOptions)options;

@end

@interface KayokoNoteEditorViewController : UIViewController

@property(nonatomic, weak, nullable) id<KayokoNoteEditorViewControllerDelegate> delegate;
@property(nonatomic, strong, readonly) KayokoNoteEditorView *noteEditorView;
@property(nonatomic, strong, readonly, nullable) KayokoPasteboardItem *item;

- (void)prepareForItem:(KayokoPasteboardItem *)item
    presentationCell:(KayokoTableViewCell *)presentationCell
             cellHeight:(CGFloat)cellHeight
    keyboardBottomInset:(CGFloat)keyboardBottomInset;
// Returns the current on-screen keyboard overlap. It deliberately does not retain a previous
// value: a stale height would move the editor before the next keyboard presentation starts.
- (CGFloat)visibleKeyboardBottomInset;
- (void)beginEditing;
- (void)resignEditing;
- (void)restorePreviewToSavedState;
- (void)setSaving:(BOOL)saving;
- (void)reset;

@end

NS_ASSUME_NONNULL_END

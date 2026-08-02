//
//  KayokoNoteEditorView.h
//  Kayoko
//

#import <UIKit/UIKit.h>

@class KayokoTableViewCell;
@class KayokoTag;
@class KayokoTagChipBarView;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoNoteEditorView : UIView

@property(nonatomic, strong, readonly) UIView *inputRowView;
@property(nonatomic, strong, readonly) UITextField *textField;
@property(nonatomic, strong, readonly) UIButton *saveButton;
@property(nonatomic, strong, readonly) UIButton *cancelButton;
@property(nonatomic, strong, readonly) KayokoTagChipBarView *tagChipBarView;
@property(nonatomic, strong, readonly, nullable) KayokoTableViewCell *previewCell;
@property(nonatomic, assign) CGFloat previewCellHeight;
@property(nonatomic, assign) CGFloat keyboardBottomInset;
@property(nonatomic, assign) BOOL automaticallyPositionsPreviewCell;
@property(nonatomic, assign) BOOL anchorsEditingContentToTop;
@property(nonatomic, assign, getter=usesCompactLayout) BOOL compactLayout;
@property(nonatomic, assign, readonly) CGFloat editingContentHeight;

- (void)setPreviewCell:(nullable KayokoTableViewCell *)previewCell;
- (void)configureTagBarWithTags:(NSArray<KayokoTag *> *)tags
                selectedTagUUID:(nullable NSString *)selectedTagUUID
               selectionHandler:(nullable void (^)(NSString *_Nullable tagUUID))selectionHandler;
- (CGRect)targetPreviewCellFrame;

@end

NS_ASSUME_NONNULL_END

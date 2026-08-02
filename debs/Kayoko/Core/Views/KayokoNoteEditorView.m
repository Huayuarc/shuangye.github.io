//
//  KayokoNoteEditorView.m
//  Kayoko
//

#import "KayokoNoteEditorView.h"

#import "KayokoTagChipBarView.h"
#import "KayokoTableViewCell.h"

static CGFloat const kKayokoNoteEditorDefaultCellHeight = 65;
static CGFloat const kKayokoNoteEditorInputHeight = 44;
static CGFloat const kKayokoNoteEditorHorizontalInset = 24;
static CGFloat const kKayokoNoteEditorPreviewTopSpacing = 10;
static CGFloat const kKayokoNoteEditorInputTopSpacing = 12;
static CGFloat const kKayokoNoteEditorInputBottomSpacing = 16;
static CGFloat const kKayokoNoteEditorTagBarTopSpacing = 6;
static CGFloat const kKayokoNoteEditorTagBarBottomSpacing = 10;
static CGFloat const kKayokoNoteEditorTextLeadingInset = 14;
static CGFloat const kKayokoNoteEditorTextTrailingInset = 6;
static CGFloat const kKayokoNoteEditorMinimumButtonWidth = 68;
static CGFloat const kKayokoNoteEditorSeparatorVerticalInset = 9;
static CGFloat const kKayokoNoteEditorCompactPreviewTopSpacing = 8;
static CGFloat const kKayokoNoteEditorCompactInputTopSpacing = 8;
static CGFloat const kKayokoNoteEditorCompactInputHeight = 40;
static CGFloat const kKayokoNoteEditorCompactTagBarTopSpacing = 4;
static CGFloat const kKayokoNoteEditorCompactTagBarHeight = 44;
static CGFloat const kKayokoNoteEditorCompactInputBottomSpacing = 10;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoNoteEditorView ()

@property(nonatomic, strong, readwrite) UIView *inputRowView;
@property(nonatomic, strong, readwrite) UITextField *textField;
@property(nonatomic, strong, readwrite) UIButton *saveButton;
@property(nonatomic, strong, readwrite) UIButton *cancelButton;
@property(nonatomic, strong, readwrite) KayokoTagChipBarView *tagChipBarView;
@property(nonatomic, strong, readwrite, nullable) KayokoTableViewCell *previewCell;
@property(nonatomic, strong) UIView *keyboardSpacerView;
@property(nonatomic, strong) UIView *saveSeparatorView;
@property(nonatomic, strong) UIView *cancelSeparatorView;

@end

@implementation KayokoNoteEditorView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _previewCellHeight = kKayokoNoteEditorDefaultCellHeight;
        _automaticallyPositionsPreviewCell = YES;
        [self setBackgroundColor:[UIColor clearColor]];
        [self setClipsToBounds:YES];

        _keyboardSpacerView = [[UIView alloc] init];
        [_keyboardSpacerView setBackgroundColor:[UIColor clearColor]];
        [_keyboardSpacerView setUserInteractionEnabled:NO];
        [self addSubview:_keyboardSpacerView];

        _inputRowView = [[UIView alloc] init];
        [_inputRowView setBackgroundColor:[UIColor tertiarySystemFillColor]];
        [[_inputRowView layer] setCornerRadius:8];
        [[_inputRowView layer] setCornerCurve:kCACornerCurveContinuous];
        [_inputRowView setClipsToBounds:YES];
        [self addSubview:_inputRowView];

        _textField = [[UITextField alloc] init];
        [_textField setBorderStyle:UITextBorderStyleNone];
        [_textField setBackgroundColor:[UIColor clearColor]];
        [_textField setClearButtonMode:UITextFieldViewModeWhileEditing];
        [_textField setFont:[UIFont systemFontOfSize:16]];
        [_textField setTextColor:[UIColor labelColor]];
        [_textField setReturnKeyType:UIReturnKeyDone];
        UIView *textLeadingInsetView =
            [[UIView alloc] initWithFrame:CGRectMake(0, 0, kKayokoNoteEditorTextLeadingInset, 1)];
        [_textField setLeftView:textLeadingInsetView];
        [_textField setLeftViewMode:UITextFieldViewModeAlways];
        [_inputRowView addSubview:_textField];

        _saveSeparatorView = [[UIView alloc] init];
        [_saveSeparatorView setBackgroundColor:[UIColor separatorColor]];
        [_saveSeparatorView setUserInteractionEnabled:NO];
        [_inputRowView addSubview:_saveSeparatorView];

        _saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_saveButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        [_saveButton setBackgroundColor:[UIColor clearColor]];
        [[_saveButton titleLabel] setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]];
        [_inputRowView addSubview:_saveButton];

        _cancelSeparatorView = [[UIView alloc] init];
        [_cancelSeparatorView setBackgroundColor:[UIColor separatorColor]];
        [_cancelSeparatorView setUserInteractionEnabled:NO];
        [_inputRowView addSubview:_cancelSeparatorView];

        _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_cancelButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [_cancelButton setBackgroundColor:[UIColor clearColor]];
        [[_cancelButton titleLabel] setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightRegular]];
        [_inputRowView addSubview:_cancelButton];

        _tagChipBarView = [[KayokoTagChipBarView alloc] initWithFrame:CGRectZero];
        [_tagChipBarView setBottomMaterialExtension:0];
        [_tagChipBarView setSettled:YES animated:NO];
        [self addSubview:_tagChipBarView];
    }
    return self;
}

- (void)setPreviewCell:(nullable KayokoTableViewCell *)previewCell {
    if (_previewCell == previewCell) {
        return;
    }

    [_previewCell removeFromSuperview];
    _previewCell = previewCell;
    if (_previewCell) {
        [_previewCell setSelectionStyle:UITableViewCellSelectionStyleNone];
        [_previewCell setUserInteractionEnabled:NO];
        [self insertSubview:_previewCell belowSubview:[self inputRowView]];
    }
    [self setNeedsLayout];
}

- (void)setPreviewCellHeight:(CGFloat)previewCellHeight {
    _previewCellHeight = MAX(previewCellHeight, 1);
    [self setNeedsLayout];
}

- (void)setKeyboardBottomInset:(CGFloat)keyboardBottomInset {
    _keyboardBottomInset = MAX(keyboardBottomInset, 0);
    [self setNeedsLayout];
}

- (void)setAnchorsEditingContentToTop:(BOOL)anchorsEditingContentToTop {
    if (_anchorsEditingContentToTop == anchorsEditingContentToTop) {
        return;
    }

    _anchorsEditingContentToTop = anchorsEditingContentToTop;
    [self setNeedsLayout];
}

- (void)setCompactLayout:(BOOL)compactLayout {
    if (_compactLayout == compactLayout) {
        return;
    }

    _compactLayout = compactLayout;
    [self setNeedsLayout];
}

- (CGFloat)previewTopSpacing {
    return [self usesCompactLayout] ? kKayokoNoteEditorCompactPreviewTopSpacing : kKayokoNoteEditorPreviewTopSpacing;
}

- (CGFloat)inputTopSpacing {
    return [self usesCompactLayout] ? kKayokoNoteEditorCompactInputTopSpacing : kKayokoNoteEditorInputTopSpacing;
}

- (CGFloat)inputHeight {
    return [self usesCompactLayout] ? kKayokoNoteEditorCompactInputHeight : kKayokoNoteEditorInputHeight;
}

- (CGFloat)tagBarTopSpacing {
    return [self usesCompactLayout] ? kKayokoNoteEditorCompactTagBarTopSpacing : kKayokoNoteEditorTagBarTopSpacing;
}

- (CGFloat)visibleTagBarHeight {
    if ([[self tagChipBarView] isHidden]) {
        return 0;
    }
    return [self usesCompactLayout] ? kKayokoNoteEditorCompactTagBarHeight : [KayokoTagChipBarView preferredHeight];
}

- (CGFloat)editingContentHeight {
    CGFloat tagBarHeight = [self visibleTagBarHeight];
    CGFloat inputBottomSpacing = tagBarHeight > 0
                                     ? [self tagBarTopSpacing] + tagBarHeight +
                                           ([self usesCompactLayout] ? kKayokoNoteEditorCompactInputBottomSpacing
                                                                     : kKayokoNoteEditorTagBarBottomSpacing)
                                     : ([self usesCompactLayout] ? kKayokoNoteEditorCompactInputBottomSpacing
                                                                 : kKayokoNoteEditorInputBottomSpacing);
    return [self previewTopSpacing] + [self previewCellHeight] + [self inputTopSpacing] + [self inputHeight] +
           inputBottomSpacing;
}

- (void)configureTagBarWithTags:(NSArray<KayokoTag *> *)tags
                selectedTagUUID:(nullable NSString *)selectedTagUUID
               selectionHandler:(nullable void (^)(NSString *_Nullable tagUUID))selectionHandler {
    [[self tagChipBarView] setSelectionHandler:selectionHandler];
    [[self tagChipBarView] configureWithTags:tags ?: @[] selectedTagUUID:selectedTagUUID];
    [[self tagChipBarView] setBottomMaterialExtension:0];
    [[self tagChipBarView] setSettled:YES animated:NO];
    [self setNeedsLayout];
}

- (CGRect)targetPreviewCellFrame {
    CGRect bounds = [self bounds];
    UIEdgeInsets safeAreaInsets = [self safeAreaInsets];
    CGFloat minimumContentOriginY = MAX(safeAreaInsets.top, 0);
    CGFloat contentOriginY =
        [self anchorsEditingContentToTop]
            ? minimumContentOriginY
            : MAX(CGRectGetHeight(bounds) - [self keyboardBottomInset] - [self editingContentHeight],
                  minimumContentOriginY);
    CGFloat y = contentOriginY + [self previewTopSpacing];
    CGFloat width = MAX(CGRectGetWidth(bounds) - safeAreaInsets.left - safeAreaInsets.right, 0);
    return CGRectMake(safeAreaInsets.left, y, width, [self previewCellHeight]);
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = [self bounds];
    CGRect previewFrame = [self targetPreviewCellFrame];
    if ([self automaticallyPositionsPreviewCell]) {
        [[self previewCell] setFrame:previewFrame];
    }

    UIEdgeInsets safeAreaInsets = [self safeAreaInsets];
    CGFloat leadingInset = safeAreaInsets.left + kKayokoNoteEditorHorizontalInset;
    CGFloat trailingInset = safeAreaInsets.right + kKayokoNoteEditorHorizontalInset;
    CGFloat availableWidth = MAX(CGRectGetWidth(bounds) - leadingInset - trailingInset, 0);
    CGFloat inputHeight = [self inputHeight];
    CGSize saveButtonSize = [[self saveButton] sizeThatFits:CGSizeMake(CGFLOAT_MAX, inputHeight)];
    CGSize cancelButtonSize = [[self cancelButton] sizeThatFits:CGSizeMake(CGFLOAT_MAX, inputHeight)];
    CGFloat saveButtonWidth = MAX(ceil(saveButtonSize.width) + 28, kKayokoNoteEditorMinimumButtonWidth);
    CGFloat cancelButtonWidth = MAX(ceil(cancelButtonSize.width) + 28, kKayokoNoteEditorMinimumButtonWidth);
    CGFloat actionButtonsWidth = saveButtonWidth + cancelButtonWidth;
    if (actionButtonsWidth > availableWidth) {
        CGFloat scale = availableWidth / MAX(actionButtonsWidth, 1);
        saveButtonWidth = floor(saveButtonWidth * scale);
        cancelButtonWidth = MAX(availableWidth - saveButtonWidth, 0);
    }
    CGFloat textFieldWidth = MAX(availableWidth - saveButtonWidth - cancelButtonWidth, 0);

    CGFloat inputY = CGRectGetMaxY(previewFrame) + [self inputTopSpacing];
    [[self inputRowView] setFrame:CGRectMake(leadingInset, inputY, availableWidth, inputHeight)];
    [[self textField] setFrame:CGRectMake(0, 0, MAX(textFieldWidth - kKayokoNoteEditorTextTrailingInset, 0),
                                          inputHeight)];
    CGFloat separatorWidth = 1.0 / [UIScreen mainScreen].scale;
    CGFloat separatorHeight = inputHeight - kKayokoNoteEditorSeparatorVerticalInset * 2;
    [[self saveSeparatorView]
        setFrame:CGRectMake(textFieldWidth, kKayokoNoteEditorSeparatorVerticalInset, separatorWidth, separatorHeight)];
    [[self saveButton] setFrame:CGRectMake(textFieldWidth + separatorWidth, 0, MAX(saveButtonWidth - separatorWidth, 0),
                                           inputHeight)];
    CGFloat cancelOriginX = textFieldWidth + saveButtonWidth;
    [[self cancelSeparatorView]
        setFrame:CGRectMake(cancelOriginX, kKayokoNoteEditorSeparatorVerticalInset, separatorWidth, separatorHeight)];
    [[self cancelButton]
        setFrame:CGRectMake(cancelOriginX + separatorWidth, 0, MAX(cancelButtonWidth - separatorWidth, 0),
                            inputHeight)];

    CGFloat tagBarHeight = [self visibleTagBarHeight];
    if (tagBarHeight > 0) {
        CGFloat tagBarY = CGRectGetMaxY([[self inputRowView] frame]) + [self tagBarTopSpacing];
        [[self tagChipBarView] setFrame:CGRectMake(leadingInset, tagBarY, availableWidth, tagBarHeight)];
        [[self tagChipBarView] layoutIfNeeded];
    } else {
        [[self tagChipBarView] setFrame:CGRectZero];
    }

    CGFloat spacerHeight = MIN([self keyboardBottomInset], CGRectGetHeight(bounds));
    [[self keyboardSpacerView]
        setFrame:CGRectMake(0, CGRectGetHeight(bounds) - spacerHeight, CGRectGetWidth(bounds), spacerHeight)];
}

@end

NS_ASSUME_NONNULL_END

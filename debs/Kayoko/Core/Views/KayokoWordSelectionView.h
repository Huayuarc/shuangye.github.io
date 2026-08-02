//
//  KayokoWordSelectionView.h
//  Kayoko
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KayokoHeaderView;

@interface KayokoWordSelectionView : UIView

@property(nonatomic, strong, readonly) KayokoHeaderView *headerView;
@property(nonatomic, strong, readonly) UIView *transitionContentView;
@property(nonatomic, copy, readonly) NSString *selectedText;
@property(nonatomic, assign, readonly) BOOL hasTokens;
@property(nonatomic, assign, readonly) BOOL hasSelectedText;
@property(nonatomic, assign, readonly) BOOL hasAllTokensSelected;
@property(nonatomic, assign, readonly) BOOL hasCustomSelection;
@property(nonatomic, assign) BOOL usesSelectionOrderForSelectedText;
@property(nonatomic, assign) CGFloat keyboardBottomInset;
@property(nonatomic, copy, nullable) void (^selectionChangedHandler)(void);

- (void)setText:(NSString *)text;
- (BOOL)selectAllTokens;
- (BOOL)clearSelectedTokens;
- (void)reset;
- (void)scrollToTopAnimated:(BOOL)animated;
- (void)requireSelectionGestureRecognizerToFailGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer;

@end

NS_ASSUME_NONNULL_END

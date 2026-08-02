//
//  KayokoClearConfirmationView.h
//  Kayoko
//
//  Created by Alexandra Aurora Göttlicher
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KayokoClearConfirmationView : UIView

@property(nonatomic, strong, readonly) UIButton *cancelButton;
@property(nonatomic, strong, readonly) UIButton *confirmButton;
@property(nonatomic, assign) CGFloat keyboardBottomInset;

- (void)updateWithHistoryKey:(NSString *)historyKey;
- (void)updateWithHistoryKey:(NSString *)historyKey imagesOnly:(BOOL)imagesOnly;

@end

NS_ASSUME_NONNULL_END

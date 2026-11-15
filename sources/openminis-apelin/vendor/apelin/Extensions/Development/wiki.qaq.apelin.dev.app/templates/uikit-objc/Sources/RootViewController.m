// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The first screen: replace it with the app. The build defines
// APELIN_VERSION and APELIN_BUILD_ID as string literals on every compile.
#import "RootViewController.h"

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"{{displayName}}";

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = @"{{displayName}}";
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    titleLabel.numberOfLines = 0;
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *detailLabel = [UILabel new];
    detailLabel.text = [NSString stringWithFormat:@"Built on this device with Apelin.\nVersion %s (%s)", APELIN_VERSION, APELIN_BUILD_ID];
    detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    detailLabel.adjustsFontForContentSizeCategory = YES;
    detailLabel.textColor = UIColor.secondaryLabelColor;
    detailLabel.numberOfLines = 0;
    detailLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, detailLabel ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
    ]];
}

@end

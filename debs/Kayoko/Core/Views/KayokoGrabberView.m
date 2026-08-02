//
//  KayokoGrabberView.m
//  Kayoko
//
//  Created by Alexandra Aurora Göttlicher
//

#import "KayokoGrabberView.h"

#import <QuartzCore/QuartzCore.h>

@interface KayokoGrabberView ()
@property(nonatomic, strong) CAShapeLayer *lineLayer;
@end

@implementation KayokoGrabberView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _lineLayer = [CAShapeLayer layer];
        [[self lineLayer] setFillColor:nil];
        [[self lineLayer] setLineCap:kCALineCapRound];
        [[self lineLayer] setLineJoin:kCALineJoinRound];
        // Slightly thicker / longer for the floating sheet header.
        [[self lineLayer] setLineWidth:5.0];
        [[self layer] addSublayer:[self lineLayer]];
        [self setContentMode:UIViewContentModeRedraw];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    // Give the grabber real presence so the segment is not visually crushed.
    return CGSizeMake(42, 14);
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self updateLineColor];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateLineColor];
}

- (void)updateLineColor {
    UIColor *lineColor = [[UIColor labelColor] colorWithAlphaComponent:0.22];
    [[self lineLayer] setStrokeColor:[lineColor CGColor]];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateLineColor];

    CGRect bounds = [self bounds];
    CGFloat minX = 3.0;
    CGFloat maxX = CGRectGetWidth(bounds) - 3.0;
    CGFloat midX = CGRectGetMidX(bounds);
    CGFloat midY = CGRectGetMidY(bounds);
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX, midY)];
    [path addLineToPoint:CGPointMake(midX, midY)];
    [path addLineToPoint:CGPointMake(maxX, midY)];
    [[self lineLayer] setFrame:bounds];
    [[self lineLayer] setPath:[path CGPath]];
}

@end

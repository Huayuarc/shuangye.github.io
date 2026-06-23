// JadeMediaModule.h
// Media playback control module for the Jade control center

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JadeMediaModule : UIView

@property (nonatomic, strong, nullable) UIImageView *artworkImageView;
@property (nonatomic, strong, nullable) UILabel *trackTitleLabel;
@property (nonatomic, strong, nullable) UILabel *artistLabel;
@property (nonatomic, strong, nullable) UILabel *albumLabel;
@property (nonatomic, strong, nullable) UIButton *playPauseButton;
@property (nonatomic, strong, nullable) UIButton *nextTrackButton;
@property (nonatomic, strong, nullable) UIButton *previousTrackButton;
@property (nonatomic, strong, nullable) UIProgressView *progressView;
@property (nonatomic, strong, nullable) UILabel *elapsedTimeLabel;
@property (nonatomic, strong, nullable) UILabel *remainingTimeLabel;
@property (nonatomic, strong, nullable) UIView *separatorLine;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, strong, nullable) UIColor *textColor;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL hasActiveMedia;
@property (nonatomic, assign) BOOL isExpanded;

- (void)setupViews;
- (void)setupConstraints;
- (void)updateMediaInfo;
- (void)updatePlaybackState;
- (void)updateProgress;
- (void)playPauseAction;
- (void)nextTrackAction;
- (void)previousTrackAction;
- (void)startUpdatingProgress;
- (void)stopUpdatingProgress;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END

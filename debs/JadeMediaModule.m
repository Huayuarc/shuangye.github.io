// JadeMediaModule.m
// Media playback control module for the Jade control center
// Uses MRMediaRemote C API for now-playing info and transport controls

#import "JadeMediaModule.h"
#import <MediaRemote/MediaRemote.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>


@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithPid:(NSInteger)pid;
@end

@interface JadeMediaModule ()
@property (nonatomic, strong) NSTimer *progressUpdateTimer;
@property (nonatomic, assign) double currentDuration;
@property (nonatomic, assign) double currentElapsedTime;
@property (nonatomic, strong) NSUserDefaults *prefs;
@end

@implementation JadeMediaModule

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
        _hasActiveMedia = NO;
        _isPlaying = NO;
        _isExpanded = NO;
        _currentDuration = 0.0;
        _currentElapsedTime = 0.0;
        [self setupViews];
        [self setupConstraints];

        // Register for MRMediaRemote notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_mediaRemoteNowPlayingInfoDidChange:)
                                                     name:(__bridge NSString *)kMRMediaRemoteNowPlayingInfoDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_mediaRemoteNowPlayingApplicationIsPlayingDidChange:)
                                                     name:(__bridge NSString *)kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
                                                   object:nil];

        // Initial fetch
        [self updateMediaInfo];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopUpdatingProgress];
}

#pragma mark - View Setup

- (void)setupViews {
    // Artwork Image View
    _artworkImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkImageView.clipsToBounds = YES;
    _artworkImageView.layer.cornerRadius = 8;
    _artworkImageView.image = [self placeholderImage];
    _artworkImageView.tintColor = [UIColor tertiaryLabelColor];
    _artworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_artworkImageView];

    // Track Title Label
    _trackTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _trackTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _trackTitleLabel.textColor = [UIColor labelColor];
    _trackTitleLabel.numberOfLines = 1;
    _trackTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_trackTitleLabel];

    // Artist Label
    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _artistLabel.textColor = [UIColor secondaryLabelColor];
    _artistLabel.numberOfLines = 1;
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_artistLabel];

    // Album Label
    _albumLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _albumLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _albumLabel.textColor = [UIColor tertiaryLabelColor];
    _albumLabel.numberOfLines = 1;
    _albumLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_albumLabel];

    // Progress View
    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progressTintColor = [UIColor systemPinkColor];
    _progressView.trackTintColor = [UIColor separatorColor];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_progressView];

    // Elapsed Time Label
    _elapsedTimeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _elapsedTimeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    _elapsedTimeLabel.textColor = [UIColor tertiaryLabelColor];
    _elapsedTimeLabel.text = @"0:00";
    _elapsedTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_elapsedTimeLabel];

    // Remaining Time Label
    _remainingTimeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _remainingTimeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    _remainingTimeLabel.textColor = [UIColor tertiaryLabelColor];
    _remainingTimeLabel.textAlignment = NSTextAlignmentRight;
    _remainingTimeLabel.text = @"0:00";
    _remainingTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_remainingTimeLabel];

    // Previous Track Button
    _previousTrackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_previousTrackButton setImage:[UIImage systemImageNamed:@"backward.fill"] forState:UIControlStateNormal];
    _previousTrackButton.tintColor = [UIColor labelColor];
    [_previousTrackButton addTarget:self action:@selector(previousTrackAction) forControlEvents:UIControlEventTouchUpInside];
    _previousTrackButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_previousTrackButton];

    // Play/Pause Button
    _playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_playPauseButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    _playPauseButton.tintColor = [UIColor labelColor];
    _playPauseButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [_playPauseButton addTarget:self action:@selector(playPauseAction) forControlEvents:UIControlEventTouchUpInside];
    _playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_playPauseButton];

    // Next Track Button
    _nextTrackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_nextTrackButton setImage:[UIImage systemImageNamed:@"forward.fill"] forState:UIControlStateNormal];
    _nextTrackButton.tintColor = [UIColor labelColor];
    [_nextTrackButton addTarget:self action:@selector(nextTrackAction) forControlEvents:UIControlEventTouchUpInside];
    _nextTrackButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_nextTrackButton];

    // Separator Line
    _separatorLine = [[UIView alloc] initWithFrame:CGRectZero];
    _separatorLine.backgroundColor = [UIColor separatorColor];
    _separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_separatorLine];
}

- (void)setupConstraints {
    CGFloat artworkSize = 44.0;

    [NSLayoutConstraint activateConstraints:@[
        // Artwork Image View
        [_artworkImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_artworkImageView.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_artworkImageView.widthAnchor constraintEqualToConstant:artworkSize],
        [_artworkImageView.heightAnchor constraintEqualToConstant:artworkSize],

        // Track Title Label
        [_trackTitleLabel.leadingAnchor constraintEqualToAnchor:_artworkImageView.trailingAnchor constant:10],
        [_trackTitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_trackTitleLabel.topAnchor constraintEqualToAnchor:_artworkImageView.topAnchor],

        // Artist Label
        [_artistLabel.leadingAnchor constraintEqualToAnchor:_trackTitleLabel.leadingAnchor],
        [_artistLabel.trailingAnchor constraintEqualToAnchor:_trackTitleLabel.trailingAnchor],
        [_artistLabel.topAnchor constraintEqualToAnchor:_trackTitleLabel.bottomAnchor constant:1],

        // Album Label
        [_albumLabel.leadingAnchor constraintEqualToAnchor:_trackTitleLabel.leadingAnchor],
        [_albumLabel.trailingAnchor constraintEqualToAnchor:_trackTitleLabel.trailingAnchor],
        [_albumLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:1],

        // Progress View
        [_progressView.leadingAnchor constraintEqualToAnchor:_artworkImageView.leadingAnchor],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_progressView.topAnchor constraintEqualToAnchor:_artworkImageView.bottomAnchor constant:10],

        // Elapsed Time Label
        [_elapsedTimeLabel.leadingAnchor constraintEqualToAnchor:_progressView.leadingAnchor],
        [_elapsedTimeLabel.topAnchor constraintEqualToAnchor:_progressView.bottomAnchor constant:2],

        // Remaining Time Label
        [_remainingTimeLabel.trailingAnchor constraintEqualToAnchor:_progressView.trailingAnchor],
        [_remainingTimeLabel.topAnchor constraintEqualToAnchor:_elapsedTimeLabel.topAnchor],

        // Previous Track Button
        [_previousTrackButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor constant:-60],
        [_previousTrackButton.topAnchor constraintEqualToAnchor:_elapsedTimeLabel.bottomAnchor constant:8],
        [_previousTrackButton.widthAnchor constraintEqualToConstant:36],
        [_previousTrackButton.heightAnchor constraintEqualToConstant:36],

        // Play/Pause Button
        [_playPauseButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_playPauseButton.centerYAnchor constraintEqualToAnchor:_previousTrackButton.centerYAnchor],
        [_playPauseButton.widthAnchor constraintEqualToConstant:40],
        [_playPauseButton.heightAnchor constraintEqualToConstant:40],

        // Next Track Button
        [_nextTrackButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor constant:60],
        [_nextTrackButton.centerYAnchor constraintEqualToAnchor:_previousTrackButton.centerYAnchor],
        [_nextTrackButton.widthAnchor constraintEqualToConstant:36],
        [_nextTrackButton.heightAnchor constraintEqualToConstant:36],

        // Separator Line
        [_separatorLine.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_separatorLine.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_separatorLine.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_separatorLine.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],
    ]];
}

#pragma mark - Media Info Updates

- (void)updateMediaInfo {
    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef information) {
        NSDictionary *info = (__bridge NSDictionary *)information;
        if (!info || info.count == 0) {
            self.hasActiveMedia = NO;
            [self showNoMediaState];
            return;
        }

        self.hasActiveMedia = YES;
        self.hidden = NO;

        // Title
        NSString *title = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoTitle];
        if (title) {
            self.trackTitleLabel.text = title;
            self.trackTitleLabel.hidden = NO;
        } else {
            self.trackTitleLabel.hidden = YES;
        }

        // Artist
        NSString *artist = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoArtist];
        if (artist) {
            self.artistLabel.text = artist;
            self.artistLabel.hidden = NO;
        } else {
            self.artistLabel.hidden = YES;
        }

        // Album
        NSString *album = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoAlbum];
        if (album) {
            self.albumLabel.text = album;
            self.albumLabel.hidden = NO;
        } else {
            self.albumLabel.hidden = YES;
        }

        // Duration & Elapsed Time
        NSNumber *duration = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoDuration];
        NSNumber *elapsedTime = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoElapsedTime];
        if (duration && elapsedTime) {
            self.currentDuration = [duration doubleValue];
            self.currentElapsedTime = [elapsedTime doubleValue];
            [self updateProgress];
        }

        // Artwork
        NSData *artworkData = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoArtworkData];
        if (artworkData) {
            UIImage *artwork = [UIImage imageWithData:artworkData];
            if (artwork) {
                self.artworkImageView.image = artwork;
                self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
            } else {
                self.artworkImageView.image = [self placeholderImage];
            }
        } else {
            self.artworkImageView.image = [self placeholderImage];
        }

        [self updatePlaybackState];
        [self updateProgress];
    });
}

- (void)updatePlaybackState {
    MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
        self.isPlaying = (BOOL)playing;
        [self updatePlayPauseIcon];
    });
}

- (void)updatePlayPauseIcon {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightRegular];
    if (self.isPlaying) {
        [self.playPauseButton setImage:[UIImage systemImageNamed:@"pause.fill" withConfiguration:config] forState:UIControlStateNormal];
    } else {
        [self.playPauseButton setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:config] forState:UIControlStateNormal];
    }
}

- (void)updateProgress {
    if (self.currentDuration > 0) {
        float progress = self.currentElapsedTime / self.currentDuration;
        self.progressView.progress = progress;
    } else {
        self.progressView.progress = 0;
    }

    self.elapsedTimeLabel.text = [self formattedTime:self.currentElapsedTime];
    double remaining = self.currentDuration - self.currentElapsedTime;
    if (remaining < 0) remaining = 0;
    self.remainingTimeLabel.text = [NSString stringWithFormat:@"-%@", [self formattedTime:remaining]];
}

- (NSString *)formattedTime:(double)seconds {
    int totalSeconds = (int)round(seconds);
    int mins = totalSeconds / 60;
    int secs = totalSeconds % 60;
    return [NSString stringWithFormat:@"%d:%02d", mins, secs];
}

#pragma mark - Transport Controls

- (void)playPauseAction {
    MRMediaRemoteSendCommand(MRMediaRemoteCommandTogglePlayPause, nil);
}

- (void)nextTrackAction {
    MRMediaRemoteSendCommand(MRMediaRemoteCommandNextTrack, nil);
}

- (void)previousTrackAction {
    MRMediaRemoteSendCommand(MRMediaRemoteCommandPreviousTrack, nil);
}

- (void)openNowPlayingApplication {
    MRMediaRemoteGetNowPlayingApplicationPID(dispatch_get_main_queue(), ^(int PID) {
        if (PID <= 0) return;

        NSString *bundleIdentifier = nil;
        Class appControllerClass = NSClassFromString(@"SBApplicationController");
        id appController = [appControllerClass respondsToSelector:@selector(sharedInstance)] ? [appControllerClass sharedInstance] : nil;
        SEL appWithPidSel = NSSelectorFromString(@"applicationWithPid:");
        if (appController && [appController respondsToSelector:appWithPidSel]) {
            id (*applicationWithPid)(id, SEL, NSInteger) = (id (*)(id, SEL, NSInteger))[appController methodForSelector:appWithPidSel];
            id application = applicationWithPid(appController, appWithPidSel, PID);
            SEL bundleIdentifierSel = NSSelectorFromString(@"bundleIdentifier");
            if (application && [application respondsToSelector:bundleIdentifierSel]) {
                NSString *(*getBundleIdentifier)(id, SEL) = (NSString *(*)(id, SEL))[application methodForSelector:bundleIdentifierSel];
                bundleIdentifier = getBundleIdentifier(application, bundleIdentifierSel);
            }
        }
        if (!bundleIdentifier.length) return;

        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = nil;
        if ([workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
            workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        }

        SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (workspace && [workspace respondsToSelector:openSelector]) {
            ((void (*)(id, SEL, NSString *))[workspace methodForSelector:openSelector])(workspace, openSelector, bundleIdentifier);
        }
    });
}

#pragma mark - Progress Timer

- (void)startUpdatingProgress {
    [self stopUpdatingProgress];
    _progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                            target:self
                                                          selector:@selector(_tickProgress:)
                                                          userInfo:nil
                                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_progressUpdateTimer forMode:NSRunLoopCommonModes];
}

- (void)stopUpdatingProgress {
    [_progressUpdateTimer invalidate];
    _progressUpdateTimer = nil;
}

- (void)_tickProgress:(NSTimer *)timer {
    if (self.isPlaying && self.currentDuration > 0) {
        self.currentElapsedTime += 1.0;
        [self updateProgress];
    }
}

- (void)resetProgress {
    self.currentElapsedTime = 0;
    [self updateProgress];
}

#pragma mark - Gesture Recognizer

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return YES;
}

- (void)setContentOpacity:(CGFloat)opacity {
    self.alpha = opacity;
}

#pragma mark - Placeholder

- (UIImage *)placeholderImage {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIFontWeightRegular];
    UIImage *image = [UIImage systemImageNamed:@"music.note" withConfiguration:config];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - No Media State

- (void)showNoMediaState {
    BOOL hideWhenNotPlaying = [self.prefs boolForKey:@"hideMediaWhenNotPlaying"];
    if (hideWhenNotPlaying) {
        self.hidden = YES;
    } else {
        self.hidden = NO;
        self.trackTitleLabel.text = NSLocalizedString(@"No Media Playing", nil);
        self.artistLabel.text = nil;
        self.artistLabel.hidden = YES;
        self.albumLabel.text = nil;
        self.albumLabel.hidden = YES;
        self.artworkImageView.image = [self placeholderImage];
        self.artworkImageView.contentMode = UIViewContentModeCenter;
        self.artworkImageView.tintColor = [UIColor tertiaryLabelColor];
        self.progressView.progress = 0;
        self.elapsedTimeLabel.text = @"0:00";
        self.remainingTimeLabel.text = @"0:00";
        [self updatePlayPauseIcon];
    }
}

#pragma mark - Tint Color

- (void)setModuleTintColor:(UIColor *)moduleTintColor {
    _moduleTintColor = moduleTintColor;
    self.progressView.progressTintColor = moduleTintColor;
}

- (void)setTextColor:(UIColor *)textColor {
    _textColor = textColor;
    self.trackTitleLabel.textColor = textColor;
    self.artistLabel.textColor = textColor;
    self.albumLabel.textColor = [textColor colorWithAlphaComponent:0.7];
    self.elapsedTimeLabel.textColor = [textColor colorWithAlphaComponent:0.6];
    self.remainingTimeLabel.textColor = [textColor colorWithAlphaComponent:0.6];
    self.previousTrackButton.tintColor = textColor;
    self.playPauseButton.tintColor = textColor;
    self.nextTrackButton.tintColor = textColor;
}

#pragma mark - Expanded State

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _isExpanded = expanded;
    CGFloat alpha = expanded ? 1.0 : 0.0;
    NSTimeInterval duration = animated ? 0.25 : 0.0;

    [UIView animateWithDuration:duration animations:^{
        self.albumLabel.alpha = alpha;
        self.separatorLine.alpha = alpha;
    }];

    if (expanded) {
        [self startUpdatingProgress];
    } else {
        [self stopUpdatingProgress];
    }
}

#pragma mark - Notification Handlers

- (void)_mediaRemoteNowPlayingInfoDidChange:(NSNotification *)notification {
    [self updateMediaInfo];
}

- (void)_mediaRemoteNowPlayingApplicationIsPlayingDidChange:(NSNotification *)notification {
    [self updatePlaybackState];
}

#pragma mark - Preference Colors

- (void)applyPreferences {
    NSString *progressColorStr = [self.prefs stringForKey:@"mediaProgressColor"];
    if (progressColorStr) {
        UIColor *progressColor = [self colorFromHexString:progressColorStr];
        if (progressColor) {
            self.progressView.progressTintColor = progressColor;
            return;
        }
    }
    self.progressView.progressTintColor = [UIColor systemPinkColor];

    BOOL hideProgress = [self.prefs boolForKey:@"hideMediaProgress"];
    self.progressView.hidden = hideProgress;
    self.elapsedTimeLabel.hidden = hideProgress;
    self.remainingTimeLabel.hidden = hideProgress;

    BOOL hideIcon = [self.prefs boolForKey:@"hideMediaIcon"];
    self.artworkImageView.hidden = hideIcon;

    // Text colors
    NSString *titleColorStr = [self.prefs stringForKey:@"mediaTitleTextColor"];
    if (titleColorStr) {
        UIColor *color = [self colorFromHexString:titleColorStr];
        if (color) self.trackTitleLabel.textColor = color;
    }

    NSString *subtitleColorStr = [self.prefs stringForKey:@"mediaSubtitleTextColor"];
    if (subtitleColorStr) {
        UIColor *color = [self colorFromHexString:subtitleColorStr];
        if (color) {
            self.artistLabel.textColor = color;
            self.albumLabel.textColor = color;
        }
    }

    // Button tint colors
    NSString *backColorStr = [self.prefs stringForKey:@"mediaBackwardImageTintColor"];
    if (backColorStr) {
        UIColor *color = [self colorFromHexString:backColorStr];
        if (color) self.previousTrackButton.tintColor = color;
    }

    NSString *playColorStr = [self.prefs stringForKey:@"mediaPlayImageTintColor"];
    if (playColorStr) {
        UIColor *color = [self colorFromHexString:playColorStr];
        if (color) self.playPauseButton.tintColor = color;
    }

    NSString *forwardColorStr = [self.prefs stringForKey:@"mediaForwardImageTintColor"];
    if (forwardColorStr) {
        UIColor *color = [self colorFromHexString:forwardColorStr];
        if (color) self.nextTrackButton.tintColor = color;
    }
}

#pragma mark - Utility

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *cleanString = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([cleanString hasPrefix:@"#"]) {
        cleanString = [cleanString substringFromIndex:1];
    }
    if ([cleanString hasPrefix:@"0x"]) {
        cleanString = [cleanString substringFromIndex:2];
    }

    NSUInteger length = [cleanString length];
    if (length != 6 && length != 8) return nil;

    NSScanner *scanner = [NSScanner scannerWithString:cleanString];
    unsigned long long hexValue = 0;
    if (![scanner scanHexLongLong:&hexValue]) return nil;

    CGFloat red, green, blue, alpha;
    if (length == 8) {
        red   = ((hexValue & 0xFF000000) >> 24) / 255.0;
        green = ((hexValue & 0x00FF0000) >> 16) / 255.0;
        blue  = ((hexValue & 0x0000FF00) >> 8)  / 255.0;
        alpha =  (hexValue & 0x000000FF)         / 255.0;
    } else {
        red   = ((hexValue & 0xFF0000) >> 16) / 255.0;
        green = ((hexValue & 0x00FF00) >> 8)  / 255.0;
        blue  =  (hexValue & 0x0000FF)        / 255.0;
        alpha = 1.0;
    }

    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}


@end

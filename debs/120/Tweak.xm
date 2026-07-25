#import <UIKit/UIKit.h>

%hook UIScreen
- (id)_display {
	return %orig;
}
%end

%hook UIScreen
- (long long)maximumFramesPerSecond {
	return %orig;
}
%end

%hook UIScreen
- (double)_refreshRate {
	return %orig;
}
%end


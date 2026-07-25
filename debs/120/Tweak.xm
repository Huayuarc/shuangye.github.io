#import <UIKit/UIKit.h>

%hook UIScreen

- (id)_display {
	return %orig;
}

- (NSInteger)maximumFramesPerSecond {
    // 强制最大刷新率120帧
	return 120;
}

- (CGFloat)_refreshRate {
    // 强制屏幕刷新率120Hz
	return 120.0;
}

- (NSInteger)preferredFramesPerSecond {
    // 补充钩子，适配系统UI控件刷新率获取
	return 120;
}

%end
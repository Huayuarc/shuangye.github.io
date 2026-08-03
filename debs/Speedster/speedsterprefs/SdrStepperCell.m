#import "sdrRootListController.h"
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>

// ============================================================================
// Dock 图标数量 +/- 调节 cell（FiveIconDockXI 移植）
// 默认 4 个图标，范围 4-10，跟随"自定义 Dock 图标数量"开关启用/禁用
// ============================================================================
@implementation SdrStepperCell {
	UIStepper *_stepper;
	UILabel *_valueLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
	if (self) {
		self.accessoryType = UITableViewCellAccessoryNone;
		self.selectionStyle = UITableViewCellSelectionStyleNone;

		// 数值标签
		_valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_valueLabel.textAlignment = NSTextAlignmentCenter;
		_valueLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
		_valueLabel.textColor = [UIColor systemOrangeColor];
		_valueLabel.adjustsFontSizeToFitWidth = YES;
		[self.contentView addSubview:_valueLabel];

		// +/- stepper
		_stepper = [[UIStepper alloc] initWithFrame:CGRectZero];
		_stepper.minimumValue = [specifier propertyForKey:@"min"] ? [[specifier propertyForKey:@"min"] doubleValue] : 4;
		_stepper.maximumValue = [specifier propertyForKey:@"max"] ? [[specifier propertyForKey:@"max"] doubleValue] : 10;
		_stepper.stepValue = [specifier propertyForKey:@"step"] ? [[specifier propertyForKey:@"step"] doubleValue] : 1;
		_stepper.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
		[_stepper addTarget:self action:@selector(_stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
		[self.contentView addSubview:_stepper];

		[self _updateValueUI];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];

	CGFloat width = self.contentView.bounds.size.width;
	CGFloat height = self.contentView.bounds.size.height;

	CGFloat stepperWidth = 94.0;
	CGFloat stepperHeight = 29.0;
	_stepper.frame = CGRectMake(width - stepperWidth - 16.0, (height - stepperHeight) / 2.0, stepperWidth, stepperHeight);

	CGFloat labelWidth = 52.0;
	_valueLabel.frame = CGRectMake(width - stepperWidth - 16.0 - labelWidth - 10.0, 0.0, labelWidth, height);
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
	[super refreshCellContentsWithSpecifier:specifier];
	[self _updateValueUI];
}

- (void)_updateValueUI {
	NSInteger intVal = 4;
	id value = [self readPreferenceValue:self.specifier];
	if (value) intVal = [value integerValue];
	if (intVal < 4) intVal = 4;
	if (intVal > 10) intVal = 10;

	_stepper.value = intVal;
	_valueLabel.text = [NSString stringWithFormat:@"%ld", (long)intVal];

	// 跟随"自定义 Dock 图标数量"开关禁用/启用
	NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hoangdus.speedsterprefs"];
	BOOL enabled = [prefs[@"dockIconCountEnabled"] boolValue];
	_stepper.enabled = enabled;
	_stepper.alpha = enabled ? 1.0 : 0.4;
	_valueLabel.alpha = enabled ? 1.0 : 0.4;
}

- (void)_stepperValueChanged:(UIStepper *)sender {
	[self setPreferenceValue:@((NSInteger)sender.value) specifier:self.specifier];
	[self _updateValueUI];
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.hoangdus.speedsterprefs-updated"), NULL, NULL, YES);
}

@end

#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <CPUthermalPaths.h>
#import <CPUthermalPressure.h>

@interface CPUthermalThermalStatusCell : PSTableCell
@property(nonatomic,strong) UILabel *pressureTitle;
@property(nonatomic,strong) UILabel *pressureSubtitle;
@property(nonatomic,strong) UIStackView *segments;
@property(nonatomic,strong) UILabel *notificationTitle;
@property(nonatomic,strong) UILabel *notificationValue;
@property(nonatomic,strong) UIButton *resetButton;
@property(nonatomic,assign) int pressureToken;
@property(nonatomic,assign) int notificationToken;
@end

@implementation CPUthermalThermalStatusCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    self=[super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier specifier:specifier];
    if(!self)return nil;
    self.selectionStyle=UITableViewCellSelectionStyleNone;
    self.backgroundColor=[UIColor clearColor];
    _pressureTitle=[UILabel new]; _pressureTitle.text=S("温控压力"); _pressureTitle.font=[UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    _pressureSubtitle=[UILabel new]; _pressureSubtitle.font=[UIFont systemFontOfSize:13 weight:UIFontWeightRegular]; _pressureSubtitle.textColor=[UIColor secondaryLabelColor];
    _segments=[[UIStackView alloc] init]; _segments.axis=UILayoutConstraintAxisHorizontal; _segments.spacing=1.5; _segments.distribution=UIStackViewDistributionFillEqually;
    NSArray *colors=@[[UIColor systemGreenColor],[UIColor colorWithRed:.72 green:.86 blue:.66 alpha:1],[UIColor colorWithRed:.87 green:.88 blue:.65 alpha:1],[UIColor colorWithRed:.92 green:.80 blue:.62 alpha:1],[UIColor colorWithRed:.92 green:.63 blue:.61 alpha:1]];
    for(UIColor *color in colors){UIView*v=[UIView new];v.backgroundColor=color;v.layer.cornerRadius=3;[_segments addArrangedSubview:v];}
    _notificationTitle=[UILabel new]; _notificationTitle.text=S("通知"); _notificationTitle.font=[UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    _notificationValue=[UILabel new]; _notificationValue.textAlignment=NSTextAlignmentRight; _notificationValue.font=[UIFont systemFontOfSize:17 weight:UIFontWeightRegular]; _notificationValue.textColor=[UIColor secondaryLabelColor];
    _resetButton=[UIButton buttonWithType:UIButtonTypeSystem]; [_resetButton setTitle:S("重置") forState:UIControlStateNormal]; _resetButton.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; _resetButton.backgroundColor=[UIColor tertiarySystemFillColor]; _resetButton.layer.cornerRadius=11; [_resetButton addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    for(UIView*v in @[_pressureTitle,_pressureSubtitle,_segments,_notificationTitle,_notificationValue,_resetButton]) [self.contentView addSubview:v];
    __weak typeof(self) weakSelf=self;
    notify_register_dispatch(kOSThermalNotificationPressureLevelName,&_pressureToken,dispatch_get_main_queue(),^(int token){(void)token;[weakSelf refreshState];});
    notify_register_dispatch("com.apple.system.thermalnotification",&_notificationToken,dispatch_get_main_queue(),^(int token){(void)token;[weakSelf refreshState];});
    [self refreshState];
    return self;
}
- (NSString *)pressureText:(CPUthermalPressureLevel)level {
    switch(level){case CPUthermalPressureLevelNominal:return S("正常");case CPUthermalPressureLevelLight:return S("轻微");case CPUthermalPressureLevelModerate:return S("中等");case CPUthermalPressureLevelHeavy:return S("严重");case CPUthermalPressureLevelTrapping:return S("临界");case CPUthermalPressureLevelSleeping:return S("休眠");default:return S("未知");}
}
- (void)refreshState {
    CPUthermalPressureLevel pressure=CPUthermalGetPressureLevel();
    _pressureSubtitle.text=[NSString stringWithFormat:S("%@（%ld）"),[self pressureText:pressure],(long)pressure];
    NSInteger active=0;if(pressure==CPUthermalPressureLevelLight)active=1;else if(pressure==CPUthermalPressureLevelModerate)active=2;else if(pressure==CPUthermalPressureLevelHeavy)active=3;else if(pressure>=CPUthermalPressureLevelTrapping&&pressure<CPUthermalPressureLevelUnknown)active=4;
    for(NSUInteger i=0;i<_segments.arrangedSubviews.count;i++)_segments.arrangedSubviews[i].alpha=(i<=active)?1.0:.34;
    int notif=CPUthermalGetCurrentNotifLevel();
    _notificationValue.text=(notif<0)?S("未知"):[NSString stringWithFormat:S("%@（%d）"),notif==0?S("正常"):S("等级"),notif];
}
- (void)resetTapped {
    NSString *tool=CPUthermalToolPath();if(!tool.length)return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{pid_t pid=0;char*args[]={(char*)"CPUthermalTool",(char*)"thermal-reset",NULL};if(posix_spawn(&pid,tool.fileSystemRepresentation,NULL,NULL,args,NULL)==0)waitpid(pid,NULL,0);dispatch_async(dispatch_get_main_queue(),^{[self refreshState];});});
}
- (void)dealloc {
    if(_pressureToken>0)notify_cancel(_pressureToken);
    if(_notificationToken>0)notify_cancel(_notificationToken);
}
- (void)layoutSubviews {
    [super layoutSubviews];CGRect b=self.contentView.bounds;CGFloat w=CGRectGetWidth(b);CGFloat pad=16;
    _pressureTitle.frame=CGRectMake(pad,12,w*.45,24);_pressureSubtitle.frame=CGRectMake(pad,38,w*.45,19);_segments.frame=CGRectMake(w-150,22,132,28);
    UIView *line=[self.contentView viewWithTag:6262];if(!line){line=[UIView new];line.tag=6262;line.backgroundColor=[UIColor separatorColor];[self.contentView addSubview:line];}line.frame=CGRectMake(pad,70,w-pad,0.5);
    _notificationTitle.frame=CGRectMake(pad,82,90,34);_resetButton.frame=CGRectMake(w-88,81,70,38);_notificationValue.frame=CGRectMake(100,82,w-200,34);
}
@end

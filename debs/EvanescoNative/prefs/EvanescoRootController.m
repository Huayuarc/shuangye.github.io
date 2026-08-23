#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
@interface CPEvanescoStepperCell:PSTableCell
@property(nonatomic,strong)UIStepper *stepper; @property(nonatomic,strong)UILabel *valueLabel;
@end
@implementation CPEvanescoStepperCell
-(instancetype)initWithStyle:(NSInteger)style reuseIdentifier:(NSString*)reuse specifier:(PSSpecifier*)sp{if((self=[super initWithStyle:style reuseIdentifier:reuse specifier:sp])){self.textLabel.text=sp.name;_stepper=[UIStepper new];_stepper.minimumValue=[[sp propertyForKey:@"min"]doubleValue];_stepper.maximumValue=[[sp propertyForKey:@"max"]doubleValue];_stepper.stepValue=1;[_stepper addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];_valueLabel=[UILabel new];_valueLabel.textAlignment=NSTextAlignmentRight;self.accessoryView=_stepper;[self.contentView addSubview:_valueLabel];}return self;}
-(void)layoutSubviews{[super layoutSubviews];_valueLabel.frame=CGRectMake(self.contentView.bounds.size.width-155,0,45,self.contentView.bounds.size.height);id v=[self.specifier performGetter];_stepper.value=[v doubleValue];_valueLabel.text=[NSString stringWithFormat:@"%.0f",_stepper.value];}
-(void)changed:(UIStepper*)s{[self.specifier performSetterWithValue:@(s.value)];_valueLabel.text=[NSString stringWithFormat:@"%.0f",s.value];}
@end
#import "../EvanescoPrefs.h"
@interface CPEvanescoRootListController:PSListController@end
@implementation CPEvanescoRootListController
-(NSArray*)specifiers{if(!_specifiers){NSMutableArray*a=[NSMutableArray array];PSSpecifier*s;
s=[PSSpecifier groupSpecifierWithName:nil];[a addObject:s];
s=[PSSpecifier preferenceSpecifierNamed:@"Enabled" target:self set:@selector(set:spec:) get:@selector(get:) detail:Nil cell:PSSwitchCell edit:Nil];[s setProperty:@"enabled" forKey:@"key"];[s setProperty:@YES forKey:@"default"];[s setProperty:@"No Respring Required" forKey:@"cellSubtitleText"];[a addObject:s];
s=[PSSpecifier groupSpecifierWithName:nil];[a addObject:s];
for(NSArray*x in @[@[@"Hide Dock",@"hideDock"],@[@"Hide Status Bar",@"hideStatusBar"]]){s=[PSSpecifier preferenceSpecifierNamed:x[0] target:self set:@selector(set:spec:) get:@selector(get:) detail:Nil cell:PSSwitchCell edit:Nil];[s setProperty:x[1] forKey:@"key"];[s setProperty:@YES forKey:@"default"];[a addObject:s];}
s=[PSSpecifier groupSpecifierWithName:@"ICON FADE ALPHA"];[a addObject:s];
s=[PSSpecifier preferenceSpecifierNamed:nil target:self set:@selector(set:spec:) get:@selector(get:) detail:Nil cell:PSSliderCell edit:Nil];[s setProperty:@"alpha" forKey:@"key"];[s setProperty:@0.0 forKey:@"default"];[s setProperty:@0.0 forKey:@"min"];[s setProperty:@1.0 forKey:@"max"];[s setProperty:@YES forKey:@"showValue"];[a addObject:s];
s=[PSSpecifier groupSpecifierWithName:nil];[a addObject:s];
s=[PSSpecifier preferenceSpecifierNamed:@"Time Delay" target:self set:@selector(set:spec:) get:@selector(get:) detail:Nil cell:PSLinkCell edit:Nil];[s setProperty:CPEvanescoStepperCell.class forKey:@"cellClass"];[s setProperty:@"timeDelay" forKey:@"key"];[s setProperty:@6 forKey:@"default"];[s setProperty:@1 forKey:@"min"];[s setProperty:@120 forKey:@"max"];[s setProperty:@1 forKey:@"step"];[a addObject:s];
s=[PSSpecifier groupSpecifierWithName:nil];[s setProperty:@"Evanesco! 2024.05.26\nCopyright © 2021 CP Digital Darkroom\nUpdated by: Randy420" forKey:@"footerText"];[s setProperty:@1 forKey:@"footerAlignment"];[a addObject:s];_specifiers=[a copy];}return _specifiers;}
-(id)get:(PSSpecifier*)s{return EVRead([s propertyForKey:@"key"],[s propertyForKey:@"default"]);}
-(void)set:(id)v spec:(PSSpecifier*)s{EVWrite([s propertyForKey:@"key"],v);}
@end

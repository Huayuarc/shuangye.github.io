#pragma once
#import <Foundation/Foundation.h>
typedef NSInteger PSCellType;
enum { PSGroupCell=0, PSLinkCell=1, PSLinkListCell=2, PSSwitchCell=6, PSEditTextCell=8, PSSegmentCell=9, PSButtonCell=13 };
@interface PSSpecifier : NSObject
@property(nonatomic,copy) NSString *name;
@property(nonatomic,retain) id target;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)setter get:(SEL)getter detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

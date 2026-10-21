#!/usr/bin/env python3
"""Run the production method-hook code using GNU ObjC and a small UIView mock.
This tests call chains and scoping, NOT UIKit, Apple PAC, or device injection.
"""
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
source = (root/'HideNCHeaders.m').read_text()
source = '\n'.join(line for line in source.splitlines() if not line.startswith('#import'))
source = source.split('static void HNCAttempt(')[0]
source = source.replace('#include "HNCSpacing.h"', (root/'HNCSpacing.h').read_text())
source = source.replace('#include "HNCViewFallback.h"', (root/'HNCViewFallback.h').read_text())
source = source.replace('#include "HNCFooterControls.h"', (root/'HNCFooterControls.h').read_text())
source = source.replace('#include "HNCFooterSpacing.h"', (root/'HNCFooterSpacing.h').read_text())
prelude = r'''
#include <objc/objc.h>
#include <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define BOOL _Bool
#undef YES
#undef NO
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#define NSLog(...) ((void)0)
typedef double CGFloat;
typedef struct CGPoint { double x, y; } CGPoint;
typedef struct CGSize { double width, height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;
static unsigned tests;
#define CHECK(...) do { assert((__VA_ARGS__)); ++tests; } while(0)
__attribute__((objc_root_class))
@interface TestRoot { Class isa; }
+ (id)alloc;
+ (Class)class;
+ (BOOL)isSubclassOfClass:(Class)c;
- (id)init;
@end
@implementation TestRoot
+ (id)alloc { return class_createInstance(self,0); }
+ (Class)class { return self; }
+ (BOOL)isSubclassOfClass:(Class)c { for(Class p=self;p;p=class_getSuperclass(p)) if(p==c)return YES;return NO; }
- (id)init { return self; }
@end
@interface UIView : TestRoot {
@public BOOL _hidden, _interaction, _a11yHidden, _a11yElement;
double _alpha;
CGRect _frame, _bounds;
unsigned _layouts, _windows, _supers, _hiddenCalls, _alphaCalls;
unsigned _frameCalls, _boundsCalls, _fitCalls;
}
@property BOOL hidden;
@property double alpha;
@property BOOL userInteractionEnabled;
@property BOOL accessibilityElementsHidden;
@property BOOL isAccessibilityElement;
@property CGRect frame;
@property CGRect bounds;
- (CGSize)sizeThatFits:(CGSize)size;
- (CGSize)intrinsicContentSize;
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size;
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size withHorizontalFittingPriority:(float)x verticalFittingPriority:(float)y;
- (void)layoutSubviews;
- (void)didMoveToWindow;
- (void)didMoveToSuperview;
@end
@implementation UIView
- (id)init { self=[super init];_alpha=1;_interaction=YES;_frame=(CGRect){{5,7},{365,62}};_bounds=(CGRect){{0,0},{365,62}};return self; }
- (CGRect)frame{return _frame;}
- (void)setFrame:(CGRect)v{_frame=v;_frameCalls++;_bounds.size=v.size;}
- (CGRect)bounds{return _bounds;}
- (void)setBounds:(CGRect)v{_bounds=v;_boundsCalls++;_frame.size=v.size;}
- (CGSize)sizeThatFits:(CGSize)s{_fitCalls++;return (CGSize){s.width,62};}
- (CGSize)intrinsicContentSize{return (CGSize){-1,62};}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)s{_fitCalls++;return (CGSize){s.width,62};}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)s withHorizontalFittingPriority:(float)x verticalFittingPriority:(float)y{_fitCalls++;return (CGSize){s.width,62};}
- (BOOL)hidden{return _hidden;}
- (void)setHidden:(BOOL)v{_hidden=v;_hiddenCalls++;}
- (double)alpha{return _alpha;}
- (void)setAlpha:(double)v{_alpha=v;_alphaCalls++;}
- (BOOL)userInteractionEnabled{return _interaction;}
- (void)setUserInteractionEnabled:(BOOL)v{_interaction=v;}
- (BOOL)accessibilityElementsHidden{return _a11yHidden;}
- (void)setAccessibilityElementsHidden:(BOOL)v{_a11yHidden=v;}
- (BOOL)isAccessibilityElement{return _a11yElement;}
- (void)setIsAccessibilityElement:(BOOL)v{_a11yElement=v;}
- (void)layoutSubviews{_layouts++;}
- (void)didMoveToWindow{_windows++;}
- (void)didMoveToSuperview{_supers++;}
@end
@interface NCNotificationListSectionHeaderView : UIView
+ (double)headerHeightWithWidth:(double)w title:(id)t isShowingCollapseButton:(BOOL)c;
@end
@implementation NCNotificationListSectionHeaderView
+ (double)headerHeightWithWidth:(double)w title:(id)t isShowingCollapseButton:(BOOL)c{return 44;}
- (void)layoutSubviews{_layouts+=10;}
@end
@interface NCNotificationListCoalescingHeaderCell : UIView
+ (double)coalescingHeaderCellHeightForWidth:(double)w title:(id)t;
@end
@implementation NCNotificationListCoalescingHeaderCell
+ (double)coalescingHeaderCellHeightForWidth:(double)w title:(id)t{return 48;}
- (void)layoutSubviews{_layouts+=100;}
@end
@interface MockDerivedHeader : NCNotificationListCoalescingHeaderCell @end
@implementation MockDerivedHeader @end
@interface NCNotificationListCell : UIView @end
@implementation NCNotificationListCell @end
'''
prelude += r'''
@interface NCNotificationListView : UIView {
@public id _headerView, _dataSource, _footerView;
    double _nativeHeaderHeight, _nativeFooterHeight, _footerViewVerticalMargin;
    unsigned _measurements, _footerMeasurements, _marginReads;
}
@property id headerView;
@property id dataSource;
@property id footerView;
@property double footerViewVerticalMargin;
- (double)_headerViewHeight;
- (double)_footerViewHeight;
- (double)mockThreeCardHeight;
- (double)mockTotalHeight;
@end
@implementation NCNotificationListView
@synthesize headerView=_headerView, dataSource=_dataSource, footerView=_footerView;
- (double)footerViewVerticalMargin{_marginReads++;return _footerViewVerticalMargin;}
- (void)setFooterViewVerticalMargin:(double)v{_footerViewVerticalMargin=v;}
- (double)_footerViewHeight{_footerMeasurements++;return _nativeFooterHeight;}
- (double)mockTotalHeight{return [self mockThreeCardHeight] + [self _footerViewHeight] + [self footerViewVerticalMargin];}
- (double)_headerViewHeight{_measurements++;return _nativeHeaderHeight;}
- (double)mockThreeCardHeight{return [self _headerViewHeight] + 3*62.0 + 2*8.0;}
@end
@interface NCNotificationListPresentableGroup : TestRoot {
@public id _headerView, _groupListView, _footerView;
    double _headerViewHeight, _footerViewHeight;
    unsigned _sourceCalls, _getCalls, _setCalls, _footerSourceCalls, _footerGetCalls, _footerSetCalls;
}
@property id headerView;
@property id groupListView;
@property double headerViewHeight;
@property id footerView;
@property double footerViewHeight;
- (double)headerViewHeightForNotificationList:(id)list withWidth:(double)width;
- (double)footerViewHeightForNotificationList:(id)list withWidth:(double)width;
@end
@implementation NCNotificationListPresentableGroup
@synthesize headerView=_headerView, groupListView=_groupListView, footerView=_footerView;
- (double)footerViewHeight{return _footerGetCalls++,_footerViewHeight;}
- (void)setFooterViewHeight:(double)v{_footerSetCalls++;_footerViewHeight=v;}
- (double)footerViewHeightForNotificationList:(id)list withWidth:(double)width{_footerSourceCalls++;return _footerViewHeight;}
- (double)headerViewHeight{return _getCalls++,_headerViewHeight;}
- (void)setHeaderViewHeight:(double)v{_setCalls++;_headerViewHeight=v;}
- (double)headerViewHeightForNotificationList:(id)list withWidth:(double)width{
    _sourceCalls++; return _headerViewHeight;
}
@end
@interface NCNotificationGroupList : NCNotificationListPresentableGroup @end
@implementation NCNotificationGroupList @end
@interface NCNotificationStructuredSectionList : TestRoot {
@public id _headerView, _sectionListView;
    double _headerViewHeight;
    unsigned _sourceCalls, _getCalls, _setCalls;
}
@property id headerView;
@property id sectionListView;
@property double headerViewHeight;
- (double)headerViewHeightForNotificationList:(id)list withWidth:(double)width;
@end
@implementation NCNotificationStructuredSectionList
@synthesize headerView=_headerView, sectionListView=_sectionListView;
- (double)headerViewHeight{return _getCalls++,_headerViewHeight;}
- (void)setHeaderViewHeight:(double)v{_setCalls++;_headerViewHeight=v;}
- (double)headerViewHeightForNotificationList:(id)list withWidth:(double)width{
    _sourceCalls++; return _headerViewHeight;
}
@end
@interface NCNotificationAppSectionListHeaderView : UIView @end
@implementation NCNotificationAppSectionListHeaderView @end
'''
prelude += r'''
@interface NCNotificationListCoalescingControlsCell : UIView
+ (double)coalescingControlsCellHeightShowingCoalescingControls:(BOOL)show;
@end
@implementation NCNotificationListCoalescingControlsCell
+ (double)coalescingControlsCellHeightShowingCoalescingControls:(BOOL)show{return show?48:8;}
- (void)layoutSubviews{_layouts+=1000;}
@end
@interface NCNotificationListCoalescingControlsView : UIView
+ (double)preferredHeight;
@end
@implementation NCNotificationListCoalescingControlsView
+ (double)preferredHeight{return 44;}
- (void)layoutSubviews{_layouts+=10000;}
@end
@interface MockDerivedControls : NCNotificationListCoalescingControlsView @end
@implementation MockDerivedControls @end
@interface MockSummaryFooter : UIView @end
@implementation MockSummaryFooter @end
'''
tests = r'''
int main(void) {
    Class legacy=[NCNotificationListSectionHeaderView class];
    Class modern=[NCNotificationListCoalescingHeaderCell class];
    IMP baseHidden=method_getImplementation(class_getInstanceMethod([UIView class],@selector(setHidden:)));
    IMP baseLayout=method_getImplementation(class_getInstanceMethod([UIView class],@selector(layoutSubviews)));
    Method boolMethod=class_getInstanceMethod(legacy,@selector(setHidden:));
    printf("Mock BOOL signature: %s (return %s; self %s; cmd %s; arg %s)\n",method_getTypeEncoding(boolMethod),method_copyReturnType(boolMethod),method_copyArgumentType(boolMethod,0),method_copyArgumentType(boolMethod,1),method_copyArgumentType(boolMethod,2));fflush(stdout);
    CHECK(!HNCValid(NULL,'v',""));
    CHECK(HNCValid(class_getInstanceMethod(legacy,@selector(setHidden:)),'v',"B"));
    CHECK(!HNCValid(class_getInstanceMethod(legacy,@selector(setHidden:)),'v',"d"));
    CHECK(!HNCValid(class_getInstanceMethod(legacy,@selector(setAlpha:)),'d',"d"));
    CHECK(!HNCReplace(legacy,sel_registerName("doesNotExist:"),(IMP)HNCSetHidden,NULL,'v',"B"));
    CHECK([NCNotificationListSectionHeaderView headerHeightWithWidth:400 title:nil isShowingCollapseButton:YES]==44);
    CHECK([NCNotificationListCoalescingHeaderCell coalescingHeaderCellHeightForWidth:400 title:nil]==48);
    Method heightMethod=class_getClassMethod(legacy,sel_registerName("headerHeightWithWidth:title:isShowingCollapseButton:"));
    printf("Mock height signature: %s; self %s; return %s\n",method_getTypeEncoding(heightMethod),method_copyArgumentType(heightMethod,0),method_copyReturnType(heightMethod));fflush(stdout);
    CHECK(HNCInstallCoalescing());
    CHECK(HNCInstallLegacy());
    IMP savedLegacy=HNCOrigSetHidden, savedModern=HNCCoalescingOrigSetHidden;
    CHECK(HNCInstallCoalescing() && HNCInstallLegacy());
    CHECK(HNCOrigSetHidden==savedLegacy && HNCCoalescingOrigSetHidden==savedModern);
    CHECK(method_getImplementation(class_getInstanceMethod([UIView class],@selector(setHidden:)))==baseHidden);
    CHECK(method_getImplementation(class_getInstanceMethod([UIView class],@selector(layoutSubviews)))==baseLayout);
    Method afterHeight=class_getInstanceMethod(object_getClass(legacy),sel_registerName("headerHeightWithWidth:title:isShowingCollapseButton:"));
    printf("height valid=%d hook=%p actual=%p value=%g\n",HNCValid(afterHeight,'d',"d@B"),(void*)HNCHeight,(void*)method_getImplementation(afterHeight),[NCNotificationListSectionHeaderView headerHeightWithWidth:400 title:nil isShowingCollapseButton:NO]);fflush(stdout);
    CHECK([NCNotificationListSectionHeaderView headerHeightWithWidth:400 title:nil isShowingCollapseButton:NO]==0);
    CHECK([NCNotificationListCoalescingHeaderCell coalescingHeaderCellHeightForWidth:400 title:nil]==0);
    UIView *old=[[NCNotificationListSectionHeaderView alloc]init];
    UIView *current=[[NCNotificationListCoalescingHeaderCell alloc]init];
    UIView *derived=[[MockDerivedHeader alloc]init];
    UIView *card=[[NCNotificationListCell alloc]init];
    UIView *plain=[[UIView alloc]init];
    UIView *headers[]={old,current,derived};
    for(unsigned i=0;i<3;i++) {
        UIView *v=headers[i];
        [v didMoveToSuperview];[v didMoveToWindow];
        CHECK(v.hidden && v.alpha==0 && !v.userInteractionEnabled);
        CHECK(v.accessibilityElementsHidden && !v.isAccessibilityElement);
        for(unsigned j=0;j<100;j++) { v.hidden=NO;v.alpha=1;[v layoutSubviews]; }
        CHECK(v.hidden && v.alpha==0);
        CHECK(v->_windows==1 && v->_supers==1);
        CHECK(v->_hiddenCalls==202 && v->_alphaCalls==202);
    }
    CHECK(old->_layouts==1000);
    CHECK(current->_layouts==10000);
    CHECK(derived->_layouts==10000);
    UIView *untouched[]={card,plain};
    for(unsigned i=0;i<2;i++) {
        UIView *v=untouched[i];v.hidden=NO;v.alpha=0.75;
        [v didMoveToWindow];[v layoutSubviews];
        CHECK(!v.hidden && v.alpha==0.75 && v.userInteractionEnabled);
        CHECK(!v.accessibilityElementsHidden);
        CHECK(v->_layouts==1 && v->_windows==1);
    }
    // Reject a mismatched height signature without changing its implementation.
    SEL h=sel_registerName("coalescingHeaderCellHeightForWidth:title:");
    IMP previous=method_getImplementation(class_getInstanceMethod(object_getClass(modern),h));
    CHECK(!HNCReplace(object_getClass(modern),h,(IMP)HNCHeight,NULL,'d',"d@B"));
    CHECK(method_getImplementation(class_getInstanceMethod(object_getClass(modern),h))==previous);
    // Gap regression: three existing cards retain their native heights and 8pt gaps.
    NCNotificationListView *groupView=[[NCNotificationListView alloc]init];
    NCNotificationGroupList *owner=[[NCNotificationGroupList alloc]init];
    groupView.headerView=current; groupView.dataSource=owner; groupView->_nativeHeaderHeight=60;
    owner.headerView=current;owner.groupListView=groupView;owner.headerViewHeight=60;
    CHECK([groupView mockThreeCardHeight]==262);
    CHECK([owner headerViewHeightForNotificationList:groupView withWidth:400]==60);
    CHECK(HNCInstallSpacing());
    IMP gapOriginal=HNCOrigListHeaderHeight, ownerOriginal=HNCGroupHeightHooks.dataSourceHeight;
    CHECK(HNCInstallSpacing());
    CHECK(HNCOrigListHeaderHeight==gapOriginal && HNCGroupHeightHooks.dataSourceHeight==ownerOriginal);
    CHECK([groupView _headerViewHeight]==0);
    CHECK([groupView mockThreeCardHeight]==202);
    CHECK([owner headerViewHeightForNotificationList:groupView withWidth:400]==0);
    CHECK(owner->_sourceCalls==2 && owner->_headerViewHeight==60);
    CHECK(owner.headerViewHeight==0 && owner->_getCalls==1);
    owner.headerViewHeight=75;
    CHECK(owner->_headerViewHeight==75 && owner->_setCalls==2);
    CHECK(owner.headerViewHeight==0);
    NCNotificationListView *unrelated=[[NCNotificationListView alloc]init];
    CHECK(!HNCHeaderIsSuppressed(nil) && !HNCHeaderIsSuppressed(card));
    CHECK([owner headerViewHeightForNotificationList:unrelated withWidth:400]==75);
    // Missing header and different header classes must keep all original spacing.
    NCNotificationAppSectionListHeaderView *other=[[NCNotificationAppSectionListHeaderView alloc]init];
    groupView.headerView=other; owner.headerView=other;
    CHECK([groupView _headerViewHeight]==60 && [groupView mockThreeCardHeight]==262);
    CHECK(owner.headerViewHeight==75);
    CHECK([owner headerViewHeightForNotificationList:groupView withWidth:400]==75);
    owner.headerViewHeight=45;
    CHECK(owner->_headerViewHeight==45);
    groupView.headerView=nil; owner.headerView=nil;
    CHECK([groupView _headerViewHeight]==60);
    CHECK([owner headerViewHeightForNotificationList:groupView withWidth:400]==45);
    CHECK(owner.headerViewHeight==45);
    // Provider can identify its own header before list has attached it; no new header made.
    owner.headerView=current;
    CHECK([groupView _headerViewHeight]==0);
    // List's existing header is enough even if the owner header hasn't been assigned yet.
    owner.headerView=nil; groupView.headerView=current;
    CHECK([owner headerViewHeightForNotificationList:groupView withWidth:400]==0);
    CHECK(groupView->_measurements==7);
    // Old-style section uses its own IMP slots and only its matching list.
    NCNotificationStructuredSectionList *section=[[NCNotificationStructuredSectionList alloc]init];
    NCNotificationListView *sectionView=[[NCNotificationListView alloc]init];
    section.headerView=old;section.sectionListView=sectionView;sectionView.headerView=old;
    sectionView.dataSource=section;sectionView->_nativeHeaderHeight=56;
    section->_headerViewHeight=56;
    CHECK([section headerViewHeightForNotificationList:sectionView withWidth:400]==0);
    CHECK([section headerViewHeightForNotificationList:groupView withWidth:400]==56);
    CHECK([sectionView _headerViewHeight]==0 && section.headerViewHeight==0);
    section.headerViewHeight=100;
    CHECK(section->_headerViewHeight==100 && section->_setCalls==1);
    section.headerView=other; sectionView.headerView=other;
    // No explicit remeasure/write after switching to a different header.
    CHECK([section headerViewHeightForNotificationList:sectionView withWidth:400]==100);
    CHECK(section.headerViewHeight==100 && [sectionView _headerViewHeight]==56);
    CHECK(section->_sourceCalls==3 && section->_setCalls==1);
    CHECK(HNCLegacyViewHooks.installed && HNCCoalescingViewHooks.installed);
    for(unsigned i=0;i<3;i++) {
        UIView *v=headers[i];
        v.frame=(CGRect){{14,88},{365,60}};
        CHECK(v.frame.origin.x==14 && v.frame.origin.y==88);
        CHECK(v.frame.size.width==365 && v.frame.size.height==0);
        v.bounds=(CGRect){{0,0},{365,56}};
        CHECK(v.bounds.size.width==365 && v.bounds.size.height==0);
        CHECK([v sizeThatFits:(CGSize){365,100}].height==0);
        CHECK([v sizeThatFits:(CGSize){400,100}].width==400);
        CHECK([v intrinsicContentSize].height==0 && [v intrinsicContentSize].width==-1);
        CHECK([v systemLayoutSizeFittingSize:(CGSize){320,100}].height==0);
        CHECK([v systemLayoutSizeFittingSize:(CGSize){320,100} withHorizontalFittingPriority:1000 verticalFittingPriority:50].height==0);
        CHECK(v->_fitCalls==4);
        // Bypass the setters to simulate a stale pre-existing frame, then run lifecycle fallback.
        v->_bounds.size.height=60;v->_frame.size.height=60;
        [v layoutSubviews];
        CHECK(v.bounds.size.height==0 && v.frame.size.height==0);
    }
    UIView *notHeaders[]={card,plain,groupView,sectionView};
    for(unsigned i=0;i<4;i++) {
        UIView *v=notHeaders[i];v.frame=(CGRect){{14,88},{365,490}};
        v.bounds=(CGRect){{0,0},{365,490}};
        CHECK(v.frame.size.height==490 && v.bounds.size.height==490);
        CHECK([v sizeThatFits:(CGSize){365,490}].height==62);
        CHECK([v intrinsicContentSize].height==62);
        CHECK([v systemLayoutSizeFittingSize:(CGSize){365,490}].height==62);
    }
    // 1.0.4: footer controls use their OWN visibility/geometry/original method slots.
    CHECK([NCNotificationListCoalescingControlsCell coalescingControlsCellHeightShowingCoalescingControls:YES]==48);
    CHECK([NCNotificationListCoalescingControlsView preferredHeight]==44);
    CHECK(HNCInstallFooterCell());
    CHECK(HNCInstallStandaloneControls());
    IMP footerHidden=HNCFooterCellControls.hidden, controlHidden=HNCStandaloneControls.hidden;
    IMP footerGeometry=HNCFooterCellViewHooks.frameSetter;
    CHECK(HNCInstallFooterCell() && HNCInstallStandaloneControls());
    CHECK(footerHidden==HNCFooterCellControls.hidden && controlHidden==HNCStandaloneControls.hidden);
    CHECK(footerGeometry==HNCFooterCellViewHooks.frameSetter);
    CHECK([NCNotificationListCoalescingControlsCell coalescingControlsCellHeightShowingCoalescingControls:YES]==0);
    CHECK([NCNotificationListCoalescingControlsCell coalescingControlsCellHeightShowingCoalescingControls:NO]==0);
    CHECK([NCNotificationListCoalescingControlsView preferredHeight]==0);
    UIView *footerCell=[[NCNotificationListCoalescingControlsCell alloc]init];
    UIView *footerControls=[[NCNotificationListCoalescingControlsView alloc]init];
    UIView *derivedControls=[[MockDerivedControls alloc]init];
    UIView *bottoms[]={footerCell,footerControls,derivedControls};
    CHECK(HNCFooterCellViewHooks.installed && HNCControlsViewHooks.installed);
    for(unsigned i=0;i<3;i++) {
        UIView *v=bottoms[i];
        [v didMoveToSuperview];[v didMoveToWindow];
        for(unsigned j=0;j<100;j++){v.hidden=NO;v.alpha=1;[v layoutSubviews];}
        CHECK(v.hidden && v.alpha==0 && !v.userInteractionEnabled);
        CHECK(v.accessibilityElementsHidden && !v.isAccessibilityElement);
        CHECK(v->_windows==1 && v->_supers==1);
        CHECK(v->_hiddenCalls==202 && v->_alphaCalls==202);
        v.frame=(CGRect){{14,88},{365,48}};
        CHECK(v.frame.origin.x==14 && v.frame.origin.y==88 && v.frame.size.width==365 && v.frame.size.height==0);
        v.bounds=(CGRect){{0,0},{365,48}};
        CHECK(v.bounds.size.width==365 && v.bounds.size.height==0);
        CHECK([v sizeThatFits:(CGSize){365,80}].height==0 && [v sizeThatFits:(CGSize){365,80}].width==365);
        CHECK([v intrinsicContentSize].height==0 && [v intrinsicContentSize].width==-1);
        CHECK([v systemLayoutSizeFittingSize:(CGSize){365,80}].height==0);
        CHECK([v systemLayoutSizeFittingSize:(CGSize){365,80} withHorizontalFittingPriority:1000 verticalFittingPriority:50].height==0);
        v->_frame.size.height=48;v->_bounds.size.height=48;[v didMoveToWindow];
        CHECK(v.bounds.size.height==0 && v.frame.size.height==0);
    }
    CHECK(footerCell->_layouts==100000 && footerControls->_layouts==1000000 && derivedControls->_layouts==1000000);
    CHECK(method_getImplementation(class_getInstanceMethod([UIView class],@selector(setHidden:)))==baseHidden);
    CHECK(method_getImplementation(class_getInstanceMethod([UIView class],@selector(layoutSubviews)))==baseLayout);
    NCNotificationListView *footerList=[[NCNotificationListView alloc]init];
    NCNotificationGroupList *footerOwner=[[NCNotificationGroupList alloc]init];
    footerList.footerView=footerCell;footerList.dataSource=footerOwner;
    footerList->_nativeFooterHeight=48;footerList.footerViewVerticalMargin=12;
    footerOwner.footerView=footerCell;footerOwner.groupListView=footerList;footerOwner.footerViewHeight=48;
    CHECK([footerList mockTotalHeight]==262);
    CHECK(HNCInstallFooterSpacing());
    IMP footerSource=HNCOrigGroupFooterHeight, footerMeasure=HNCOrigListFooterHeight;
    CHECK(HNCInstallFooterSpacing());
    CHECK(footerSource==HNCOrigGroupFooterHeight && footerMeasure==HNCOrigListFooterHeight);
    CHECK([footerList mockTotalHeight]==202);
    CHECK([footerList _footerViewHeight]==0 && footerList.footerViewVerticalMargin==0);
    CHECK([footerOwner footerViewHeightForNotificationList:footerList withWidth:365]==0);
    CHECK(footerOwner.footerViewHeight==0 && footerOwner->_footerViewHeight==48);
    footerOwner.footerViewHeight=72;footerList.footerViewVerticalMargin=15;
    CHECK(footerOwner->_footerViewHeight==72 && footerOwner.footerViewHeight==0);
    CHECK(footerList->_footerViewVerticalMargin==15 && footerList.footerViewVerticalMargin==0);
    CHECK([footerOwner footerViewHeightForNotificationList:unrelated withWidth:365]==72);
    CHECK(!HNCFooterIsSuppressed(nil) && !HNCFooterIsSuppressed(card) && !HNCFooterIsSuppressed(current));
    // No header or footer factory calls: use existing provider/list objects only.
    footerList.footerView=nil;
    CHECK([footerList _footerViewHeight]==0 && footerList.footerViewVerticalMargin==0);
    footerOwner.footerView=nil;footerList.footerView=footerControls;
    CHECK([footerOwner footerViewHeightForNotificationList:footerList withWidth:365]==0);
    CHECK([footerList _footerViewHeight]==0);
    // Switching to an unrelated summary footer restores original values WITHOUT rewriting caches.
    UIView *summary=[[MockSummaryFooter alloc]init];
    footerList.footerView=summary;footerOwner.footerView=summary;
    CHECK([footerList _footerViewHeight]==48 && footerList.footerViewVerticalMargin==15);
    CHECK(footerOwner.footerViewHeight==72);
    CHECK([footerOwner footerViewHeightForNotificationList:footerList withWidth:365]==72);
    CHECK([footerList mockTotalHeight]==265);
    footerList.footerView=nil;footerOwner.footerView=nil;
    CHECK([footerList _footerViewHeight]==48 && footerList.footerViewVerticalMargin==15);
    CHECK(footerOwner.footerViewHeight==72 && footerOwner->_footerSetCalls==2);
    CHECK(footerList->_footerMeasurements==8 && footerList->_marginReads==8);
    // A stale suppressed owner must not override a real non-target footer on the list.
    footerOwner.footerView=footerCell;footerList.footerView=summary;
    CHECK([footerList _footerViewHeight]==48 && footerList.footerViewVerticalMargin==15);
    CHECK([footerOwner footerViewHeightForNotificationList:footerList withWidth:365]==72);
    CHECK(footerOwner.footerViewHeight==72);
    footerOwner.footerView=summary;footerList.footerView=footerCell;
    CHECK([footerList _footerViewHeight]==0 && footerList.footerViewVerticalMargin==0);
    CHECK([footerOwner footerViewHeightForNotificationList:footerList withWidth:365]==0);
    CHECK(footerOwner.footerViewHeight==0 && footerOwner->_footerViewHeight==72);
    CHECK(HNCFooterCellControls.complete && HNCStandaloneControls.complete);
    CHECK(HNCFooterCellViewHooks.complete && HNCControlsViewHooks.complete);
    // Whole lists/cards/summary still measure and receive real geometry.
    UIView *footerNegatives[]={card,footerList,summary};
    for(unsigned i=0;i<3;i++) {
        UIView *v=footerNegatives[i];v.frame=(CGRect){{14,88},{365,490}};v.bounds=(CGRect){{0,0},{365,490}};
        v.hidden=NO;v.alpha=1;[v layoutSubviews];
        CHECK(v.frame.size.height==490 && v.bounds.size.height==490 && !v.hidden && v.alpha==1);
        CHECK([v sizeThatFits:(CGSize){365,490}].height==62);
    }
    CHECK(HNCOrigSetHidden==savedLegacy && HNCCoalescingOrigSetHidden==savedModern);
    CHECK([NCNotificationListSectionHeaderView headerHeightWithWidth:365 title:nil isShowingCollapseButton:YES]==0);
    CHECK([NCNotificationListCoalescingHeaderCell coalescingHeaderCellHeightForWidth:365 title:nil]==0);
    printf("RUNTIME MOCK PASS: %u assertions; 600 visibility/layout cycles; header/footer occupancy and view-fallback passed; card/list geometry and raw caches unchanged\n",tests);
    return 0;
}
'''
build=root/'build';build.mkdir(exist_ok=True)
path=build/'runtime_mock.m'; path.write_text(prelude+'\n'+source+'\n'+tests)
includes=subprocess.check_output(['gcc','-print-file-name=include'],text=True).strip()
subprocess.run(['clang','-x','objective-c','-fobjc-runtime=gcc','-I'+includes,'-Wno-objc-property-no-attribute','-Wno-unused-parameter',str(path),'-lobjc','-o',str(build/'runtime_mock')],check=True)
subprocess.run(['/lib/ld-musl-aarch64.so.1',str(build/'runtime_mock')],check=True)

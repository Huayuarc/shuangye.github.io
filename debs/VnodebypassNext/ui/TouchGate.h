#ifndef VB_TOUCH_GATE_H
#define VB_TOUCH_GATE_H
#import <UIKit/UIKit.h>
// sendActionsForControlEvents: and system state setters have no UITouch.
// Only a real, completed touch inside this control reaches a write-capable UI.
static inline BOOL VBRealTouch(UIControl *control, UIEvent *event) {
    if (!control || !event || event.type != UIEventTypeTouches) return NO;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseEnded) continue;
        UIView *view = touch.view;
        if (view != control && ![view isDescendantOfView:control]) continue;
        if ([control pointInside:[touch locationInView:control] withEvent:event]) return YES;
    }
    return NO;
}
#endif

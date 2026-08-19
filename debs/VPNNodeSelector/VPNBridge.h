#import <Foundation/Foundation.h>

BOOL VPNLegacyIsActive(void);
BOOL VPNLegacySetActive(BOOL active);
BOOL VPNLegacyToggle(void);
NSArray<NSDictionary *> *VPNLegacyCopyNodes(void);
BOOL VPNLegacySelectNode(id serviceID, NSUInteger grade);

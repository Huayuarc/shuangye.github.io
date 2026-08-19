#import <Foundation/Foundation.h>

BOOL VPNLegacyIsActive(void);
BOOL VPNLegacySetActive(BOOL active);
BOOL VPNLegacyToggle(void);
NSArray<NSDictionary *> *VPNLegacyCopyNodes(void);
BOOL VPNLegacySelectNode(NSString *serviceID, NSUInteger grade);

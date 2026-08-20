#import <Foundation/Foundation.h>

BOOL VPNLegacyIsActive(void);
BOOL VPNLegacySetActive(BOOL active);
BOOL VPNLegacyToggle(void);
id VPNSafeCurrentIdentifierForGrade(NSInteger grade);
BOOL VPNSafeSetCurrentIdentifier(id identifier, NSInteger grade);

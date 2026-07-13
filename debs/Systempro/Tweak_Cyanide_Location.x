// Tweak_Cyanide_Location.x
// Ported from Cyanide location_sim - GPS location simulation via CLLocationManager

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

static BOOL g_cld_locationEnabled = NO;
static double g_cld_latitude = 0;
static double g_cld_longitude = 0;

%group LocationHooks

%hook CLLocationManager

- (void)startUpdatingLocation {
    if (!g_cld_locationEnabled) {
        %orig;
        return;
    }
    
    // Intercept: create simulated location and feed to delegate
    CLLocation *simLocation = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(g_cld_latitude, g_cld_longitude)
                                                            altitude:0
                                                  horizontalAccuracy:50
                                                    verticalAccuracy:50
                                                              course:0
                                                               speed:0
                                                           timestamp:[NSDate date]];
    
    id delegate = [self delegate];
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:self didUpdateLocations:@[simLocation]];
    }
}

%end

%hook CLLocationManager

- (void)stopUpdatingLocation {
    %orig;
}

%end

%end // LocationHooks

static void cld_loadLocationPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_locationEnabled = [prefs[@"cld_locationEnabled"] boolValue];
    g_cld_latitude = [prefs[@"cld_locationLatitude"] doubleValue];
    g_cld_longitude = [prefs[@"cld_locationLongitude"] doubleValue];
    
    if (g_cld_latitude < -90) g_cld_latitude = -90;
    if (g_cld_latitude > 90) g_cld_latitude = 90;
    if (g_cld_longitude < -180) g_cld_longitude = -180;
    if (g_cld_longitude > 180) g_cld_longitude = 180;
    
    if (g_cld_locationEnabled) {
        %init(LocationHooks);
    }
}

__attribute__((constructor)) static void cld_Location_init(void) {
    cld_loadLocationPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadLocationPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

#import "PGSystemStatus.h"
#import <dlfcn.h>
#import <math.h>
#import <IOKit/IOKitLib.h>

static double PGNormalizeTemperature(double value) {
    if (value > 100000.0) value /= 1000.0;
    else if (value > 1000.0) value /= 100.0;
    else if (value > 200.0) value /= 10.0;
    return (value >= -20.0 && value <= 150.0) ? value : NAN;
}

static double PGNumberTemperature(CFTypeRef object) {
    if (!object) return NAN;
    double value = NAN;
    if (CFGetTypeID(object) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)object, kCFNumberDoubleType, &value);
    } else if (CFGetTypeID(object) == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)object;
        const UInt8 *bytes = CFDataGetBytePtr(data);
        CFIndex length = CFDataGetLength(data);
        if (length >= 4) { int32_t raw = 0; memcpy(&raw, bytes, 4); value = raw; }
        else if (length >= 2) { int16_t raw = 0; memcpy(&raw, bytes, 2); value = raw; }
    }
    return PGNormalizeTemperature(value);
}

double PGCurrentDeviceTemperature(void) {
    const char *services[] = {"AppleSmartBattery", "AppleARMPMUCharger", "ApplePMGR"};
    const CFStringRef keys[] = {CFSTR("Temperature"), CFSTR("BatteryTemperature"),
                                CFSTR("temperature"), CFSTR("DieTemp"), CFSTR("SkinTemperature")};
    for (NSUInteger i = 0; i < sizeof(services) / sizeof(services[0]); i++) {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(services[i]));
        if (!service) continue;
        for (NSUInteger j = 0; j < sizeof(keys) / sizeof(keys[0]); j++) {
            CFTypeRef object = IORegistryEntryCreateCFProperty(service, keys[j], kCFAllocatorDefault, 0);
            double value = PGNumberTemperature(object);
            if (object) CFRelease(object);
            if (isfinite(value)) { IOObjectRelease(service); return value; }
        }
        IOObjectRelease(service);
    }
    return NAN;
}

void PGSendMediaAction(PGMediaAction action) {
    static void *handle;
    static Boolean (*sendCommand)(unsigned int, id);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        sendCommand = handle ? (Boolean (*)(unsigned int, id))dlsym(handle, "MRMediaRemoteSendCommand") : NULL;
    });
    if (sendCommand) sendCommand((unsigned int)action, nil);
}

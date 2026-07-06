#import "CPUthermalSwiftBridge.h"
#import <CPUthermalPaths.h>

NSString *CPUthermalSwiftJBRootPathForRootFSPath(NSString *path) {
    if (path.length == 0) {
        return [NSString stringWithUTF8String:""];
    }
    NSString *resolved = CPUthermalJBRootPathForRootFSPath(path.fileSystemRepresentation);
    return resolved ?: [NSString stringWithUTF8String:""];
}

NSInteger CPUthermalSwiftNativeMaxPCoreFrequencyMHz(void) {
    return CPUthermalNativeMaxPCoreFrequencyMHz();
}

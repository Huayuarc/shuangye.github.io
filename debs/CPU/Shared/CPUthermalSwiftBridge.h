#import <Foundation/Foundation.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/sysctl.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

NS_ASSUME_NONNULL_BEGIN

NSString *CPUthermalSwiftJBRootPathForRootFSPath(NSString *path);
NSInteger CPUthermalSwiftNativeMaxPCoreFrequencyMHz(void);
NSDictionary *CPUthermalSwiftReadPrefs(void);

NS_ASSUME_NONNULL_END

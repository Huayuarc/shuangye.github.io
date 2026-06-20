#import <roothide.h>
#import <spawn.h>
#import <Foundation/Foundation.h>
#import "./PSSpecifier/PSSpecifier.h"

static NSString *_Nonnull rootlessPath(NSString* _Nonnull path) {
  return jbroot(path);
}

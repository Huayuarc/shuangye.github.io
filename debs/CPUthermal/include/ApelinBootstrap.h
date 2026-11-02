#pragma once
#import <Foundation/Foundation.h>
#import <dlfcn.h>
static inline NSString *ApelinBootstrapRoot(void) {
#ifdef APELIN_BOOTSTRAP_ROOTHIDE
 static NSString *root; static dispatch_once_t once; dispatch_once(&once, ^{ static const char anchor=0; Dl_info info; if(dladdr(&anchor,&info)&&info.dli_fname){ NSArray *parts=[@(info.dli_fname) componentsSeparatedByString:@"/"]; for(NSUInteger i=0;i<parts.count;i++){ if([parts[i] hasPrefix:@".jbroot-"]){ root=[[parts subarrayWithRange:NSMakeRange(0,i+1)] componentsJoinedByString:@"/"]; break; } } } }); return root;
#else
 return @"/var/jb";
#endif
}
static inline NSString *ApelinBootstrapPath(NSString *path) { NSString *root=ApelinBootstrapRoot(); return root ? [root stringByAppendingString:path] : nil; }

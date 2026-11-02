#pragma once
#import <Foundation/Foundation.h>
#import <dlfcn.h>
// isolation.42：本仓库的 Theos 构建只定义 THEOS_PACKAGE_SCHEME_ROOTHIDE（不定义
// APELIN_BOOTSTRAP_ROOTHIDE），此前 roothide 包因此走进了 rootless 分支，返回
// "/var/jb/…" —— 在 roothide 上并不存在，导致 Hello 120Hz 无法保存注入设置。
// 这里两种宏都认，同时 Makefile 也会显式补 -DAPELIN_BOOTSTRAP_ROOTHIDE=1 兜底。
static inline NSString *ApelinBootstrapRoot(void) {
#if defined(APELIN_BOOTSTRAP_ROOTHIDE) || defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
 static NSString *root; static dispatch_once_t once; dispatch_once(&once, ^{ static const char anchor=0; Dl_info info; if(dladdr(&anchor,&info)&&info.dli_fname){ NSArray *parts=[@(info.dli_fname) componentsSeparatedByString:@"/"]; for(NSUInteger i=0;i<parts.count;i++){ if([parts[i] hasPrefix:@".jbroot-"]){ root=[[parts subarrayWithRange:NSMakeRange(0,i+1)] componentsJoinedByString:@"/"]; break; } } } }); return root;
#else
 return @"/var/jb";
#endif
}
static inline NSString *ApelinBootstrapPath(NSString *path) { NSString *root=ApelinBootstrapRoot(); return root ? [root stringByAppendingString:path] : nil; }

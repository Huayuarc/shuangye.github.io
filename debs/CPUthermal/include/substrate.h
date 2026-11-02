#pragma once
#import <objc/runtime.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef const void *MSImageRef;
void MSHookMessageEx(Class, SEL, IMP, IMP *);
void MSHookFunction(void *, void *, void **);
MSImageRef MSGetImageByName(const char *);
void *MSFindSymbol(MSImageRef, const char *);
#ifdef __cplusplus
}
#endif

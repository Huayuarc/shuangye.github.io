#ifndef SJG_TEST_SYSCTL_H
#define SJG_TEST_SYSCTL_H
#include <stddef.h>
int sysctlbyname(const char *, void *, size_t *, void *, size_t);
#endif

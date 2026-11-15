// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// From Apelin's command-line template. The build defines APELIN_VERSION and
// APELIN_BUILD_ID as string literals on every compile. Exit codes follow
// sysexits(3): 0 on success, 64 for a usage error.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <sysexits.h>

static void PrintUsage(FILE *stream) {
    fprintf(stream, "usage: %s [--version] [--help] [name]\n", "{{productName}}");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *name = @"world";
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        for (NSUInteger index = 1; index < arguments.count; index++) {
            NSString *argument = arguments[index];
            if ([argument isEqualToString:@"--version"]) {
                printf("%s %s (%s)\n", "{{productName}}", APELIN_VERSION, APELIN_BUILD_ID);
                return EX_OK;
            }
            if ([argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]) {
                PrintUsage(stdout);
                return EX_OK;
            }
            if ([argument hasPrefix:@"-"]) {
                fprintf(stderr, "%s: unknown option %s\n", "{{productName}}", argument.UTF8String);
                PrintUsage(stderr);
                return EX_USAGE;
            }
            name = argument;
        }
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        printf("Hello, %s! This is iOS %ld.%ld.%ld.\n",
               name.UTF8String,
               (long)os.majorVersion,
               (long)os.minorVersion,
               (long)os.patchVersion);
        return EX_OK;
    }
}

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// From Apelin's command-line template. The build defines APELIN_VERSION and
// APELIN_BUILD_ID as string literals on every compile. Exit codes follow
// sysexits(3): 0 on success, 64 for a usage error.
#include <stdio.h>
#include <string.h>
#include <sysexits.h>

static void print_usage(FILE *stream) {
    fprintf(stream, "usage: %s [--version] [--help] [name]\n", "{{productName}}");
}

int main(int argc, char *argv[]) {
    const char *name = "world";
    for (int index = 1; index < argc; index++) {
        const char *argument = argv[index];
        if (strcmp(argument, "--version") == 0) {
            printf("%s %s (%s)\n", "{{productName}}", APELIN_VERSION, APELIN_BUILD_ID);
            return EX_OK;
        }
        if (strcmp(argument, "--help") == 0 || strcmp(argument, "-h") == 0) {
            print_usage(stdout);
            return EX_OK;
        }
        if (argument[0] == '-') {
            fprintf(stderr, "%s: unknown option %s\n", "{{productName}}", argument);
            print_usage(stderr);
            return EX_USAGE;
        }
        name = argument;
    }
    printf("Hello, %s!\n", name);
    return EX_OK;
}

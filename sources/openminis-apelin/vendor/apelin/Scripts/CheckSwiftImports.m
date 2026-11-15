#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <unistd.h>

// A research-only device helper. It inspects fixed Apple system-image
// install names through dyld, never loads the compiler or a supplied file.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        char *canonical = realpath(argv[1], NULL);
        if (!canonical) return 2;
        NSData *data = [NSData dataWithContentsOfFile:@(canonical)];
        free(canonical);
        if (!data) return 2;
        NSDictionary *input = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![input isKindOfClass:NSDictionary.class] || ![input[@"libraries"] isKindOfClass:NSArray.class]) return 2;
        NSSet *knownImages = [NSSet setWithArray:@[
            @"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            @"/usr/lib/libSystem.B.dylib", @"/usr/lib/libc++.1.dylib",
            @"/usr/lib/libncurses.5.4.dylib", @"/usr/lib/libobjc.A.dylib",
            @"/usr/lib/libresolv.9.dylib", @"/usr/lib/libz.1.dylib",
            @"/usr/lib/swift/libswiftCore.dylib", @"/usr/lib/swift/libswiftDarwin.dylib"
        ]];
        NSMutableArray *results = [NSMutableArray array];
        NSUInteger missingCount = 0;
        for (NSDictionary *library in input[@"libraries"]) {
            NSString *name = library[@"path"];
            NSArray *symbols = library[@"strong"];
            if (![name isKindOfClass:NSString.class] || ![symbols isKindOfClass:NSArray.class]) return 2;
            if (!symbols.count) continue; // optional images need not be present
            if (![knownImages containsObject:name]) return 2;
            void *image = dlopen(name.UTF8String, RTLD_LAZY | RTLD_LOCAL);
            NSMutableArray *missing = [NSMutableArray array];
            for (NSString *symbol in symbols) {
                if (![symbol isKindOfClass:NSString.class] || !symbol.length) return 2;
                NSString *lookup = [symbol hasPrefix:@"_"] ? [symbol substringFromIndex:1] : symbol;
                if ([lookup rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound) return 2;
                if (!image || !dlsym(image, lookup.UTF8String)) [missing addObject:symbol];
            }
            missingCount += missing.count;
            [results addObject:@{@"image": name, @"checked": @(symbols.count), @"missing": missing}];
            if (image) dlclose(image);
        }
        NSDictionary *output = @{
            @"host": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"uid": @(getuid()), @"missingCount": @(missingCount), @"libraries": results
        };
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:output
                                                          options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                            error:nil];
        if (!encoded) return 2;
        fwrite(encoded.bytes, 1, encoded.length, stdout);
        fputc('\n', stdout);
        return missingCount ? 1 : 0;
    }
}

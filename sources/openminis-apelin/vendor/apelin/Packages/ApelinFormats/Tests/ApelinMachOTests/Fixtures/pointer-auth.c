// The source of the ios-arm64e-*-binds binaries. See build.sh. No headers:
// the older linkers these are made with cannot read a current SDK's.

extern int apelin_imported(const void *string);

__attribute__((visibility("default"))) int apelin_fixture(void) {
    return apelin_imported(__builtin___CFStringMakeConstantString("apelin"));
}

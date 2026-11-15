// The source of every binary in binaries/. See build.sh.

#include <CoreFoundation/CoreFoundation.h>

__attribute__((visibility("default"))) int apelin_fixture(void) {
    return (int)CFAbsoluteTimeGetCurrent() & 1;
}

#ifdef FIXTURE_MAIN
int main(void) {
    return apelin_fixture();
}
#endif

// The whole source of the code-signing fixtures beside it. See build.sh.
__attribute__((visibility("default"))) int fixture_entry(void) {
    return 7;
}

#ifdef FIXTURE_EXECUTABLE
int main(void) {
    return fixture_entry();
}
#endif

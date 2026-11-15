/* Static Mach-O instruction inventory, using the selected Xcode's LLVM decoder.
 * This program never maps an inspected image executable or loads it as a dylib.
 * It prints counters instead of millions of disassembly lines. */
#include <ctype.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <inttypes.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef void *(*Create)(const char *, const char *, const char *, void *, int, void *, void *);
typedef size_t (*Decode)(void *, uint8_t *, uint64_t, uint64_t, char *, size_t);
typedef void (*Dispose)(void *);
enum { slots = 4096, maxCPUs = 16 };
struct Count { char name[64]; uint64_t count, address; };
static struct Count counts[maxCPUs + 1][slots];
/* Feature acceptance and the mnemonic depend on the instruction word, not
 * its PC. Repeated instructions need not be decoded for every occurrence. */
struct Cached { uint32_t word; uint16_t slot, unavailable; uint8_t valid; };
static struct Cached cache[1U << 18];

static _Noreturn void fail(const char *message) { fprintf(stderr, "%s\n", message); exit(1); }
static unsigned slotFor(const char *name) {
    uint32_t hash = 2166136261U;
    for (const char *p = name; *p; ++p) hash = (hash ^ (uint8_t)*p) * 16777619U;
    unsigned slot = hash % slots;
    for (unsigned probe = 0; probe < slots; ++probe, slot = (slot + 1) % slots) {
        struct Count *entry = &counts[0][slot];
        if (!entry->name[0]) {
            snprintf(entry->name, sizeof(entry->name), "%s", name);
        }
        if (!strcmp(entry->name, name)) return slot;
    }
    fail("Too many instruction mnemonics");
}
static void printCounts(int table) {
    int comma = 0;
    putchar('{');
    for (unsigned i = 0; i < slots; ++i) if (counts[table][i].count) {
        printf("%s\"%s\":%" PRIu64, comma ? "," : "", counts[table][i].name, counts[table][i].count);
        comma = 1;
    }
    putchar('}');
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > maxCPUs + 3) fail("usage: inventory LIBLLVM IMAGE [CPU ...]");
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) fail("Cannot load Xcode's LLVM decoder");
    void (*initialize)(void) = dlsym(library, "lto_initialize_disassembler");
    Create create = (Create)dlsym(library, "LLVMCreateDisasmCPUFeatures");
    Decode decode = (Decode)dlsym(library, "LLVMDisasmInstruction");
    Dispose dispose = (Dispose)dlsym(library, "LLVMDisasmDispose");
    if (!initialize || !create || !decode || !dispose) fail("LLVM disassembler API is unavailable");
    initialize();
    int cpuCount = argc - 3;
    void *decoders[maxCPUs + 1];
    decoders[0] = create("arm64-apple-macosx", "apple-m1", "", NULL, 0, NULL, NULL);
    for (int i = 0; i < cpuCount; ++i) {
        for (const char *p = argv[i + 3]; *p; ++p)
            if (!isalnum((unsigned char)*p) && *p != '-') fail("Invalid CPU name");
        decoders[i + 1] = create("arm64-apple-macosx", argv[i + 3], "", NULL, 0, NULL, NULL);
    }
    for (int i = 0; i <= cpuCount; ++i) if (!decoders[i]) fail("Cannot create LLVM CPU decoder");
    int fd = open(argv[2], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || st.st_size < (off_t)sizeof(struct mach_header_64)) fail("Cannot read Mach-O");
    size_t length = (size_t)st.st_size;
    uint8_t *bytes = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
    if (bytes == MAP_FAILED) fail("Cannot map Mach-O for reading");
    const struct mach_header_64 *header = (const void *)bytes;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) fail("Expected a thin arm64 image");
    size_t cursor = sizeof(*header), end = cursor + header->sizeofcmds;
    if (end > length || header->ncmds > header->sizeofcmds / sizeof(struct load_command)) fail("Invalid load commands");
    uint64_t total = 0, unknown = 0;
    uint32_t unknownWords[32];
    uint64_t unknownPCs[32];
    unsigned unknownExamples = 0;
    char text[1024], scratch[1024], mnemonic[64];
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (end - cursor < sizeof(struct load_command)) fail("Truncated load command");
        const struct load_command *command = (const void *)(bytes + cursor);
        if (command->cmdsize < sizeof(*command) || command->cmdsize > end - cursor) fail("Invalid load command size");
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (command->cmdsize < sizeof(*segment)
                    || segment->nsects > (command->cmdsize - sizeof(*segment)) / sizeof(struct section_64))
                fail("Invalid sections");
            const struct section_64 *sections = (const void *)(segment + 1);
            for (uint32_t j = 0; j < segment->nsects; ++j) {
                const struct section_64 *section = &sections[j];
                if (!(section->flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
                if (section->offset > length || section->size > length - section->offset || section->size % 4)
                    fail("Invalid code section");
                for (uint64_t k = 0; k < section->size; k += 4) {
                    uint8_t *instruction = bytes + section->offset + k;
                    uint64_t pc = section->addr + k;
                    ++total;
                    uint32_t word;
                    memcpy(&word, instruction, sizeof(word));
                    struct Cached *cached = &cache[(word * 2654435761U) >> 14];
                    if (!cached->valid || cached->word != word) {
                        cached->valid = 1; cached->word = word; cached->slot = 0; cached->unavailable = 0;
                        if (decode(decoders[0], instruction, 4, pc, text, sizeof(text)) == 4) {
                            char *start = text;
                            while (isspace((unsigned char)*start)) ++start;
                            size_t n = 0;
                            while (isalnum((unsigned char)start[n]) || start[n] == '_') ++n;
                            if (!n || n >= sizeof(mnemonic)) fail("Unexpected LLVM mnemonic");
                            memcpy(mnemonic, start, n); mnemonic[n] = 0;
                            cached->slot = (uint16_t)(slotFor(mnemonic) + 1);
                            for (int cpu = 1; cpu <= cpuCount; ++cpu)
                                if (decode(decoders[cpu], instruction, 4, pc, scratch, sizeof(scratch)) != 4)
                                    cached->unavailable |= (uint16_t)(1U << (cpu - 1));
                        }
                    }
                    if (!cached->slot) {
                        ++unknown;
                        unsigned example = 0;
                        while (example < unknownExamples && unknownWords[example] != word) ++example;
                        if (example == unknownExamples && unknownExamples < 32) {
                            unknownWords[unknownExamples] = word; unknownPCs[unknownExamples++] = pc;
                        }
                        continue;
                    }
                    unsigned slot = cached->slot - 1;
                    if (!counts[0][slot].count) counts[0][slot].address = pc;
                    ++counts[0][slot].count;
                    for (int cpu = 1; cpu <= cpuCount; ++cpu) if (cached->unavailable & (1U << (cpu - 1))) {
                        if (!counts[cpu][slot].count) strcpy(counts[cpu][slot].name, counts[0][slot].name);
                        ++counts[cpu][slot].count;
                    }
                }
            }
        }
        cursor += command->cmdsize;
    }
    if (cursor != end) fail("Load command size mismatch");
    printf(
        "{\"referenceCPU\":\"apple-m1\",\"referenceInstructions\":%" PRIu64 ",\"referenceUnknown\":%" PRIu64 ",\"mnemonics\":",
        total,
        unknown
    );
    printCounts(0);
    printf(",\"unknownInstructions\":[");
    for (unsigned i = 0; i < unknownExamples; ++i)
        printf(
            "%s{\"address\":\"%" PRIx64 "\",\"word\":\"%08" PRIx32 "\"}",
            i ? "," : "",
            unknownPCs[i],
            unknownWords[i]
        );
    printf("],\"cpus\":{");
    for (int i = 0; i < cpuCount; ++i) {
        printf("%s\"%s\":{\"missingAddresses\":0,\"unsupportedInstructions\":", i ? "," : "", argv[i + 3]);
        printCounts(i + 1); putchar('}');
    }
    printf("},\"firstAddresses\":{");
    int comma = 0;
    for (unsigned i = 0; i < slots; ++i) if (counts[0][i].count) {
        printf("%s\"%s\":\"%" PRIx64 "\"", comma ? "," : "", counts[0][i].name, counts[0][i].address); comma = 1;
    }
    puts("}}");
    for (int i = 0; i <= cpuCount; ++i) dispose(decoders[i]);
    munmap(bytes, length); close(fd); dlclose(library);
    return 0;
}

/* Pure policy/constant tests. This file never allocates or calls Darwin APIs. */
#include "../MemoryTrimPolicy.h"
#include <inttypes.h>
#include <stdio.h>

static unsigned checks;
#define CHECK(expression) do {                                                   \
    ++checks;                                                                    \
    if (!(expression)) {                                                         \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression);           \
        return 1;                                                                \
    }                                                                            \
} while (0)

static int check_hard_limits(SJGMemoryTrimMode mode,
                             uint64_t ram,
                             uint64_t available) {
    SJGMemoryTrimPlan p = sjg_mt_make_plan(mode, ram, available);
    uint64_t ramLimit = mode == SJGMemoryTrimModeDeep
        ? sjg_mt_ratio_floor(ram, 15, 100)
        : sjg_mt_ratio_floor(ram, 8, 100);
    uint64_t availableLimit = mode == SJGMemoryTrimModeDeep
        ? sjg_mt_ratio_floor(available, 35, 100)
        : sjg_mt_ratio_floor(available, 20, 100);
    uint64_t absoluteLimit = mode == SJGMemoryTrimModeDeep
        ? SJG_MT_DEEP_CAP_BYTES : SJG_MT_NORMAL_CAP_BYTES;
    CHECK(p.budget_bytes <= ramLimit);
    CHECK(p.budget_bytes <= availableLimit);
    CHECK(p.budget_bytes <= absoluteLimit);
    CHECK(p.planned_bytes <= p.budget_bytes);
    CHECK(p.planned_bytes == p.block_count * p.chunk_bytes);
    CHECK(p.available == (p.block_count != 0));
    if (p.available) {
        CHECK(available >= p.reserve_bytes);
        CHECK(p.planned_bytes <= available - p.reserve_bytes);
    }
    return 0;
}

int main(void) {
    const uint64_t M = SJG_MT_MIB;
    SJGMemoryTrimPlan n = sjg_mt_make_plan(SJGMemoryTrimModeNormal,
                                            8ULL * 1024 * M,
                                            3ULL * 1024 * M);
    CHECK(SJG_MT_NORMAL_CHUNK_BYTES == 7ULL * M);
    CHECK(SJG_MT_DEEP_CHUNK_BYTES == 3ULL * M);
    CHECK(SJG_MT_NORMAL_CAP_BYTES == 384ULL * M);
    CHECK(SJG_MT_DEEP_CAP_BYTES == 768ULL * M);
    CHECK(SJG_MT_MIN_RESERVE_BYTES == 512ULL * M);
    CHECK(n.chunk_bytes == 7ULL * M);
    CHECK(n.deadline_milliseconds == 8000U);
    CHECK(n.hold_milliseconds == 150U);
    CHECK(n.reserve_bytes == 1024ULL * M); /* max(512 MiB, RAM / 8). */
    CHECK(n.budget_bytes == 384ULL * M);
    CHECK(n.block_count == 54U);
    CHECK(n.planned_bytes == 378ULL * M);
    CHECK(n.available);

    SJGMemoryTrimPlan d = sjg_mt_make_plan(SJGMemoryTrimModeDeep,
                                            8ULL * 1024 * M,
                                            3ULL * 1024 * M);
    CHECK(d.chunk_bytes == 3ULL * M);
    CHECK(d.deadline_milliseconds == 20000U);
    CHECK(d.hold_milliseconds == 500U);
    CHECK(d.reserve_bytes == 1024ULL * M);
    CHECK(d.budget_bytes == 768ULL * M);
    CHECK(d.block_count == 256U);
    CHECK(d.planned_bytes == 768ULL * M);
    CHECK(d.available);

    /* Reserve dominates percentage limits when available memory is low. */
    n = sjg_mt_make_plan(SJGMemoryTrimModeNormal, 4ULL * 1024 * M, 512ULL * M);
    CHECK(n.reserve_bytes == 512ULL * M);
    CHECK(!n.available && n.budget_bytes == 0 && n.planned_bytes == 0);
    n = sjg_mt_make_plan(SJGMemoryTrimModeNormal, 4ULL * 1024 * M, 518ULL * M);
    CHECK(!n.available); /* Six MiB headroom is less than a seven MiB chunk. */
    n = sjg_mt_make_plan(SJGMemoryTrimModeNormal, 4ULL * 1024 * M, 519ULL * M);
    CHECK(n.available && n.block_count == 1 && n.planned_bytes == 7ULL * M);

    /* RAM 12.5% reserve is selected above 4 GiB. */
    d = sjg_mt_make_plan(SJGMemoryTrimModeDeep, 16ULL * 1024 * M, 3ULL * 1024 * M);
    CHECK(d.reserve_bytes == 2ULL * 1024 * M);
    CHECK(d.budget_bytes == 768ULL * M);

    /* Zero/overflow edges remain closed and ratio arithmetic remains exact. */
    n = sjg_mt_make_plan(SJGMemoryTrimModeNormal, 0, UINT64_MAX);
    CHECK(!n.available && n.budget_bytes == 0);
    CHECK(sjg_mt_ratio_floor(UINT64_MAX, 0, 100) == 0);
    CHECK(sjg_mt_ratio_floor(UINT64_MAX, 1, 0) == 0);
    CHECK(sjg_mt_ratio_floor(UINT64_MAX, 101, 100) == 0);
    CHECK(sjg_mt_ratio_floor(UINT64_MAX, 8, 100) <= UINT64_MAX / 10);

    const uint64_t ramValues[] = {
        1ULL * 1024 * M, 4ULL * 1024 * M, 8ULL * 1024 * M,
        16ULL * 1024 * M, UINT64_MAX
    };
    const uint64_t availableValues[] = {
        0, 511ULL * M, 512ULL * M, 519ULL * M,
        1ULL * 1024 * M, 4ULL * 1024 * M, UINT64_MAX
    };
    for (unsigned mode = 0; mode < 2; ++mode) {
        for (size_t i = 0; i < sizeof(ramValues) / sizeof(ramValues[0]); ++i) {
            for (size_t j = 0; j < sizeof(availableValues) / sizeof(availableValues[0]); ++j) {
                if (check_hard_limits((SJGMemoryTrimMode)mode,
                                      ramValues[i], availableValues[j])) return 1;
            }
        }
    }

    printf("memory-trim-policy: %u checks PASS (no allocation performed)\n", checks);
    return 0;
}

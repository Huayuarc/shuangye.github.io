#ifndef SJG_MEMORY_TRIM_POLICY_H
#define SJG_MEMORY_TRIM_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SJG_MT_MIB (1024ULL * 1024ULL)
#define SJG_MT_NORMAL_CHUNK_BYTES (7ULL * SJG_MT_MIB)
#define SJG_MT_DEEP_CHUNK_BYTES (3ULL * SJG_MT_MIB)
#define SJG_MT_NORMAL_CAP_BYTES (384ULL * SJG_MT_MIB)
#define SJG_MT_DEEP_CAP_BYTES (768ULL * SJG_MT_MIB)
#define SJG_MT_MIN_RESERVE_BYTES (512ULL * SJG_MT_MIB)

typedef enum {
    SJGMemoryTrimModeNormal = 0,
    SJGMemoryTrimModeDeep = 1
} SJGMemoryTrimMode;

typedef struct {
    uint64_t reserve_bytes;
    uint64_t budget_bytes;
    uint64_t planned_bytes;
    uint64_t chunk_bytes;
    uint64_t block_count;
    uint32_t deadline_milliseconds;
    uint32_t hold_milliseconds;
    bool available;
} SJGMemoryTrimPlan;

/* Overflow-safe floor(value * numerator / denominator), for small ratios. */
static inline uint64_t sjg_mt_ratio_floor(uint64_t value,
                                          uint64_t numerator,
                                          uint64_t denominator) {
    if (denominator == 0 || numerator > denominator) return 0;
    return (value / denominator) * numerator +
           ((value % denominator) * numerator) / denominator;
}

static inline uint64_t sjg_mt_min3(uint64_t a, uint64_t b, uint64_t c) {
    uint64_t m = a < b ? a : b;
    return m < c ? m : c;
}

static inline SJGMemoryTrimPlan sjg_mt_make_plan(SJGMemoryTrimMode mode,
                                                  uint64_t physical_bytes,
                                                  uint64_t available_bytes) {
    SJGMemoryTrimPlan p = {0};
    const bool deep = mode == SJGMemoryTrimModeDeep;
    p.chunk_bytes = deep ? SJG_MT_DEEP_CHUNK_BYTES : SJG_MT_NORMAL_CHUNK_BYTES;
    p.deadline_milliseconds = deep ? 20000U : 8000U;
    p.hold_milliseconds = deep ? 500U : 150U;

    uint64_t ram_reserve = physical_bytes / 8ULL; /* RAM 12.5%. */
    p.reserve_bytes = ram_reserve > SJG_MT_MIN_RESERVE_BYTES
        ? ram_reserve : SJG_MT_MIN_RESERVE_BYTES;

    if (physical_bytes == 0 || available_bytes <= p.reserve_bytes) return p;

    uint64_t ram_limit = deep
        ? sjg_mt_ratio_floor(physical_bytes, 3, 20)  /* 15% */
        : sjg_mt_ratio_floor(physical_bytes, 2, 25); /* 8% */
    uint64_t available_limit = deep
        ? sjg_mt_ratio_floor(available_bytes, 7, 20) /* 35% */
        : available_bytes / 5ULL;                    /* 20% */
    uint64_t cap = deep ? SJG_MT_DEEP_CAP_BYTES : SJG_MT_NORMAL_CAP_BYTES;
    uint64_t headroom = available_bytes - p.reserve_bytes;

    p.budget_bytes = sjg_mt_min3(ram_limit, available_limit, cap);
    if (p.budget_bytes > headroom) p.budget_bytes = headroom;
    p.block_count = p.budget_bytes / p.chunk_bytes;
    p.planned_bytes = p.block_count * p.chunk_bytes;
    p.available = p.block_count != 0;
    return p;
}

#endif

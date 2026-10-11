#ifndef SJG_POLICY_H
#define SJG_POLICY_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
typedef struct { int32_t active; uint32_t active_attr; int32_t inactive; uint32_t inactive_attr; } SJGLimits;
_Static_assert(sizeof(SJGLimits)==16,"XNU memlimit ABI");
/* Fixed target: never multiply observed limits. 25% of RAM, capped at 1536 MiB. */
static inline int32_t sjg_target(uint64_t ram_bytes) {
    uint64_t mb=ram_bytes/(1024ULL*1024ULL);
    if (mb<2048) return 0; /* unknown/unsupported small RAM: leave unchanged */
    uint64_t target=mb/4;
    if (target>1536) target=1536;
    return (int32_t)target;
}
static inline bool sjg_plan(SJGLimits old, int32_t target, SJGLimits *out) {
    *out=old;
    if(target<=0 || (old.active_attr&~1u) || (old.inactive_attr&~1u)) return false;
    /* Nonpositive special/default limits are preserved: not treated as zero MB. */
    if(old.active>0 && old.active<target) out->active=target;
    if(old.inactive>0 && old.inactive<target) out->inactive=target;
    return out->active!=old.active || out->inactive!=old.inactive;
}
static inline bool sjg_equal(SJGLimits a,SJGLimits b) {
    return a.active==b.active && a.inactive==b.inactive && a.active_attr==b.active_attr && a.inactive_attr==b.inactive_attr;
}
#endif

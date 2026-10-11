#import "MemoryTrimEngine.h"
#import "MemoryTrimPolicy.h"
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <stdint.h>
#import <stdlib.h>

#if !__has_feature(objc_arc)
#error MemoryTrimEngine.m requires Objective-C ARC
#endif

#define SJG_MT_ENGINE_REVISION @"memory-trim-v1"

typedef struct {
    uint64_t physical;
    uint64_t resident;
    uint64_t footprint;
    uint64_t available;
} SJGMemorySnapshot;

typedef size_t (*SJGAvailableMemoryFunction)(void);

static SJGAvailableMemoryFunction SJGAvailableMemoryAPI(void) {
    static SJGAvailableMemoryFunction function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        function = (SJGAvailableMemoryFunction)dlsym(RTLD_DEFAULT,
                                                       "os_proc_available_memory");
    });
    return function;
}

static uint64_t SJGSaturatingPageBytes(uint64_t pages, uint64_t pageSize) {
    return pageSize && pages > UINT64_MAX / pageSize
        ? UINT64_MAX : pages * pageSize;
}

/* Prefer the process-aware API. Old SDK/runtime combinations fall back to a
 * fresh host VM snapshot rather than treating symbol absence as free memory. */
static BOOL SJGCurrentAvailable(uint64_t *value) {
    SJGAvailableMemoryFunction function = SJGAvailableMemoryAPI();
    if (function) {
        *value = (uint64_t)function();
        return YES;
    }
    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t pageResult = host_page_size(host, &pageSize);
    kern_return_t vmResult = host_statistics64(host, HOST_VM_INFO64,
                                                (host_info64_t)&vm, &count);
    (void)mach_port_deallocate(mach_task_self(), host);
    if (pageResult != KERN_SUCCESS || vmResult != KERN_SUCCESS || pageSize == 0)
        return NO;
    *value = SJGSaturatingPageBytes(
        (uint64_t)vm.free_count + (uint64_t)vm.inactive_count, (uint64_t)pageSize);
    return YES;
}

static BOOL SJGTakeSnapshot(SJGMemorySnapshot *snapshot, size_t *pageSizeOut) {
    if (!snapshot) return NO;
    *snapshot = (SJGMemorySnapshot){0};

    uint64_t physical = 0;
    size_t physicalSize = sizeof(physical);
    if (sysctlbyname("hw.memsize", &physical, &physicalSize, NULL, 0) != 0 ||
        physicalSize != sizeof(physical) || physical == 0) return NO;

    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    kern_return_t pageResult = host_page_size(host, &pageSize);
    kern_return_t vmResult = host_statistics64(host, HOST_VM_INFO64,
                                                (host_info64_t)&vm, &vmCount);
    (void)mach_port_deallocate(mach_task_self(), host);
    if (pageResult != KERN_SUCCESS || vmResult != KERN_SUCCESS || pageSize == 0)
        return NO;

    mach_task_basic_info_data_t basic = {0};
    mach_msg_type_number_t basicCount = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&basic, &basicCount) != KERN_SUCCESS) return NO;

    uint64_t footprint = 0;
#if defined(TASK_VM_INFO) && defined(TASK_VM_INFO_COUNT)
    task_vm_info_data_t taskVM = {0};
    mach_msg_type_number_t taskVMCount = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&taskVM, &taskVMCount) != KERN_SUCCESS) return NO;
    footprint = (uint64_t)taskVM.phys_footprint;
#else
    /* Compatibility for SDKs predating TASK_VM_INFO. */
    footprint = (uint64_t)basic.resident_size;
#endif

    uint64_t available = 0;
    SJGAvailableMemoryFunction availableFunction = SJGAvailableMemoryAPI();
    if (availableFunction) available = (uint64_t)availableFunction();
    else available = SJGSaturatingPageBytes(
        (uint64_t)vm.free_count + (uint64_t)vm.inactive_count, (uint64_t)pageSize);

    snapshot->physical = physical;
    snapshot->resident = (uint64_t)basic.resident_size;
    snapshot->footprint = footprint;
    snapshot->available = available;
    if (pageSizeOut) *pageSizeOut = (size_t)pageSize;
    return YES;
}

static NSDictionary<NSString *, NSNumber *> *SJGSnapshotDictionary(SJGMemorySnapshot s) {
    return @{ @"physicalBytes": @(s.physical), @"residentBytes": @(s.resident),
              @"footprintBytes": @(s.footprint), @"availableBytes": @(s.available) };
}

static NSDictionary<NSString *, id> *SJGResult(NSString *mode,
                                                BOOL completed,
                                                NSString *reason,
                                                uint64_t peak,
                                                uint64_t allocated,
                                                uint64_t rounds,
                                                double elapsed,
                                                SJGMemorySnapshot initial,
                                                SJGMemorySnapshot final,
                                                uint64_t minimumAvailable,
                                                BOOL releaseAll) {
    return @{ @"mode": mode, @"completed": @(completed), @"stopReason": reason,
              @"peakBytes": @(peak), @"allocatedBytes": @(allocated),
              @"rounds": @(rounds), @"elapsedSeconds": @(elapsed),
              @"initial": SJGSnapshotDictionary(initial),
              @"final": SJGSnapshotDictionary(final),
              @"initialPhysicalBytes": @(initial.physical),
              @"initialResidentBytes": @(initial.resident),
              @"initialFootprintBytes": @(initial.footprint),
              @"initialAvailableBytes": @(initial.available),
              @"finalPhysicalBytes": @(final.physical),
              @"finalResidentBytes": @(final.resident),
              @"finalFootprintBytes": @(final.footprint),
              @"finalAvailableBytes": @(final.available),
              @"initialPhysical": @(initial.physical),
              @"initialResident": @(initial.resident),
              @"initialFootprint": @(initial.footprint),
              @"initialAvailable": @(initial.available),
              @"finalPhysical": @(final.physical),
              @"finalResident": @(final.resident),
              @"finalFootprint": @(final.footprint),
              @"finalAvailable": @(final.available),
              @"minimumAvailable": @(minimumAvailable),
              @"releaseAll": @(releaseAll),
              @"engineRevision": SJG_MT_ENGINE_REVISION };
}

static dispatch_semaphore_t SJGMemoryTrimGate(void) {
    static dispatch_semaphore_t gate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gate = dispatch_semaphore_create(1); });
    return gate;
}

static BOOL SJGTrimCancelled(void) {
    return [[NSThread currentThread] isCancelled];
}

static double SJGMonotonicSeconds(void) {
    return [[NSProcessInfo processInfo] systemUptime];
}

static BOOL SJGWaitUntil(double end, double deadline) {
    dispatch_semaphore_t sleeper = dispatch_semaphore_create(0);
    while (SJGMonotonicSeconds() < end) {
        if (SJGTrimCancelled() || SJGMonotonicSeconds() >= deadline) return NO;
        double remaining = end - SJGMonotonicSeconds();
        if (remaining > 0.025) remaining = 0.025;
        int64_t nanoseconds = (int64_t)(remaining * (double)NSEC_PER_SEC);
        if (nanoseconds > 0)
            (void)dispatch_semaphore_wait(sleeper,
                                          dispatch_time(DISPATCH_TIME_NOW, nanoseconds));
    }
    return YES;
}

NSDictionary<NSString *, id> *SJGRunMemoryTrim(NSString *mode) {
    double started = SJGMonotonicSeconds();
    SJGMemorySnapshot initial = {0}, final = {0};
    NSString *canonical = [[mode isKindOfClass:[NSString class]]
                           ? mode : @"" lowercaseString];
    BOOL deep = [canonical isEqualToString:@"deep"];
    if (!deep && ![canonical isEqualToString:@"normal"])
        return SJGResult(@"invalid", NO, @"invalid_mode", 0, 0, 0,
                         SJGMonotonicSeconds() - started, initial, final, 0, YES);

    dispatch_semaphore_t gate = SJGMemoryTrimGate();
    if (dispatch_semaphore_wait(gate, DISPATCH_TIME_NOW) != 0)
        return SJGResult(canonical, NO, @"busy", 0, 0, 0,
                         SJGMonotonicSeconds() - started, initial, final, 0, YES);

    BOOL completed = NO;
    BOOL releaseAll = YES;
    NSString *reason = @"metrics_failed";
    uint64_t peak = 0, allocated = 0, rounds = 0, minimumAvailable = 0;
    void **blocks = NULL;
    size_t pageSize = 0;
    SJGMemoryTrimPlan plan = {0};
    double deadline = started + (deep ? 20.0 : 8.0);

    if (!SJGTakeSnapshot(&initial, &pageSize)) goto finish;
    plan = sjg_mt_make_plan(deep ? SJGMemoryTrimModeDeep : SJGMemoryTrimModeNormal,
                            initial.physical, initial.available);
    minimumAvailable = plan.reserve_bytes;
    if (SJGTrimCancelled()) { reason = @"cancelled"; goto finish; }
    if (!plan.available) { reason = @"low_available"; goto finish; }
    if (plan.block_count > SIZE_MAX / sizeof(*blocks)) {
        reason = @"allocation_failed"; goto finish;
    }
    blocks = calloc((size_t)plan.block_count, sizeof(*blocks));
    if (!blocks) { reason = @"allocation_failed"; goto finish; }

    while (rounds < plan.block_count) {
        if (SJGTrimCancelled()) { reason = @"cancelled"; break; }
        if (SJGMonotonicSeconds() >= deadline) { reason = @"deadline"; break; }

        uint64_t available = 0;
        if (!SJGCurrentAvailable(&available)) { reason = @"metrics_failed"; break; }
        if (available <= minimumAvailable ||
            available - minimumAvailable < plan.chunk_bytes) {
            reason = @"low_available"; break;
        }

        void *memory = malloc((size_t)plan.chunk_bytes);
        if (!memory) { reason = @"allocation_failed"; break; }
        blocks[rounds++] = memory;
        allocated += plan.chunk_bytes;
        if (allocated > peak) peak = allocated;

        volatile uint8_t *bytes = (volatile uint8_t *)memory;
        BOOL cancelled = NO;
        for (uint64_t offset = 0; offset < plan.chunk_bytes; offset += pageSize) {
            bytes[offset] = (uint8_t)(offset / pageSize);
            if (((offset / pageSize) & 63ULL) == 63ULL && SJGTrimCancelled()) {
                cancelled = YES; break;
            }
        }
        if (cancelled) { reason = @"cancelled"; break; }

        if (!SJGCurrentAvailable(&available)) { reason = @"metrics_failed"; break; }
        if (available < minimumAvailable) { reason = @"low_available"; break; }
    }

    if (rounds == plan.block_count) {
        double holdEnd = SJGMonotonicSeconds() +
                         (double)plan.hold_milliseconds / 1000.0;
        if (!SJGWaitUntil(holdEnd, deadline))
            reason = SJGTrimCancelled() ? @"cancelled" : @"deadline";
        else { completed = YES; reason = @"completed"; }
    }

finish:
    if (blocks) {
        for (uint64_t i = 0; i < rounds; i++) {
            free(blocks[i]);
            blocks[i] = NULL;
        }
        free(blocks);
    }
    if (!SJGTakeSnapshot(&final, NULL)) {
        if (completed) { completed = NO; reason = @"final_metrics_failed"; }
    }
    dispatch_semaphore_signal(gate);
    return SJGResult(canonical, completed, reason, peak, allocated, rounds,
                     SJGMonotonicSeconds() - started, initial, final,
                     minimumAvailable, releaseAll);
}

#pragma once
#import <Metal/Metal.h>
#include <stdlib.h>
// The diagnostic cap only removes capabilities; the actual GPU remains checked.
static inline BOOL pjdv_entry_gpu(id<MTLDevice> device) {
    const char *cap = getenv("PJDV_GPU_FAMILY_CAP");
    int family = cap ? atoi(cap) : 0;
    return !device || ![device supportsFamily:MTLGPUFamilyApple9] || family == 7 || family == 8;
}

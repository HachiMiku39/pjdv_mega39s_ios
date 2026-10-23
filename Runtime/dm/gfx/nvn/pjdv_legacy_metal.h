#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdlib.h>

// CPU-side replay handles on Big Sur. These numbers are never written into
// GPU argument buffers: the standard MTLArgumentEncoder resolves each handle
// back to its buffer and offset. No private GPU-address API is required.
static inline BOOL pjdv_test_macos11_api(void) {
#if TARGET_OS_MACCATALYST
    static int enabled = -1;
    if (enabled < 0) enabled = getenv("PJDV_TEST_MACOS11_API") != NULL;
    return enabled;
#else
    return NO;
#endif
}
static inline BOOL pjdv_legacy_handles(void) {
#if DM_NVN_M3
    if (pjdv_test_macos11_api()) return YES;
    if (@available(macOS 13.0, macCatalyst 16.0, iOS 16.0, *)) return NO;
    return YES;
#else
    return NO;
#endif
}
static inline uint64_t pjdv_buffer_address(id<MTLBuffer> buffer) {
    if (!buffer) return 0;
    if (!pjdv_legacy_handles()) {
        if (@available(macOS 13.0, macCatalyst 16.0, iOS 16.0, *)) return buffer.gpuAddress;
    }
    static char key;
    static _Atomic uint64_t next = 0x4000000000000000ull;
    @synchronized (buffer) {
        NSNumber *stored = objc_getAssociatedObject(buffer, &key);
        if (stored) return stored.unsignedLongLongValue;
        uint64_t span = ((uint64_t)buffer.length + 4095) & ~4095ull;
        if (!span || span > (1ull << 40)) abort();
        uint64_t value = atomic_fetch_add(&next, span);
        objc_setAssociatedObject(buffer, &key, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return value;
    }
}
static inline uint64_t pjdv_texture_id(id<MTLTexture> texture) {
#if DM_NVN_M3
    return (uint64_t)(uintptr_t)(__bridge void *)texture;
#else
    return texture.gpuResourceID._impl;
#endif
}
static inline uint64_t pjdv_sampler_id(id<MTLSamplerState> sampler) {
#if DM_NVN_M3
    return (uint64_t)(uintptr_t)(__bridge void *)sampler;
#else
    return sampler.gpuResourceID._impl;
#endif
}

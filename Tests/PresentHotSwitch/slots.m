#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

static void require(BOOL ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL %s\n", what); exit(2); }
}
static pthread_mutex_t g_pq_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pq_cv = PTHREAD_COND_INITIALIZER;
static int g_present_slot_busy[3], g_pq_inflight;
static uint64_t g_pq_done;
static _Atomic int waits;
static int observed_wait(pthread_cond_t *cv, pthread_mutex_t *mu) {
    atomic_fetch_add(&waits, 1);
    return pthread_cond_wait(cv, mu);
}
#define pthread_cond_wait observed_wait
#include "slot_functions.inc"
#undef pthread_cond_wait

// Metal command encoding is represented by a probe. The included production
// body reserves the slot, handles failure and installs the completion callback.
@protocol MTLTexture @end
@protocol MTLBuffer @end
@class Probe;
typedef void (^Callback)(Probe *);
static Callback last_callback;
static BOOL command_ok = YES, encode_ok = YES, hdr_success, capture_success;
static int ended, signaled, captures;
@interface Probe : NSObject
@property(nonatomic, strong) NSError *error;
@property(nonatomic, readonly) Probe *texture;
@property(nonatomic, readonly) int pixelFormat;
- (Probe *)commandBuffer;
- (void)reset;
- (void)waitForDrawable:(Probe *)d;
- (void)signalDrawable:(Probe *)d;
- (void)endCommandBuffer;
- (void)beginCommandBufferWithAllocator:(Probe *)a;
- (void)commit:(Probe *const *)buffers count:(int)n options:(Probe *)opts;
- (void)addCompletedHandler:(Callback)block;
- (void)addFeedbackHandler:(Callback)block;
@end
@implementation Probe
- (Probe *)texture { return self; }
- (int)pixelFormat { return 0; }
- (Probe *)commandBuffer { return command_ok ? self : nil; }
- (void)reset {}
- (void)waitForDrawable:(Probe *)d {}
- (void)signalDrawable:(Probe *)d { signaled++; }
- (void)endCommandBuffer { ended++; }
- (void)beginCommandBufferWithAllocator:(Probe *)a {}
- (void)commit:(Probe *const *)buffers count:(int)n options:(Probe *)opts {}
- (void)addCompletedHandler:(Callback)block { last_callback = [block copy]; }
- (void)addFeedbackHandler:(Callback)block { last_callback = [block copy]; }
@end
static Probe *g_q, *g_q4, *g_present_alloc4[3], *g_present_cb[3];
static id<MTLBuffer> g_pjdv_hdr_stats[3];
#define CBUF Probe *
#define MTL4CommitOptions Probe
#define MTLPixelFormatRGBA16Float 1
#define FB_ARG Probe *
#if DM_NVN_M3
#define FB_ON(o,cb) cb
#define FB_SEL addCompletedHandler
#else
#define FB_ON(o,cb) o
#define FB_SEL addFeedbackHandler
#endif
#define MLOG(...) ((void)0)
#define pjdv_spatial_encode(...) nil
#define pjdv_hdr_encode(...) nil
#define present_encode_m4(...) encode_ok
#define pjdv_fx_capture_encode(...) nil
static void pjdv_hdr_complete(id hdr, id stats, uint64_t frame, BOOL success) { hdr_success = success; }
static void pjdv_fx_capture_complete(id capture, BOOL success) { captures++; capture_success = success; }
static int submit(uint64_t ticket) {
    uint64_t frame = ticket;
    int alloc_i = (int)(ticket % 3);
    Probe *dr = g_q;
    id hdrFrame = nil;
#include "encode_and_feedback.inc"
    return 1;
}

static _Atomic bool reacquired;
static void *reuse(void *unused) {
    present_acquire_slot(1); // ticket 4 wants the same slot as ticket 1
    atomic_store(&reacquired, true);
    present_cancel_slot(1);
    return NULL;
}
static void wait_count(int min) {
    for (int i = 0; i < 1000 && atomic_load(&waits) < min; i++) usleep(1000);
    require(atomic_load(&waits) >= min, "slot waiter did not sleep");
}

int main(void) { @autoreleasepool {
    g_q = g_q4 = [Probe new];
    for (int i = 0; i < 3; i++) g_present_alloc4[i] = g_present_cb[i] = g_q;
    require(submit(1) && g_pq_inflight == 1 && last_callback, "first command took ownership");
    Callback delayed = last_callback;
    pthread_t worker;
    require(!pthread_create(&worker, NULL, reuse, NULL), "create waiter");
    wait_count(1);
    // The queue retires newer dropped tickets independently of GPU completion.
    // The waiter must go back to sleep after this wake even though 4 > 1.
    pthread_mutex_lock(&g_pq_mu);
    int before = atomic_load(&waits);
    g_pq_done = 4;
    pthread_cond_broadcast(&g_pq_cv);
    pthread_mutex_unlock(&g_pq_mu);
    wait_count(before + 1);
    require(!atomic_load(&reacquired), "newer dropped ticket released an in-use slot");

    require(submit(5) && g_pq_inflight == 2 && last_callback, "another slot progressed");
    last_callback([Probe new]);
    require(hdr_success && capture_success && g_pq_done == 5 && g_pq_inflight == 1, "successful GPU feedback");
    require(!atomic_load(&reacquired), "different slot completion released original slot");

    Probe *error = [Probe new];
    error.error = [NSError errorWithDomain:@"PresentTest" code:1 userInfo:nil];
    delayed(error);
    pthread_join(worker, NULL);
    require(atomic_load(&reacquired) && !hdr_success && !capture_success, "GPU error released its own slot");
    require(g_pq_done == 5 && g_pq_inflight == 0 && captures == 2, "late completion preserved newer retirement");

#if DM_NVN_M3
    command_ok = NO;
    require(!submit(7) && !g_present_slot_busy[1] && !g_pq_inflight, "missing command buffer released slot");
    command_ok = YES;
#endif
    last_callback = nil;
    encode_ok = NO;
    int old_end = ended, old_signal = signaled;
    require(!submit(7) && !g_present_slot_busy[1] && !g_pq_inflight && !last_callback, "encoder failure released slot");
#if !DM_NVN_M3
    require(ended == old_end + 1 && signaled == old_signal + 1, "failed Metal 4 encoding released drawable");
#endif
    encode_ok = YES;
    require(submit(10) && g_pq_inflight == 1 && last_callback, "same slot reusable after failed encoding");
    last_callback([Probe new]);
    require(g_pq_done == 10 && !g_pq_inflight && !g_present_slot_busy[1], "final completion");
    printf("PASS Metal %d slot reuse, delayed/error feedback, other slot progress and encode failure\n", DM_NVN_M3 ? 3 : 4);
} return 0; }

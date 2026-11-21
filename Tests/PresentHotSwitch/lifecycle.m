#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include "pjdv_fg_policy.h"

// The production worker runs on a real pthread and Foundation run loop.
// Only the display link and layer are represented by a probe in this test.
#define MLOG(...) ((void)0)
#define MDIE(...) abort()
static int g_dm_present_link,g_present_latency=1;
static _Atomic int fakeLegacy,fakeFG,fakeNative=60,gate,entered,invalidations;
static int pjdv_test_macos11_api(void){return fakeLegacy;}
static int pjdv_game_frame_generation_mode(void){return fakeFG;}
static int mtl_fps_target(void){return fakeNative;}
static NSObject *layer;
static void *front_metal_layer(void){return (__bridge void *)layer;}
static pthread_mutex_t g_pq_mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pq_cv=PTHREAD_COND_INITIALIZER;
static uint64_t g_pq_read,g_pq_in;
static int g_pq_inflight;
@interface LinkProbe : NSObject
@property(atomic) CAFrameRateRange preferredFrameRateRange;
@property(atomic) float preferredFrameLatency;
@property(atomic,weak) id delegate;
@property(atomic,strong) NSTimer *timer;
@end
@implementation LinkProbe
-(instancetype)initWithMetalLayer:(id)l{
    self=[super init];
    if(self){entered++;while(gate)usleep(100);}
    return self;
}
-(void)addToRunLoop:(NSRunLoop*)loop forMode:(NSString*)mode{
    self.timer=[NSTimer timerWithTimeInterval:3600 repeats:YES block:^(NSTimer *t){}];
    [loop addTimer:self.timer forMode:mode];
}
-(void)invalidate{[self.timer invalidate];self.timer=nil;invalidations++;}
@end
#define CAMetalDisplayLink LinkProbe
#define NvMetalDisplayLinkDelegate NSObject
#include "link_lifecycle_under_test.inc"

static void expect(int ok,const char *label){if(!ok){fprintf(stderr,"FAIL %s\n",label);exit(2);}}
static void stopped(void){
    for(int i=0;i<10000;i++){
        pthread_mutex_lock(&g_pq_mu);
        BOOL idle=!g_link_started && !g_link_owns_layer && !g_link && !g_link_rl;
        pthread_mutex_unlock(&g_pq_mu);
        if(idle)return;
        usleep(100);
    }
    expect(0,"worker never stopped or layer ownership leaked");
}
static void cadence(float target){
    for(int i=0;i<10000;i++){
        pthread_mutex_lock(&g_pq_mu);
        LinkProbe *p=g_link;BOOL owned=g_link_owns_layer;
        pthread_mutex_unlock(&g_pq_mu);
        if(owned && p.preferredFrameRateRange.preferred==target)return;
        usleep(100);
    }
    expect(0,"unexpected rate or no worker");
}
static void *timestamps(void *role) {
    for (uint64_t n = 1; n <= 8 * PRING; n++) {
        if (role) {
            record_present_time(n, (double)n / 8);
        } else {
            double time = mtl_presented_time(n);
            expect(time == 0 || time == (double)n / 8, "timestamp has wrong ticket");
        }
    }
    return NULL;
}
static void check_timestamps(void) {
    pthread_t reader, writer;
    expect(!pthread_create(&reader, NULL, timestamps, NULL), "timestamp reader");
    expect(!pthread_create(&writer, NULL, timestamps, (void *)1), "timestamp writer");
    pthread_join(reader, NULL);
    pthread_join(writer, NULL);
    // A delayed callback for the first frame arrives after a wrap.
    uint64_t newer = 8 * PRING + 1;
    record_present_time(newer, -1);
    record_present_time(1, .5);
    expect(mtl_presented_time(newer) == -1 && !mtl_presented_time(1), "old callback replaced dropped frame");
}
static void check_late_present(void) {
    g_pq_in = 1;
    expect(!wait_present_idle(1), "queued frame escaped drain");
    g_pq_read = 1;
    g_classic_busy = 1;
    expect(!wait_present_idle(1), "encoder escaped drain");
    g_pq_inflight = 1;
    g_classic_busy = 0;
    expect(!wait_present_idle(1), "late GPU completion escaped drain");
    g_pq_inflight = 0;
    expect(wait_present_idle(1), "completed frame never released");
}
int main(void){@autoreleasepool{
    layer=[NSObject new];
    for(int iteration=0;iteration<50;iteration++){
        int previous=entered;
        gate=1;g_dm_present_link=1;link_sync();
        for(int i=0;i<10000 && entered==previous;i++)usleep(100);
        expect(entered>previous,"worker did not reach creation gate");
        g_dm_present_link=0;link_sync();gate=0;stopped();
        g_dm_present_link=1;link_sync();cadence(60);
        // Stop before any later call to link_sync updates the previous mode.
        g_dm_present_link=0;link_sync();stopped();
    }
    g_dm_present_link=1;link_sync();cadence(60);
    for(int i=0;i<1000;i++){
        fakeFG=2;link_sync();expect(g_dm_present_link==2,"lost FG request");cadence(120);
        fakeFG=1;link_sync();expect(g_dm_present_link==1,"lost FG request");cadence(60);
        fakeFG=0;fakeNative=30;link_sync();cadence(30);
        fakeNative=60;link_sync();cadence(60);
        link_sync();cadence(60);
    }
    link_request_mode(0);stopped();
    fakeLegacy=1;g_dm_present_link=2;link_sync();expect(g_dm_present_link==0,"legacy fallback");
    expect(invalidations==101,"every created worker invalidated exactly once");
    check_late_present();check_timestamps();
    puts("PASS 100 pending stops, 1000 cadence cycles, 101 invalidations, late GPU drain, timestamp wrap and parallel reads/writes");
}return 0;}

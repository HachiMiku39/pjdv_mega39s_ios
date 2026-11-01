#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <stdatomic.h>
#include "pjdv_fg_policy.h"

// Exercise the production switch function with no GPU, threads or game data.
@interface LinkProbe : NSObject
@property(nonatomic) CAFrameRateRange preferredFrameRateRange;
@property(nonatomic) int invalidations;
- (void)invalidate;
@end
@implementation LinkProbe
- (void)invalidate { self.invalidations++; }
@end
static int g_dm_present_link, g_link_mode, g_link_started, g_link_owns_layer;
static int fakeLegacy, fakeFG, fakeNative=60, creations;
static _Atomic uint64_t g_cur_frame;
static id g_link;
static CFRunLoopRef g_link_rl;
static pthread_mutex_t g_pq_mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pq_cv=PTHREAD_COND_INITIALIZER;
static int pjdv_test_macos11_api(void){return fakeLegacy;}
static int pjdv_game_frame_generation_mode(void){return fakeFG;}
static int mtl_fps_target(void){return fakeNative;}
static void *front_metal_layer(void){return (void *)1;}
static void *link_main(void *unused){return NULL;}
static CAFrameRateRange link_range(int mode){return mode==3?CAFrameRateRangeMake(30,30,30):mode==2?CAFrameRateRangeMake(60,120,120):CAFrameRateRangeMake(60,60,60);}
static int fake_create(pthread_t *t,const pthread_attr_t *a,void *(*fn)(void *),void *arg){creations++;*t=(pthread_t)1;return 0;}
static int fake_detach(pthread_t t){return 0;}
static void fake_perform(CFRunLoopRef rl,CFTypeRef mode,void (^block)(void)){block();}
#define pthread_create fake_create
#define pthread_detach fake_detach
#define CFRunLoopPerformBlock fake_perform
#define CFRunLoopStop(rl) ((void)0)
#define CFRunLoopWakeUp(rl) ((void)0)
#define MLOG(...) ((void)0)
#define MDIE(...) abort()
#include "link_sync_under_test.inc"
static void require(BOOL ok,const char *message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(2);}}
static void active(LinkProbe *probe,int request,float preferred){
    require(g_dm_present_link==request,"active request fell through to legacy fallback");
    require(g_link_owns_layer && probe.invalidations==0,"active link lost ownership");
    require(probe.preferredFrameRateRange.preferred==preferred,"wrong display cadence");
}
int main(void){@autoreleasepool{
    LinkProbe *probe=[LinkProbe new];g_link=probe;g_link_started=1;g_link_owns_layer=1;g_dm_present_link=1;
    link_sync();active(probe,1,60);
    for(int iteration=0;iteration<1000;iteration++){
        fakeFG=2;link_sync();active(probe,2,120);
        fakeFG=1;link_sync();active(probe,1,60);
        fakeFG=0;fakeNative=30;link_sync();active(probe,1,30);
        fakeNative=60;link_sync();active(probe,1,60);
        link_sync();active(probe,1,60);
    }
    g_dm_present_link=0;link_sync();require(g_link==nil && !g_link_owns_layer && probe.invalidations==1,"classic takeover did not invalidate/release link");
    g_link_started=0;g_dm_present_link=1;link_sync();require(creations==1 && g_link_started && g_dm_present_link==1,"cold link start lost requested mode");
    fakeLegacy=1;g_dm_present_link=2;link_sync();require(g_dm_present_link==0,"legacy system must use classic presenter");
    puts("PASS: 1000 native30/native60/FG30-60/FG60-120 cycles; unchanged mode; classic takeover; cold start; legacy fallback");
}return 0;}

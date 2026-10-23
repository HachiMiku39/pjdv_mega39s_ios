// Host-independent checks of the real guest-service implementation and ABI.
#include <assert.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <math.h>
#define HLE_FORCE(symbol,description,ret,name,...) ret name(__VA_ARGS__)
#define LOG(...) ((void)0)
static unsigned deliveries;
static float delivered[2];
void pjdv_host_vibration_send(int32_t side,float low,float low_hz,float high,float high_hz){
    assert(side>=0 && side<=1);
    assert(isfinite(low) && low>=0 && low<=1 && isfinite(high) && high>=0 && high<=1);
    assert(isfinite(low_hz) && isfinite(high_hz));
    deliveries++;delivered[side]=fmaxf(low,high);
}
#include "pjdv_vibration.inc"
static void *race(void *side_ptr){
    int side=(int)(intptr_t)side_ptr;
    PjdvVibrationHandle h={3,0,side,0};
    for(int i=0;i<10000;i++){
        PjdvVibrationValue value={(i%100)/100.f,160,.4f,320},actual;
        h_hid_SendVib(&h,&value);h_hid_GetActualVib(&actual,&h);
        assert(actual.low>=0 && actual.low<=1 && actual.high==.4f);
    }
    return NULL;
}
int main(void){
    uint32_t id=0;
    struct { PjdvVibrationHandle h[2]; uint32_t guard; } out={.guard=0x12345678};
    assert(h_hid_VibPermit()==1);
    assert(h_hid_GetVibHandles(out.h,100,&id,1)==2 && out.guard==0x12345678);
    assert(out.h[0].style==3 && out.h[0].side==0 && out.h[1].side==1);
    PjdvVibrationHandle sentinel=out.h[1];
    assert(h_hid_GetVibHandles(out.h,1,&id,1)==1);
    assert(out.h[1].style==sentinel.style && out.h[1].side==sentinel.side);
    assert(h_hid_GetVibHandles(out.h,0,&id,1)==0);
    assert(h_hid_GetVibHandles(out.h,-1,&id,1)==0);
    assert(h_hid_GetVibHandles(NULL,2,&id,1)==0);
    id=1;assert(h_hid_GetVibHandles(out.h,2,&id,1)==0);
    id=0x20;assert(h_hid_GetVibHandles(out.h,2,&id,2)==2 && out.h[0].player==0x20);
    id=0;assert(h_hid_GetVibHandles(out.h,2,&id,1)==2);
    PjdvVibrationInfo info;
    for(int i=0;i<2;i++){
        h_hid_GetVibInfo(&info,&out.h[i]);assert(info.type==1 && info.position==i+1);
    }
    PjdvVibrationValue value={.2f,160,.8f,320},actual;
    h_hid_SendVib(&out.h[0],&value);assert(deliveries==0);
    h_hid_InitVib(&out.h[0]);h_hid_InitVib(&out.h[1]);
    h_hid_SendVib(&out.h[0],&value);assert(delivered[0]==.8f && deliveries==1);
    h_hid_GetActualVib(&actual,&out.h[0]);assert(actual.low==.2f && actual.high==.8f);
    h_hid_GetActualVib(&actual,&out.h[1]);assert(actual.low==0 && actual.high==0);
    value=(PjdvVibrationValue){NAN,INFINITY,4,-100};h_hid_SendVib(&out.h[1],&value);
    h_hid_GetActualVib(&actual,&out.h[1]);assert(actual.low==0 && actual.low_hz==160 && actual.high==1 && actual.high_hz==0);
    unsigned previous=deliveries;
    PjdvVibrationHandle invalid={3,0,2,0};h_hid_SendVib(&invalid,&value);assert(deliveries==previous);
    h_hid_SendVib(NULL,&value);h_hid_SendVib(&out.h[0],NULL);assert(deliveries==previous);
    pthread_t threads[4];
    for(int i=0;i<4;i++)assert(pthread_create(&threads[i],NULL,race,(void *)(intptr_t)(i%2))==0);
    for(int i=0;i<4;i++)pthread_join(threads[i],NULL);
    pjdv_vibration_session_end();assert(delivered[0]==0 && delivered[1]==0);
    previous=deliveries;h_hid_SendVib(&out.h[0],&value);assert(deliveries==previous);
    h_hid_GetActualVib(&actual,&out.h[0]);assert(actual.low==0 && actual.high==0);
    h_hid_InitVib(&out.h[0]);value=(PjdvVibrationValue){.3f,160,0,320};
    h_hid_SendVib(&out.h[0],&value);assert(delivered[0]==.3f);
    pjdv_vibration_session_end();
    puts("PASS: handle ABI/capacity, independent channels, initialization, finite bounds, concurrent sends, stop and session restart");
}

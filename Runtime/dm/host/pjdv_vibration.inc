// nn::hid vibration service boundary. Keep the guest's VibrationTarget mixer;
// convert its two-band output to ordinary GameController rumble in the host.
#include <math.h>
#include <stdlib.h>
#include <stdatomic.h>
typedef struct { uint8_t style, player, side, reserved; } PjdvVibrationHandle;
typedef struct { uint32_t type, position; } PjdvVibrationInfo;
typedef struct { float low, low_hz, high, high_hz; } PjdvVibrationValue;
_Static_assert(sizeof(PjdvVibrationHandle)==4,"VibrationDeviceHandle ABI");
_Static_assert(sizeof(PjdvVibrationInfo)==8,"VibrationDeviceInfo ABI");
_Static_assert(sizeof(PjdvVibrationValue)==16,"VibrationValue ABI");
extern void pjdv_host_vibration_send(int32_t,float,float,float,float);
static pthread_mutex_t vibration_lock=PTHREAD_MUTEX_INITIALIZER;
static PjdvVibrationValue vibration_values[2]={{0,160,0,320},{0,160,0,320}};
static unsigned vibration_initialized[2],vibration_trace;
static _Atomic unsigned vibration_api_trace[5],vibration_event_trace,vibration_reject_trace;
#ifndef PJDV_VIBRATION_ORIGIN
#define PJDV_VIBRATION_ORIGIN() 0ull
#endif
static int vibration_trace_api(unsigned index){return atomic_fetch_add(&vibration_api_trace[index],1)<16;}
static int vibration_side(const PjdvVibrationHandle *h){
    if(!h || h->reserved || h->side>1)return -1;
    if(h->style==4)return h->player==0x20?h->side:-1;
    return (h->style==3 || h->style==5) && h->player==0?h->side:-1;
}
static float vibration_finite(float f,float fallback,float maximum){
    return !isfinite(f)?fallback:f<0?0:f>maximum?maximum:f;
}
HLE_FORCE("_ZN2nn3hid20IsVibrationPermittedEv", "Host permits logical controller rumble", unsigned, h_hid_VibPermit, void){return 1;}
HLE_FORCE("_ZN2nn3hid25GetVibrationDeviceHandlesEPNS0_21VibrationDeviceHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE",
          "Two logical rumble channels, including before physical hot-plug", int, h_hid_GetVibHandles,
          PjdvVibrationHandle *out,int max,const uint32_t *id,uint32_t style){
    if(vibration_trace_api(0))LOG("PJDV vibration handles id=%#x style=%#x capacity=%d",id?*id:0xffff,style,max);
    if(!out || !id || max<=0)return 0;
    unsigned index=style==1?3:style==2?4:style==4?5:0;
    if(!index || (*id!=0 && *id!=0x20) || (index==4?*id!=0x20:*id!=0))return 0;
    int n=max<2?max:2;
    for(int i=0;i<n;i++)out[i]=(PjdvVibrationHandle){index,*id,i,0};
    return n;
}
HLE_FORCE("_ZN2nn3hid25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", "Initialize host rumble channel", void, h_hid_InitVib,const PjdvVibrationHandle *h){
    if(vibration_trace_api(1))LOG("PJDV vibration init style=%u player=%#x side=%u",h?h->style:0,h?h->player:0xff,h?h->side:0xff);
    int side=vibration_side(h);if(side<0)return;
    pthread_mutex_lock(&vibration_lock);vibration_initialized[side]=1;pthread_mutex_unlock(&vibration_lock);
}
HLE_FORCE("_ZN2nn3hid22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", "Logical LRA position; physical output is approximate rumble", void, h_hid_GetVibInfo,
          PjdvVibrationInfo *out,const PjdvVibrationHandle *h){
    if(!out)return;int side=vibration_side(h);
    *out=(PjdvVibrationInfo){side<0?0:1,side<0?0:(uint32_t)side+1};
    if(vibration_trace_api(2))LOG("PJDV vibration info side=%d type=%u position=%u",side,out->type,out->position);
}
HLE_FORCE("_ZN2nn3hid18SendVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", "Convert guest rumble to physical GameController output", void, h_hid_SendVib,
          const PjdvVibrationHandle *h,const PjdvVibrationValue *value){
    if(vibration_trace_api(3))LOG("PJDV vibration send style=%u player=%#x side=%u low=%.3f high=%.3f",h?h->style:0,h?h->player:0xff,h?h->side:0xff,value?value->low:0,value?value->high:0);
    int side=vibration_side(h);
    uint64_t origin=PJDV_VIBRATION_ORIGIN();
    // A reset from the original pattern setter precedes the next frame's pulse.
    // This observes the game event; it does not synthesize a button vibration.
    if(origin==0x681c20 && atomic_fetch_add(&vibration_event_trace,1)<48)
        LOG("PJDV vibration original-pattern side=%d style=%u",side,h?h->style:0);
    if(side<0 || !value){
        if(value && (value->low>0 || value->high>0) && atomic_fetch_add(&vibration_reject_trace,1)<16)
            LOG("PJDV vibration rejected invalid-handle origin=%#llx",origin);
        return;
    }
    PjdvVibrationValue v={vibration_finite(value->low,0,1),vibration_finite(value->low_hz,160,1250),
                         vibration_finite(value->high,0,1),vibration_finite(value->high_hz,320,1250)};
    pthread_mutex_lock(&vibration_lock);
    if(vibration_initialized[side]){
        vibration_values[side]=v;
        if((v.low>0 || v.high>0) && vibration_trace++<24)
            LOG("PJDV vibration guest side=%d low=%.3f@%.1f high=%.3f@%.1f",side,v.low,v.low_hz,v.high,v.high_hz);
        // The callback only enqueues/coalesces; never starts an engine here.
        pjdv_host_vibration_send(side,v.low,v.low_hz,v.high,v.high_hz);
    }else if((v.low>0 || v.high>0) && atomic_fetch_add(&vibration_reject_trace,1)<16){
        LOG("PJDV vibration rejected uninitialized side=%d origin=%#llx",side,origin);
    }
    pthread_mutex_unlock(&vibration_lock);
}
HLE_FORCE("_ZN2nn3hid23GetActualVibrationValueEPNS0_14VibrationValueERKNS0_21VibrationDeviceHandleE", "Last accepted logical value, not physical actuator telemetry", void, h_hid_GetActualVib,
          PjdvVibrationValue *out,const PjdvVibrationHandle *h){
    if(!out)return;int side=vibration_side(h);
    if(vibration_trace_api(4))LOG("PJDV vibration actual side=%d",side);
    pthread_mutex_lock(&vibration_lock);*out=side<0?(PjdvVibrationValue){0,160,0,320}:vibration_values[side];pthread_mutex_unlock(&vibration_lock);
}
void pjdv_vibration_session_end(void){
    pthread_mutex_lock(&vibration_lock);
    for(int i=0;i<2;i++){
        vibration_values[i]=(PjdvVibrationValue){0,160,0,320};vibration_initialized[i]=0;
        pjdv_host_vibration_send(i,0,160,0,320);
    }
    vibration_trace=0;atomic_store(&vibration_event_trace,0);atomic_store(&vibration_reject_trace,0);
    for(unsigned i=0;i<5;i++)atomic_store(&vibration_api_trace[i],0);
    pthread_mutex_unlock(&vibration_lock);
}

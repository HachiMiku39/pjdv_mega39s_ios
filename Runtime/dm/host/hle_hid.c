// Switch Npad/touch bridge with bounded read-only M39 v1.0.9 diagnostics.
#include "hle.h"
#include "dm_input.h"
#include <stdatomic.h>
#include <mach/mach.h>
enum { NPAD_HANDHELD=0x20, STYLE_FULLKEY=1, STYLE_HANDHELD=2, STYLE_JOYDUAL=4, ATTR_CONNECTED=1 };
typedef struct { int64_t sampling;uint64_t buttons;int32_t lx,ly,rx,ry;uint32_t attributes,pad; } NpadState;
_Static_assert(sizeof(NpadState)==0x28,"NpadState ABI");
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static NpadState current;
static uint64_t latch;
static _Atomic int64_t samples;
static _Atomic unsigned input_trace_count;
static _Atomic uint32_t supported_ids=0x101,supported_styles=7;
void dm_pad_set(uint64_t b,int32_t lx,int32_t ly,int32_t rx,int32_t ry) {
    pthread_mutex_lock(&lock);latch|=b&~current.buttons;
    if(b!=current.buttons && getenv("PJDV_INPUT_TRACE") && atomic_fetch_add(&input_trace_count,1)<96)
        LOG("PJDV input host buttons=%#llx",b);
    current.buttons=b;current.lx=lx;current.ly=ly;current.rx=rx;current.ry=ry;
    pthread_mutex_unlock(&lock);
}
void dm_input_set(uint64_t b,int32_t lx,int32_t ly,int32_t rx,int32_t ry){dm_pad_set(b,lx,ly,rx,ry);}
uint64_t dm_input_samples(void){return atomic_load(&samples);}
void hid_keys_init(void){}
static uint32_t style_of(uint32_t id){
    uint32_t ids=atomic_load(&supported_ids),styles=atomic_load(&supported_styles);
    // An external/full-key controller is valid in handheld operation mode too.
    // M39 requests player IDs 0..3; never force its input onto unrequested 0x20.
    // DualSense/Xbox use the full-key layout. The JoyDual A/B candidate did
    // not restore gameplay rumble; retain JoyDual only as a restricted fallback.
    if(id==0 && (ids&1))return styles&STYLE_FULLKEY?STYLE_FULLKEY:styles&STYLE_JOYDUAL?STYLE_JOYDUAL:0;
    if(id==NPAD_HANDHELD && (ids&0x100) && dm_opmode()==0 && (styles&STYLE_HANDHELD))return STYLE_HANDHELD;
    return 0;
}
static void fill(NpadState *s,uint32_t id,uint32_t style){
    memset(s,0,sizeof *s);s->sampling=atomic_fetch_add(&samples,1)+1;
    if(style_of(id)!=style)return;
    static uint64_t traced_buttons;
    pthread_mutex_lock(&lock);*s=current;s->buttons|=latch;latch=0;
    int changed=traced_buttons!=s->buttons;traced_buttons=s->buttons;pthread_mutex_unlock(&lock);
    // Attached handheld Joy-Cons expose both sides as connected and wired,
    // not just the aggregate IsConnected flag, which leaves both sides absent.
    s->sampling=atomic_load(&samples);s->attributes=style==STYLE_HANDHELD?0x3f:style==STYLE_JOYDUAL?0x15:ATTR_CONNECTED;
    if(changed && getenv("PJDV_INPUT_TRACE") && atomic_fetch_add(&input_trace_count,1)<96)
        LOG("PJDV input guest id=%#x style=%u buttons=%#llx attributes=%#x",id,style,s->buttons,s->attributes);
    if(s->lx<-16384)s->buttons|=1ull<<16;if(s->lx>16384)s->buttons|=1ull<<18;
    if(s->ly>16384)s->buttons|=1ull<<17;if(s->ly<-16384)s->buttons|=1ull<<19;
    if(s->rx<-16384)s->buttons|=1ull<<20;if(s->rx>16384)s->buttons|=1ull<<22;
    if(s->ry>16384)s->buttons|=1ull<<21;if(s->ry<-16384)s->buttons|=1ull<<23;
}
HLE_FORCE("_ZN2nn3hid14InitializeNpadEv", "连 hid 服务；宿主从 dm_input 取输入", void, h_hid_InitNpad, void) {
    LOG("PJDV vibration diagnostics v4 active (bounded; PJDV_VIB_TRACE=0 disables snapshots)");
}
HLE_FORCE("_ZN2nn3hid21InitializeTouchScreenEv", "连 hid 服务；触屏输入由前端另接", void, h_hid_InitTouch, void) {}
HLE_FORCE("_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm", "支持的手柄号；宿主固定", void, h_hid_SetIds, const uint32_t *ids, uint64_t n) {
    uint32_t mask=0;
    for(uint64_t i=0;ids && i<n && i<16;i++)if(ids[i]<8)mask|=1u<<ids[i];else if(ids[i]==NPAD_HANDHELD)mask|=0x100;
    atomic_store(&supported_ids,mask);
    if(getenv("PJDV_INPUT_TRACE")){for(uint64_t i=0;ids && i<n && i<16;i++)LOG("PJDV supported Npad id[%llu]=%#x",i,ids[i]);}
}
// BitFlagSet<32> 按值传在 w 寄存器
// BitFlagSet<32> is passed by value in a w register
HLE_FORCE("_ZN2nn3hid24SetSupportedNpadStyleSetENS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", "Honor requested controller styles for host input", void, h_hid_SetStyles, uint32_t styles) {
    atomic_store(&supported_styles,styles);
    if(getenv("PJDV_INPUT_TRACE"))LOG("PJDV supported Npad styles=%#x",styles);
}
HLE_FORCE("_ZN2nn3hid29SetNpadHandheldActivationModeENS0_26NpadHandheldActivationModeE", "掌机手柄激活方式；宿主固定", void, h_hid_SetHhMode, int m) { (void)m; }
HLE_FORCE("_ZN2nn3hid15GetNpadStyleSetERKj", "手柄样式查询；跟 DM_OPMODE 走", uint32_t, h_hid_GetStyle, const uint32_t *id) { return style_of(*id); }
// Read-only v1.0.9 diagnostics. Read through Mach so a retiring guest object
// cannot turn a diagnostic snapshot into a dangling-pointer access.
static int vibration_read(uintptr_t address,void *out,size_t size){
    vm_size_t got=0;
    return vm_read_overwrite(mach_task_self(),address,size,(vm_address_t)out,&got)==KERN_SUCCESS && got==size;
}
static void vibration_input_trace(const NpadState *s,uint32_t id,void *caller){
    // Keep diagnostics available after SpringBoard relaunch, which drops the
    // devicectl launch environment. Read-only, bounded, and explicitly opt-out.
    const char *trace=getenv("PJDV_VIB_TRACE");if(id || (trace && !strcmp(trace,"0")))return;
    module_t *m=module_of(caller);if(!m || strcmp(m->name,"main"))return;
    uint64_t origin=(uint64_t)caller-(uint64_t)m->base;
    unsigned route=(origin==0x67d104 || origin==0x67d224)?1:(origin==0x6ef8f4 || origin==0x6ef8b0)?0:2;
    if(route>1)return;
    static _Atomic uint64_t previous[2];static _Atomic unsigned changes[2],polls,snapshots;
    int changed=atomic_exchange(&previous[route],s->buttons)!=s->buttons;
    if(changed && atomic_fetch_add(&changes[route],1)<192)
        LOG("PJDV vibration input route=%u buttons=%#llx",route,s->buttons);
    // Input changes remain observable after the initial idle window. Periodic
    // snapshots cover up to 40 minutes, rather than ending before the song.
    unsigned poll=route==1?atomic_fetch_add(&polls,1):0;
    if(route!=1 || (!changed && poll%600) || atomic_fetch_add(&snapshots,1)>=512)return;
    uintptr_t base=(uintptr_t)m->base,active=0;uint8_t config[8]={0},context[0x34]={0},header[0x38]={0},units[0xa0]={0};
    int conf=vibration_read(base+0x4d243ec8,config,sizeof config);
    int ctx=vibration_read(base+0x4d2c9990,context,sizeof context);
    if(!vibration_read(base+0xbe395e20,&active,sizeof active) || !active)return;
    if(!vibration_read(active,header,sizeof header) || !vibration_read(active+0x98,units,sizeof units))return;
    uint32_t frame[2],duration[2],pattern[2];uint64_t vtable,active_buttons;memcpy(&vtable,header,8);memcpy(&active_buttons,header+0x18,8);
    for(unsigned i=0;i<2;i++){memcpy(&pattern[i],units+i*0x50+0x34,4);memcpy(&frame[i],units+i*0x50+0x38,4);memcpy(&duration[i],units+i*0x50+0x3c,4);}
    LOG("PJDV vibration state vtable=%#llx connected=%u buttons=%#llx enabled=%u/%u paused=%u/%u pattern=%u/%u frame=%u/%u duration=%u/%u config=%d:%u,%u,%u,%u,%u,%u context=%d:gate2c=%u mode=%u",
        vtable-base,header[0x28],active_buttons,units[0x4a],units[0x9a],units[0x49],units[0x99],pattern[0],pattern[1],frame[0],frame[1],duration[0],duration[1],
        conf,config[0],config[1],config[2],config[3],config[4],config[5],ctx,context[0x2c],context[4]);
}
HLE_FORCE("_ZN2nn3hid12GetNpadStateEPNS0_16NpadFullKeyStateERKj", "全键手柄状态；取 dm_input", void, h_hid_GetFullKey, NpadState *s, const uint32_t *id) {
    fill(s,*id,STYLE_FULLKEY);
    vibration_input_trace(s,*id,__builtin_return_address(0));
}
HLE_FORCE("_ZN2nn3hid12GetNpadStateEPNS0_17NpadHandheldStateERKj", "掌机手柄状态；取 dm_input", void, h_hid_GetHandheld, NpadState *s, const uint32_t *id) { fill(s, *id, STYLE_HANDHELD); }
HLE_FORCE("_ZN2nn3hid12GetNpadStateEPNS0_16NpadJoyDualStateERKj", "Paired-controller fallback when the game excludes full-key style", void, h_hid_GetJoyDual, NpadState *s, const uint32_t *id) { fill(s,*id,STYLE_JOYDUAL);vibration_input_trace(s,*id,__builtin_return_address(0)); }

// Arcade mode initializes motion even with button-only virtual input. There is
// currently no host IMU feed: expose an inactive, stationary orientation rather
// than enter Horizon's hid IPC service. Mix-mode motion remains unsupported.
typedef struct { uint64_t delta,sampling;float acceleration[3],velocity[3],angle[3],direction[9];uint32_t attributes,reserved; } SixAxisState;
_Static_assert(sizeof(SixAxisState)==0x60,"SixAxisSensorState ABI");
static void sixaxis_stationary(SixAxisState *s){
    memset(s,0,sizeof(*s));s->delta=16666667;s->sampling=guest_ns()/16666667;
    s->direction[0]=s->direction[4]=s->direction[8]=1;
}
HLE_FORCE("_ZN2nn3hid18StartSixAxisSensorERKNS0_19SixAxisSensorHandleE", "Virtual input has no IMU; retain inactive stationary motion", void, h_hid_StartSixAxis, const uint32_t *h){
    (void)h;static _Atomic int reported;if(!atomic_exchange(&reported,1))LOG("PJDV motion: inactive stationary fallback; no host IMU input");
}
HLE_FORCE("_ZN2nn3hid17StopSixAxisSensorERKNS0_19SixAxisSensorHandleE", "No host IMU session to stop", void, h_hid_StopSixAxis, const uint32_t *h){(void)h;}
HLE_FORCE("_ZN2nn3hid22GetSixAxisSensorStatesEPNS0_18SixAxisSensorStateEiRKNS0_19SixAxisSensorHandleE", "Inactive stationary sample for button-only input", int, h_hid_GetSixAxisStates, SixAxisState *out,int n,const uint32_t *h){
    (void)h;if(n<1 || !out)return 0;sixaxis_stationary(out);return 1;
}
HLE_FORCE("_ZN2nn3hid21GetSixAxisSensorStateEPNS0_18SixAxisSensorStateERKNS0_19SixAxisSensorHandleE", "Inactive stationary sample for button-only input", void, h_hid_GetSixAxisState, SixAxisState *out,const uint32_t *h){(void)h;sixaxis_stationary(out);}
HLE_FORCE("_ZN2nn3hid21IsSixAxisSensorAtRestERKNS0_19SixAxisSensorHandleE", "No host IMU feed; stationary", unsigned, h_hid_SixAxisAtRest,const uint32_t *h){(void)h;return 1;}

static uint64_t vibration_origin(void *caller){
    module_t *m=module_of(caller);
    return m && !strcmp(m->name,"main")?(uint64_t)caller-(uint64_t)m->base:0;
}
#define PJDV_VIBRATION_ORIGIN() vibration_origin(__builtin_return_address(0))
#include "pjdv_vibration.inc"

// 触屏：nn::hid::TouchScreenState<16> = { int64 sampling; int32 count; int32 _r; TouchState touches[16]（各 0x28） }
// 内容由 hle_touch.c 按前端推来的触点填（布局与短按锁存见该文件）；游戏只看第 0 份，返回写入的状态份数 1
// Touchscreen: nn::hid::TouchScreenState<16> = { int64 sampling; int32 count; int32 _r; TouchState touches[16] (0x28 each) }
// Contents are filled by hle_touch.c from the touch points pushed by the front end (see that file for the layout and the short-press latch); the game only looks at entry 0, returns the number of states written, 1
typedef struct { int64_t sampling; int32_t count, _r; uint8_t touches[16][0x28]; } TouchState16;
_Static_assert(sizeof(TouchState16) == 0x290, "TouchScreenState<16>");
int touch_fill(void *out, uint64_t now_ns);
HLE_FORCE("_ZN2nn3hid20GetTouchScreenStatesILm16EEEiPNS0_16TouchScreenStateIXT_EEEi", "触屏状态：前端触点（hle_touch.c）", int, h_hid_GetTouch, TouchState16 *out, int n) {
    if (n < 1) return 0;
    touch_fill(out, guest_ns());
    return 1;
}

// M39 uses the single newest state with a four-touch inline array (0xb0 bytes).
extern int touch_fill_capacity(void *,unsigned,uint64_t);
HLE_FORCE("_ZN2nn3hid19GetTouchScreenStateILm4EEEvPNS0_16TouchScreenStateIXT_EEE", "M39 four-finger touch state from front-end", void, h_hid_GetTouch4, void *out) {
    touch_fill_capacity(out,4,now_ns());
}

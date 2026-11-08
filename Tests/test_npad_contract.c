#ifndef PJDV_HID_SOURCE
#define PJDV_HID_SOURCE "../Runtime/dm/host/hle_hid.c"
#endif
#include PJDV_HID_SOURCE
static int mode;
module_t *module_of(const void *p){(void)p;return NULL;}
void pjdv_host_vibration_send(int32_t side,float low,float low_hz,float high,float high_hz){(void)side;(void)low;(void)low_hz;(void)high;(void)high_hz;}
void pjdv_profile_input_poll(void *caller){(void)caller;}
int dm_opmode(void){return mode;}
uint64_t now_ns(void){return 1000000000;}
uint64_t guest_ns(void){return now_ns();}
int touch_fill(void *out,uint64_t t){(void)out;(void)t;return 0;}
int touch_fill_capacity(void *out,unsigned n,uint64_t t){(void)out;(void)n;(void)t;return 0;}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Npad failure line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void){
 uint32_t handheld=0x20,player=0;NpadState state;
 h_hid_SetIds(&handheld,1);
 CHECK(h_hid_GetStyle(&handheld)==STYLE_HANDHELD);
 dm_pad_set(1,0,0,0,0);dm_pad_set(0,0,0,0,0);
 h_hid_GetFullKey(&state,&player);CHECK(state.buttons==0 && state.attributes==0);
 h_hid_GetHandheld(&state,&handheld);CHECK(state.buttons==1 && state.attributes==0x3f);
 int64_t first=state.sampling;
 h_hid_GetHandheld(&state,&handheld);CHECK(state.buttons==0 && state.sampling>first);
 uint32_t requested[]={0,1,2,3};h_hid_SetIds(requested,4);
 CHECK(h_hid_GetStyle(&player)==STYLE_FULLKEY && h_hid_GetStyle(&handheld)==STYLE_HANDHELD);
 dm_pad_set(2,0,0,0,0);dm_pad_set(0,0,0,0,0);
 h_hid_GetJoyDual(&state,&player);CHECK(state.buttons==0 && state.attributes==0);
 h_hid_GetFullKey(&state,&player);CHECK(state.buttons==2 && state.attributes==ATTR_CONNECTED);
 h_hid_GetFullKey(&state,&player);CHECK(state.buttons==0);
 // Touch Play selects the handheld (0x20) input object even when the host
 // uses the original docked graphics profile. Its connection gates scoring,
 // separately from the touch samples that animate the on-screen lanes.
 mode=1;
 uint32_t both[]={0,0x20};h_hid_SetIds(both,2);
 CHECK(h_hid_GetStyle(&player)==STYLE_FULLKEY);
 CHECK(h_hid_GetStyle(&handheld)==STYLE_HANDHELD);
 dm_pad_set(1,0,0,0,0);
 h_hid_GetHandheld(&state,&handheld);CHECK(state.buttons==1 && state.attributes==0x3f);
 h_hid_GetFullKey(&state,&player);CHECK(state.buttons==1 && state.attributes==ATTR_CONNECTED);
 dm_pad_set(0,0,0,0,0);
 h_hid_GetHandheld(&state,&handheld);CHECK(state.buttons==0 && state.attributes==0x3f);
 h_hid_SetStyles(STYLE_FULLKEY);
 CHECK(h_hid_GetStyle(&handheld)==0);
 h_hid_GetHandheld(&state,&handheld);CHECK(state.buttons==0 && state.attributes==0);
 h_hid_SetStyles(7);h_hid_SetIds(requested,4);
 CHECK(h_hid_GetStyle(&handheld)==STYLE_HANDHELD); // integrated Touch Play device
 h_hid_GetHandheld(&state,&handheld);CHECK(state.attributes==0x3f);
 h_hid_SetIds(NULL,0);CHECK(h_hid_GetStyle(&handheld)==0 && h_hid_GetStyle(&player)==0);
 h_hid_SetIds(requested,4);
 CHECK(h_hid_GetStyle(&player)==STYLE_FULLKEY);
 h_hid_SetStyles(STYLE_FULLKEY);CHECK(h_hid_GetStyle(&player)==STYLE_FULLKEY);
 dm_pad_set(1ull<<6,0,0,0,0);
 h_hid_GetFullKey(&state,&player);CHECK(state.buttons==(1ull<<6) && state.attributes==ATTR_CONNECTED);
 dm_pad_set(0,0,0,0,0);
 h_hid_SetStyles(STYLE_JOYDUAL);CHECK(h_hid_GetStyle(&player)==STYLE_JOYDUAL);
 h_hid_GetJoyDual(&state,&player);CHECK(state.attributes==0x15);
 h_hid_SetStyles(STYLE_FULLKEY|STYLE_JOYDUAL);CHECK(h_hid_GetStyle(&player)==STYLE_FULLKEY);
 h_hid_SetStyles(0);CHECK(h_hid_GetStyle(&player)==0);
 h_hid_GetJoyDual(&state,&player);CHECK(state.buttons==0 && state.attributes==0);
 uint32_t other=1;CHECK(h_hid_GetStyle(&other)==0);
 puts("Npad contract passed: ABI, handheld side connections, requested IDs/styles, docked-quality integrated Touch Play, full-key and paired-controller fallback, invalid-style/empty-ID isolation, short-tap latch and release");return 0;
}

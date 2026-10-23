#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "front.h"
extern int touch_fill_capacity(void *,unsigned,uint64_t);
static uint32_t u32(const uint8_t *p) { uint32_t n; memcpy(&n,p,4); return n; }
int main(void) {
    struct { uint8_t before[16], state[0xb0], after[16]; } guarded;
    memset(&guarded,0xa5,sizeof guarded);
    dm_touch taps[5]={{0,.25f,.5f},{1,.5f,.25f},{2,.75f,.5f},{3,1,1},{4,0,0}};
    dm_touch_set(taps,5);
    assert(touch_fill_capacity(guarded.state,4,100)==4);
    for(int i=0;i<16;i++)assert(guarded.before[i]==0xa5 && guarded.after[i]==0xa5);
    assert(u32(guarded.state+8)==4);
    assert(u32(guarded.state+0x20)==320 && u32(guarded.state+0x24)==360);
    assert(u32(guarded.state+0x10+3*0x28+0x10)==1279);
    assert(u32(guarded.state+0x10+3*0x28+0x14)==719);
    for(int i=0;i<4;i++)assert(u32(guarded.state+0x10+i*0x28+8)==1);
    dm_touch_set(NULL,0);
    assert(touch_fill_capacity(guarded.state,4,200)==4);
    for(int i=0;i<4;i++)assert(u32(guarded.state+0x10+i*0x28+8)==2);
    // The fifth touch was never emitted: preserve its short tap until a slot frees.
    assert(touch_fill_capacity(guarded.state,4,300)==1);
    assert(u32(guarded.state+0x18)==1 && u32(guarded.state+0x1c)==4);
    assert(touch_fill_capacity(guarded.state,4,400)==1);
    assert(u32(guarded.state+0x18)==2);
    assert(touch_fill_capacity(guarded.state,4,500)==0);
    puts("Native four-touch tests passed: bounds, coordinates, short-tap latch, overflow queue, release");
}

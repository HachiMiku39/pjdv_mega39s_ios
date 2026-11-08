#include <assert.h>
#include "hle.h"
// Exercise the real service functions without retaining every unrelated HLE
// registration (audio/lifecycle/exit workers are outside this contract).
#undef HLE_FORCE
#define HLE_FORCE(mangled, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#ifndef PJDV_OE_SOURCE
#define PJDV_OE_SOURCE "../Runtime/dm/host/hle_oe.c"
#endif
#include PJDV_OE_SOURCE
uint64_t g_t0_ns;
uint64_t now_ns(void){return 1000000000;}
int main(void) {
    setenv("DM_OPMODE","1",1);
#if defined(DM_GAME_M39)
    assert(h_oe_GetOpMode()==0 && h_oe_GetPerfMode()==1);
    dm_set_opmode(0);assert(h_oe_GetOpMode()==0 && h_oe_GetPerfMode()==0);
    dm_set_opmode(1);assert(h_oe_GetOpMode()==0 && h_oe_GetPerfMode()==1);
    pjdv_oe_session_end();
    assert(h_oe_GetOpMode()==0 && h_oe_GetPerfMode()==1);
    puts("M39 operation contract passed: touch-capable operation, independent high/low performance profile, session reset");
#else
    assert(h_oe_GetOpMode()==1 && h_oe_GetPerfMode()==1);
    dm_oe_ui_opmode(0);assert(h_oe_GetOpMode()==0 && h_oe_GetPerfMode()==1);
    dm_oe_ui_opmode(-1);assert(h_oe_GetOpMode()==1 && h_oe_GetPerfMode()==1);
    dm_set_opmode(0);assert(h_oe_GetOpMode()==0 && h_oe_GetPerfMode()==0);
    puts("Shared operation contract passed: original operation/performance and UI override retained");
#endif
}

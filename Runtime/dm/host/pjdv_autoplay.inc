// One offline, fingerprinted call-site gate; no runtime executable writes.
// Off: forward the unchanged four arguments to the original judgment function.
// On: the original group/effect/score pipeline consumes diagnostic COOL hits.
// The host MUST select a disposable save before enabling this session flag.
#include "pjdv_autoplay.h"
#include <stdatomic.h>
static _Atomic int autoplay_enabled;
static _Atomic uint64_t autoplay_cool_count;
void pjdv_autoplay_configure(int enabled) {
    atomic_store(&autoplay_cool_count, 0);
    atomic_store(&autoplay_enabled, enabled == 1);
}
uint64_t pjdv_autoplay_hits(void) { return atomic_load(&autoplay_cool_count); }
static uint64_t pjdv_autoplay_judge(uint64_t *r, uint64_t caller) {
    module_t *m = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) m = &g_mod[i];
    if (!m || caller != 0x1af6a4) die("M39 autoplay gate at unexpected caller");
    typedef int (*judge_fn)(void *, void *, uint16_t, uint16_t);
    if (!atomic_load(&autoplay_enabled))
        return (uint32_t)((judge_fn)(m->base + 0x1b11f0))((void *)r[0], (void *)r[1], r[2], r[3]);
    uint8_t *game = (void *)r[0], *target = (void *)r[1];
    if (!game || !target) return PJDV_AUTO_PENDING;
    // Verified by the original getter at main+1a4540, not the PC layout.
    uint8_t *pv = m->base + 0x4d285788;
    int32_t type; float remaining;
    memcpy(&type, target + 0x14, 4); memcpy(&remaining, target + 0x18, 4);
    int result = pjdv_auto_judgment(game[0] && pv[0], pv[1], type, remaining);
    // Original prologue clears this per-target scratch result before grading.
    uint16_t *scratch; memcpy(&scratch, m->base + 0xcdf608, sizeof scratch);
    *scratch = 0;
    if (result == PJDV_AUTO_COOL) {
        float exact = 0; memcpy(target + 0x1c, &exact, 4);
        uint64_t n = atomic_fetch_add(&autoplay_cool_count, 1) + 1;
        if (n <= 4 || n % 256 == 0) LOG("PJDV AutoPlay COOL hits=%llu type=%d (disposable save)", n, type);
    }
    return result;
}

// Independent JP 1.0.9 diagnostic judgment policy. This is not a score editor.
#ifndef PJDV_AUTOPLAY_H
#define PJDV_AUTOPLAY_H
#include <math.h>
enum { PJDV_AUTO_COOL = 0, PJDV_AUTO_PENDING = 21 };
static inline int pjdv_auto_judgment(int playing, int paused, int type, float remaining) {
    // The guest supplies time relative to the note. Do not advance its clock,
    // erase the chart, or invent hits for unrecognized/custom note types.
    if (!playing || paused || type < 0 || type > 24 || !isfinite(remaining))
        return PJDV_AUTO_PENDING;
    return remaining <= 0 ? PJDV_AUTO_COOL : PJDV_AUTO_PENDING;
}
#endif

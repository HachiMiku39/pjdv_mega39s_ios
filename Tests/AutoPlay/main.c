#include <assert.h>
#include <stdio.h>
#include "pjdv_autoplay.h"
int main(void) {
    for (int type = 0; type <= 24; type++) {
        assert(pjdv_auto_judgment(1, 0, type, .001f) == 21);
        assert(pjdv_auto_judgment(1, 0, type, 0) == 0);
        assert(pjdv_auto_judgment(1, 0, type, -.02f) == 0);
        assert(pjdv_auto_judgment(1, 1, type, 0) == 21);
        assert(pjdv_auto_judgment(0, 0, type, 0) == 21);
    }
    assert(pjdv_auto_judgment(1, 0, -1, 0) == 21);
    assert(pjdv_auto_judgment(1, 0, 25, 0) == 21);
    assert(pjdv_auto_judgment(1, 0, 0, NAN) == 21);
    assert(pjdv_auto_judgment(1, 0, 0, INFINITY) == 21);
    puts("AutoPlay timing/paused/unknown target checks passed; real-game validation separate");
}

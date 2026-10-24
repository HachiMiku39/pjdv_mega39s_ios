#include <assert.h>
#include <stdio.h>
#include "pjdv_fg_policy.h"
int main(void) {
    // Integration invariants: one real frame + one midpoint per source period.
    // A 60Hz callback fallback must still have a 60Hz NVN source budget.
    for(int mode=1;mode<=2;mode++) {
        int source=pjdv_fg_source_hz(mode),output=pjdv_fg_output_hz(mode);
        assert(output==source*2);
        assert(1000000000ull/source==(mode==1?33333333ull:16666666ull));
        assert(pjdv_fg_link_mode(mode)==mode);
    }
    assert(pjdv_fg_source_hz(0)==60);
    puts("Source30/display60 and source60/display120 pacing invariants: PASS");
}

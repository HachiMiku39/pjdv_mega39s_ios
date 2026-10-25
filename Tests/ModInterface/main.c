#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pjdv_mod_interface.h"
static unsigned callback_calls;
static pjdv_mod_result forbidden_callback(void *ctx, const pjdv_mod_read_request_v1 *r,
                                        char *out, size_t n) {
    (void)ctx; (void)r; (void)out; (void)n; callback_calls++;
    return PJDV_MOD_RESOLVED;
}
int main(void) {
    setenv("PJDV_MODS", "1", 1); /* Cannot turn on the reserved seam. */
    pjdv_mod_provider_v1 p = {1, sizeof(p), PJDV_MOD_CAP_READONLY_ASSETS |
        PJDV_MOD_CAP_DATABASE_EXTENSION, 0, NULL, forbidden_callback};
    assert(pjdv_mod_install_provider_v1(NULL) == PJDV_MOD_INVALID_ARGUMENT);
    p.abi_version=2;
    assert(pjdv_mod_install_provider_v1(&p) == PJDV_MOD_UNSUPPORTED_ABI);
    p.abi_version=1; p.struct_size--;
    assert(pjdv_mod_install_provider_v1(&p) == PJDV_MOD_UNSUPPORTED_ABI);
    p.struct_size=sizeof(p);
    assert(pjdv_mod_install_provider_v1(&p) == PJDV_MOD_DISABLED);
    const char *paths[] = {"/rom/objset/model.farc", "../GuestSave/pl.dat", "", "/mods/config.toml"};
    for (unsigned i=0;i<100000;i++) {
        char out[64], before[64];memset(out, 0xa5, sizeof(out));memcpy(before,out,sizeof(out));
        pjdv_mod_read_request_v1 r={1,sizeof(r),"rom",paths[i%4]};
        errno=EINTR;
        assert(pjdv_mod_try_resolve_readonly_v1(&r,out,sizeof(out)) == PJDV_MOD_DISABLED);
        assert(errno==EINTR && !memcmp(out,before,sizeof(out)));
    }
    assert(pjdv_mod_try_resolve_readonly_v1(NULL,NULL,0)==PJDV_MOD_DISABLED);
    pjdv_mod_status_v1 s=pjdv_mod_get_status_v1();
    assert(s.abi_version==1 && s.struct_size==sizeof(s));
    assert(s.enabled_capabilities==0 && s.active_provider_count==0 && callback_calls==0);
    puts("MOD ABI: activation refused, no callback, output/errno preserved (100000 queries)");
}

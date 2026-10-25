#include "pjdv_mod_interface.h"

pjdv_mod_status_v1 pjdv_mod_get_status_v1(void) {
    return (pjdv_mod_status_v1){PJDV_MOD_ABI_VERSION, sizeof(pjdv_mod_status_v1), 0, 0};
}
pjdv_mod_result pjdv_mod_install_provider_v1(const pjdv_mod_provider_v1 *provider) {
    if (!provider) return PJDV_MOD_INVALID_ARGUMENT;
    if (provider->abi_version != PJDV_MOD_ABI_VERSION ||
        provider->struct_size != sizeof(pjdv_mod_provider_v1))
        return PJDV_MOD_UNSUPPORTED_ABI;
    return PJDV_MOD_DISABLED;
}
pjdv_mod_result pjdv_mod_try_resolve_readonly_v1(
    const pjdv_mod_read_request_v1 *request, char *host_path, size_t capacity) {
    /* Intentionally no provider registry, filesystem access, allocation,
     * preferences or environment-variable switch. Enabling requires new code. */
    (void)request; (void)host_path; (void)capacity;
    return PJDV_MOD_DISABLED;
}

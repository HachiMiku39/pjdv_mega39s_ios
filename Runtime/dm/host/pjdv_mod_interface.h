#ifndef PJDV_MOD_INTERFACE_H
#define PJDV_MOD_INTERFACE_H
/* PJDV-owned extension ABI reservation. No upstream plugin implementation.
 * build18 never scans, loads or executes MODs. See Reports/MOD-INTERFACE-build18.md. */
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define PJDV_MOD_ABI_VERSION 1u

typedef enum {
    PJDV_MOD_DISABLED = 0,
    PJDV_MOD_RESOLVED = 1,
    PJDV_MOD_INVALID_ARGUMENT = -1,
    PJDV_MOD_UNSUPPORTED_ABI = -2
} pjdv_mod_result;

enum {
    PJDV_MOD_CAP_READONLY_ASSETS = 1u << 0,
    PJDV_MOD_CAP_DATABASE_EXTENSION = 1u << 1
};

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t enabled_capabilities; /* Always zero in build18. */
    uint32_t active_provider_count; /* Always zero in build18. */
} pjdv_mod_status_v1;

/* Borrowed inputs, valid only for the duration of a query. Future providers
 * must be immutable per game session and use a fingerprint-verified target.
 * A read query is never a save/temp write or a debug-output redirection. */
typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    const char *mount_name;
    const char *relative_path;
} pjdv_mod_read_request_v1;

typedef pjdv_mod_result (*pjdv_mod_read_resolver_v1)(
    void *context, const pjdv_mod_read_request_v1 *request,
    char *host_path, size_t host_path_capacity);

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t requested_capabilities;
    uint32_t reserved;
    void *context;
    pjdv_mod_read_resolver_v1 resolve_readonly;
} pjdv_mod_provider_v1;

pjdv_mod_status_v1 pjdv_mod_get_status_v1(void);
/* Always refuses activation in build18; does not retain or invoke callbacks. */
pjdv_mod_result pjdv_mod_install_provider_v1(const pjdv_mod_provider_v1 *provider);
/* DISABLED leaves output bytes and errno untouched, so existing base resource
 * resolution, overlays, aliases and caches proceed exactly as before. */
pjdv_mod_result pjdv_mod_try_resolve_readonly_v1(
    const pjdv_mod_read_request_v1 *request, char *host_path, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif

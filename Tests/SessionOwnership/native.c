#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Atomic int session_phase, autoplay;
static char status_text[128], save_path[4096];
static int fail_next_thread;
static void stage(const char *s) { strlcpy(status_text, s, sizeof status_text); }
static void *guest_boot_thread(void *unused) { abort(); }
static int test_create(pthread_t *thread, const pthread_attr_t *attr, void *(*entry)(void *), void *args);
#define pthread_create test_create
#define pthread_detach(thread) ((void)0)
#include "boot_under_test.inc"

static int test_create(pthread_t *thread, const pthread_attr_t *attr, void *(*entry)(void *), void *args) {
    guest_boot_args *a = args;
    strlcpy(save_path, a->path[2], sizeof save_path);
    if (fail_next_thread) { fail_next_thread = 0; return EAGAIN; }
    boot_args_free(a);
    atomic_store(&session_phase, 2);
    return 0;
}

int pjdv_guest_load(char *err, size_t size) { return 1; }
int pjdv_guest_math_probe(void) { return 1; }
int pjdv_guest_autoplay_supported(void) { return 1; }
void pjdv_autoplay_configure(int v) { atomic_store(&autoplay, v); }
void pjdv_guest_state(char *out, size_t n) { strlcpy(out, status_text, n); }
void dm_pad_set(uint64_t b, int32_t l, int32_t ly, int32_t r, int32_t ry) {}
void dm_touch_set(const void *touches, int count) {}
void dm_touch_reset(void) {}
int test_autoplay(void) { return atomic_load(&autoplay); }
int test_phase(void) { return atomic_load(&session_phase); }
const char *test_save_path(void) { return save_path; }
void test_end_native(void) { atomic_store(&session_phase, 0); }
void test_fail_boot(void) { fail_next_thread = 1; }

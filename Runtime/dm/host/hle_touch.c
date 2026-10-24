// 触屏：前端整组推触点（dm_touch_set，front.h），游戏每帧经 nn::hid::GetTouchScreenStates 读（hle_hid.c → touch_fill）。
// 游戏的读法（main 0x1b65260）：清 16 份状态、要 16 份，只看第 0 份——触点数与各触点的 finger_id / x / y；面板坐标系 1280x720
// （它在同一函数里写常量 0x2d0_00000500 = 720 << 32 | 1280）。所以：
//   · 前端归一化坐标 [0,1)（出图画面左上为原点）→ x = nx·1280、y = ny·720，夹到 [0,1279] / [0,719]；
//   · 短按锁存：游戏只看最新一份，两次读之间按下又抬起的手指若不锁存会整个丢掉——本表每根手指先以 Start 报一次，
//     抬起后再以 End 报一次才释放（两次读之间按下又抬起 = 这次报 Start、下次报 End）。
// TouchState（0x28 字节，= libnx HidTouchState）：+0 delta_time（ns，i64）、+8 属性（bit0 Start / bit1 End）、+0xc finger_id、
// +0x10 x、+0x14 y、+0x18 直径 x、+0x1c 直径 y、+0x20 转角、+0x24 保留。TouchScreenState<16>：+0 采样号、+8 触点数、+0x10 起 16 个 TouchState。
// Touchscreen: the front end pushes the whole set of touch points (dm_touch_set, front.h), and the game reads them every frame through nn::hid::GetTouchScreenStates (hle_hid.c → touch_fill).
// How the game reads (main 0x1b65260): it clears 16 states, asks for 16, and looks only at state 0 -- the touch count and each touch point's finger_id / x / y; the panel coordinate system is 1280x720
// (it writes the constant 0x2d0_00000500 = 720 << 32 | 1280 in the same function). Therefore:
//   · front-end normalized coordinates [0,1) (origin at the top left of the output picture) → x = nx·1280, y = ny·720, clamped to [0,1279] / [0,719];
//   · short-press latch: the game only looks at the newest state, so a finger pressed and lifted between two reads would be lost entirely without a latch -- in this table every finger is first reported once as Start,
//     and is released only after being reported once more as End after lifting (pressed and lifted between two reads = Start in this report, End in the next).
// TouchState (0x28 bytes, = libnx HidTouchState): +0 delta_time (ns, i64), +8 attributes (bit0 Start / bit1 End), +0xc finger_id,
// +0x10 x, +0x14 y, +0x18 diameter x, +0x1c diameter y, +0x20 rotation angle, +0x24 reserved. TouchScreenState<16>: +0 sample number, +8 touch count, 16 TouchState from +0x10.
#include "dm.h"
#include "front.h"
#include <pthread.h>
#include <math.h>
// Keep distinct strokes until the guest has observed Start and End. UIKit may
// reuse a released slot before the next game poll; a single "again" bit loses
// these taps. Movement is coalesced within a stroke, never across two presses.
enum { TOUCH_STROKES = 16 };
typedef struct { int reported, ended; float sx, sy, x, y; } touch_stroke;
static struct {
    int down, accepted;
    unsigned head, count;
    touch_stroke strokes[TOUCH_STROKES];
} g_f[16];
static pthread_mutex_t g_tl = PTHREAD_MUTEX_INITIALIZER;
static int64_t g_tsamp; static uint64_t g_tlast_ns;

void dm_touch_reset(void) {
    pthread_mutex_lock(&g_tl);
    memset(g_f, 0, sizeof g_f); // cancellation must not replay queued taps later
    pthread_mutex_unlock(&g_tl);
}
void dm_touch_set(const dm_touch *t, int n) {
    if (!t || n < 0) n = 0;
    if (n > 16) n = 16;
    pthread_mutex_lock(&g_tl);
    int seen[16] = {0};
    for (int i = 0; i < n; i++) {
        uint32_t id = t[i].id;
        if (id >= 16 || !isfinite(t[i].x) || !isfinite(t[i].y)) continue;
        seen[id] = 1;
        if (!g_f[id].down) {
            g_f[id].down = 1;
            // Bounded backpressure: do not corrupt an earlier stroke if the
            // consumer has stopped polling and the ring is full.
            g_f[id].accepted = g_f[id].count < TOUCH_STROKES;
            if (g_f[id].accepted) {
                unsigned tail = (g_f[id].head + g_f[id].count++) % TOUCH_STROKES;
                g_f[id].strokes[tail] = (touch_stroke){.sx=t[i].x,.sy=t[i].y,.x=t[i].x,.y=t[i].y};
            }
        }
        if (g_f[id].accepted && g_f[id].count) {
            unsigned tail = (g_f[id].head + g_f[id].count - 1) % TOUCH_STROKES;
            g_f[id].strokes[tail].x = t[i].x; g_f[id].strokes[tail].y = t[i].y;
        }
    }
    for (int id = 0; id < 16; id++) if (!seen[id] && g_f[id].down) {
        if (g_f[id].accepted && g_f[id].count) {
            unsigned tail = (g_f[id].head + g_f[id].count - 1) % TOUCH_STROKES;
            g_f[id].strokes[tail].ended = 1;
        }
        g_f[id].down = g_f[id].accepted = 0;
    }
    pthread_mutex_unlock(&g_tl);
}

static int32_t clampi(float v, int hi) { int32_t r = (int32_t)(v * (float)(hi + 1)); return r < 0 ? 0 : r > hi ? hi : r; }
// 填一份 TouchScreenState<16>（out 按 0x290 字节）；now_ns 用于 delta_time。返回写入的触点数
// Fill one TouchScreenState<16> (out is 0x290 bytes); now_ns is used for delta_time. Returns the number of touch points written
int touch_fill_capacity(void *out, unsigned capacity, uint64_t now_ns) {
    if (capacity < 1 || capacity > 16) die("Invalid touch state capacity");
    uint8_t *o = out; memset(o, 0, 0x10 + capacity * 0x28);
    pthread_mutex_lock(&g_tl);
    int64_t samp = ++g_tsamp; int64_t dt = g_tlast_ns ? (int64_t)(now_ns - g_tlast_ns) : 0; g_tlast_ns = now_ns;
    int k = 0;
    for (int id = 0; id < 16; id++) {
        if (!g_f[id].count || k >= (int)capacity) continue;
        touch_stroke *stroke = &g_f[id].strokes[g_f[id].head];
        uint32_t attr = !stroke->reported ? 1 : stroke->ended ? 2 : 0;
        stroke->reported = 1;
        uint8_t *s = o + 0x10 + 0x28 * k++;
        float px = attr & 1 ? stroke->sx : stroke->x, py = attr & 1 ? stroke->sy : stroke->y;
        int32_t x = clampi(px, 1279), y = clampi(py, 719), d = 30, zero = 0, fid = id;
        memcpy(s + 0x00, &dt, 8); memcpy(s + 0x08, &attr, 4); memcpy(s + 0x0c, &fid, 4);
        memcpy(s + 0x10, &x, 4); memcpy(s + 0x14, &y, 4); memcpy(s + 0x18, &d, 4); memcpy(s + 0x1c, &d, 4); memcpy(s + 0x20, &zero, 4);
        if (attr & 2) { g_f[id].head = (g_f[id].head + 1) % TOUCH_STROKES; g_f[id].count--; }
    }
    pthread_mutex_unlock(&g_tl);
    int32_t cnt = k; memcpy(o + 0, &samp, 8); memcpy(o + 8, &cnt, 4);
    // DM_TOUCH_LOG=1（验收诊断）：非 0 触点的读逐次记一行——采样号、触点数、各点 finger_id / 面板 x,y / 属性（1 Start、2 End）；封顶 500 行
    // DM_TOUCH_LOG=1 (acceptance diagnostics): each read with non-zero touch points logs one line -- sample number, touch count, and for each point finger_id / panel x,y / attributes (1 Start, 2 End); capped at 500 lines
    static int lg = -1, nl; if (lg < 0) lg = getenv("DM_TOUCH_LOG") != NULL;
    if (lg && k && nl < 500) {
        char b[256]; int m = snprintf(b, sizeof b, "触屏读 采样 %lld 触点 %d", (long long)samp, k);
        for (int i = 0; i < k && m < (int)sizeof b - 40; i++) { int32_t v[4]; memcpy(v, o + 0x10 + 0x28 * i + 0x08, 16);
            m += snprintf(b + m, sizeof b - m, " | #%d (%d,%d) 属性 %d", v[1], v[2], v[3], v[0]); }
        LOG("%s", b); if (++nl == 500) LOG("DM_TOUCH_LOG 满 500 行，停记");
    }
    return k;
}

int touch_fill(void *out, uint64_t now_ns) { return touch_fill_capacity(out,16,now_ns); }

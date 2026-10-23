// nn::time：真机经 time 服务取网络校准的用户时钟；宿主直接取系统时钟（单机、离线）。
// 布局按公开 Horizon ABI：PosixTime = int64 秒；CalendarTime = {s16 年, s8 月/日/时/分/秒}；
// CalendarAdditionalInfo = {u32 星期, u32 年内日, char 时区名[8], u32 夏令时, s32 UTC 偏移秒}。
// nn::time: a real device gets the network-calibrated user clock through the time service; the host reads the system clock directly (single machine, offline).
// Layout follows the public Horizon ABI: PosixTime = int64 seconds; CalendarTime = {s16 year, s8 month/day/hour/minute/second};
// CalendarAdditionalInfo = {u32 day of week, u32 day of year, char time zone name[8], u32 DST, s32 UTC offset in seconds}.
#include "hle.h"
#include <stdatomic.h>
#include <time.h>

typedef struct { int16_t year; int8_t month, day, hour, minute, second; int8_t pad; } CalendarTime;
typedef struct { uint32_t wday, yday; char tzname[8]; uint32_t dst; int32_t offset; } CalendarAdditionalInfo;

// User calendar clock follows the host wall clock. SDK steady time is retained.
HLE_FORCE("_ZN2nn4time23StandardUserSystemClock3nowEv", "User system wall clock", int64_t, h_time_now, void) { return time(NULL); }
HLE_FORCE("_ZN2nn4time23StandardUserSystemClock9to_time_tERKNSt3__16chrono10time_pointINS0_17SystemClockTraitsENS3_8durationIlNS2_5ratioILl1ELl1EEEEEEE",
          "SDK 实现与 now() 配套，一并接管", int64_t, h_time_to_time_t, const int64_t *tp) { return *tp; }
HLE_FORCE("_ZN2nn4time14ToCalendarTimeEPNS0_12CalendarTimeEPNS0_22CalendarAdditionalInfoERKNS0_9PosixTimeE",
          "连 time 服务的时区规则；改用宿主 localtime_r", Result, h_time_ToCalendarTime, CalendarTime *ct, CalendarAdditionalInfo *ai, const int64_t *pt) {
    time_t t = *pt; struct tm tm; localtime_r(&t, &tm);
    static int once; if (!once++) LOG("ToCalendarTime：首次换算 %lld → %04d-%02d-%02d %02d:%02d（时区 %s，偏移 %ld 秒）", (long long)t, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_zone ? tm.tm_zone : "?", (long)tm.tm_gmtoff);
    if (ct) *ct = (CalendarTime){(int16_t)(tm.tm_year + 1900), (int8_t)(tm.tm_mon + 1), (int8_t)tm.tm_mday, (int8_t)tm.tm_hour, (int8_t)tm.tm_min, (int8_t)tm.tm_sec, 0};
    if (ai) { memset(ai, 0, sizeof *ai); ai->wday = tm.tm_wday; ai->yday = tm.tm_yday; strlcpy(ai->tzname, tm.tm_zone ? tm.tm_zone : "UTC", sizeof ai->tzname);
              ai->dst = tm.tm_isdst > 0; ai->offset = (int32_t)tm.tm_gmtoff; }
    return RES_OK;
}
// 本地时刻换算强制接宿主 libc：SDK 自带的 localtime / localtime_r / mktime 没有时区数据、恒按 UTC（宿主实测：编年史「首次发现」由
// main+0xb04d34 调 localtime 再 strftime 出，差 8 小时）。真机 Switch 的 SDK 按系统时区换算，这里跟宿主系统时区走才一致；
// 宿主 TZ 平时 = 系统时区，只在 DM_FIXED_TIME 确定性对拍时钉 UTC（main.c）。struct tm 布局两边相同（9 个 int、long 偏移、时区名指针）。
// gmtime / gmtime_r / timegm 本来就是 UTC，不接。hle_table.c 的同名直通项只在符号没有定义时才生效（SDK 有定义），所以要 HLE_FORCE
// Local time conversion is forced onto the host libc: the SDK's own localtime / localtime_r / mktime have no time zone data and always use UTC (measured on the host: the chronicle's 「首次发现」(First Discovered) is produced by
// main+0xb04d34 calling localtime and then strftime, and was off by 8 hours). The SDK on a real Switch converts by the system time zone, so only following the host system time zone here is consistent;
// the host TZ normally = the system time zone, and is pinned to UTC only for deterministic comparison with DM_FIXED_TIME (main.c). The struct tm layout is the same on both sides (9 ints, long offset, time zone name pointer).
// gmtime / gmtime_r / timegm are UTC anyway and are not taken over. The same-named pass-through entries in hle_table.c only take effect when the symbol has no definition (the SDK defines them), hence HLE_FORCE
HLE_FORCE("localtime", "本地时刻 → 宿主 localtime（跟系统时区）", struct tm *, h_localtime, const int64_t *t) { time_t v = (time_t)*t; return localtime(&v); }
HLE_FORCE("localtime_r", "本地时刻 → 宿主 localtime_r（跟系统时区）", struct tm *, h_localtime_r, const int64_t *t, struct tm *out) { time_t v = (time_t)*t; return localtime_r(&v, out); }
HLE_FORCE("mktime", "本地日历 → 绝对秒，宿主 mktime（跟系统时区）", int64_t, h_mktime, struct tm *tm) { return (int64_t)mktime(tm); }

static _Atomic int pjdv_time_initialized;
HLE_FORCE("_ZN2nn4time10InitializeEv", "Host calendar time service", void, h_time_Initialize, void) { atomic_store(&pjdv_time_initialized,1); }
HLE_FORCE("_ZN2nn4time13IsInitializedEv", "Host calendar time service status", int, h_time_IsInitialized, void) { return atomic_load(&pjdv_time_initialized); }
HLE_FORCE("_ZN2nn4time8FinalizeEv", "Release host calendar time service", void, h_time_Finalize, void) { atomic_store(&pjdv_time_initialized,0); }
HLE_FORCE("_ZN2nn4time23StandardUserSystemClock14GetCurrentTimeEPNS0_9PosixTimeE", "Host POSIX calendar seconds", Result, h_time_Current, int64_t *out) {
    if (!out || !atomic_load(&pjdv_time_initialized)) return RES_FAIL;
    *out = time(NULL); return RES_OK;
}

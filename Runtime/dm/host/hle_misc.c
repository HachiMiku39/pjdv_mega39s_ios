// 零散服务层：追加内容 / 商店 / 错误小程序 / 敏感词过滤 / 服务器名解析 / 家长控制 / 软键盘。
// 真机上各自走 IPC 或系统小程序；宿主按单机离线给结果。纯计算的 SDK 部分（hash、util、软件 Opus）不接管，直接用原实现。
// Miscellaneous service layer: add-on content / shop / error applet / profanity filter / server name resolution / parental controls / software keyboard.
// On the real device each goes through IPC or a system applet; the host gives results as single-player offline. Pure-computation SDK parts (hash, util, software Opus) are not taken over, the original implementation is used directly.
#include "hle.h"

// PJDV add-on content: only authenticated, locally prepared package entries.
#include <unistd.h>
#include <sys/stat.h>
#include "PjdvDlcLayout.h"
#include "pjdv_dlc_config.h"
static int pjdv_dlc_indexes_for_session(int out[PJDV_MAX_DLC]){
    const char *declaration=getenv("PJDV_DLC_INDEXES");
    if(declaration){int count=pjdv_parse_dlc_indexes(declaration,out);return count<0?0:count;}
    // Compatibility for standalone native diagnostics. The app always sets
    // its validated list, including an empty string for a base-only import.
    int count=(int)(sizeof pjdv_dlc_indexes/sizeof(int));
    if(count>PJDV_MAX_DLC)return 0;
    memcpy(out,pjdv_dlc_indexes,count*sizeof(int));return count;
}
int pjdv_dlc_path(int index,char *out,size_t size){
    const char *root=getenv("PJDV_DLC_ROOT");if(!root)return 0;
    int indexes[PJDV_MAX_DLC],count=pjdv_dlc_indexes_for_session(indexes),valid=0;
    for(int i=0;i<count;i++)valid|=index==indexes[i];if(!valid)return 0;
    char marker[1100];snprintf(marker,sizeof marker,"%s/%d/complete.json",root,index);
    struct stat st;if(stat(marker,&st) || !S_ISREG(st.st_mode) || access(marker,R_OK))return 0;
    int written=snprintf(out,size,"%s/%d",root,index);return written>=0 && (size_t)written<size;
}
HLE_FORCE("_ZN2nn3aoc17CountAddOnContentEv", "Prepared local PJDV DLC count", int, h_aoc_Count, void) {
    int indexes[PJDV_MAX_DLC],count=pjdv_dlc_indexes_for_session(indexes),n=0;
    char path[1024];for(int i=0;i<count;i++)n+=pjdv_dlc_path(indexes[i],path,sizeof path);return n;
}
HLE_FORCE("_ZN2nn3aoc16ListAddOnContentEPiii", "Prepared local PJDV DLC indexes", int, h_aoc_List, int *out,int off,int n) {
    if(!out || off<0 || n<1)return 0;
    int indexes[PJDV_MAX_DLC],count=pjdv_dlc_indexes_for_session(indexes);
    int pos=0,w=0;char path[1024];for(int i=0;i<count && w<n;i++)if(pjdv_dlc_path(indexes[i],path,sizeof path)){
        if(pos++>=off)out[w++]=indexes[i];
    }return w;
}
// 事件对象按需由 nn::os 旁表建（未触发），游戏等它只会超时 / 取到未触发
// The event object is created on demand by the nn::os side table (not signaled), the game waiting on it only times out / gets not-signaled
HLE_FORCE("_ZN2nn3aoc31GetAddOnContentListChangedEventEPNS_2os11SystemEventE", "追加内容变更事件，排除范围；绑内核事件、恒不触发（游戏会 TryWait 轮询，未初始化即中止）", void, h_aoc_GetEv, void *ev) { hle_bind_system_event(ev, 0); }
extern void pjdv_exit_from_shop(uint64_t caller);
HLE_FORCE("_ZN2nn2ec24ShowShopAddOnContentListEv", "Verified main-menu eShop entry -> host exit confirmation", void, h_ec_ShowShop, void) {
    pjdv_exit_from_shop((uint64_t)__builtin_return_address(0));
}
HLE_FORCE("_ZN2nn2ec24ShowShopAddOnContentListERKNS_7account10UserHandleE", "Same verified eShop entry with selected user", void, h_ec_ShowShopUser, const void *user) {
    (void)user;pjdv_exit_from_shop((uint64_t)__builtin_return_address(0));
}

// ---------- err 错误小程序：宿主打印 ----------
// ---------- err error applet: printed by the host ----------
HLE_FORCE("_ZN2nn3err9ShowErrorENS_6ResultE", "错误显示小程序；宿主打印模块 / 描述号", void, h_err_ShowError, Result r) {
    LOG("err::ShowError Result=%#x（模块 %u，描述 %u）", r, r & 0x1ff, (r >> 9) & 0x1fff);
}

// ---------- ngc 敏感词过滤：词库在系统数据存档（经 IPC 挂载）；单机无他人可见文本，恒判无敏感词 ----------
// ---------- ngc profanity filter: the word list is in a system data save (mounted via IPC); single-player has no text visible to others, always judged as no profanity ----------
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterC1Ev", "敏感词过滤，词库走系统存档；宿主不建", void, h_ngc_Ctor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterD1Ev", "敏感词过滤", void, h_ngc_Dtor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter10InitializeEPvm", "敏感词过滤初始化；宿主无词库", Result, h_ngc_Init, void *self, void *work, uint64_t sz) { (void)self; (void)work; (void)sz; return RES_OK; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter17GetContentVersionEv", "词库版本；宿主 0", uint32_t, h_ngc_Ver, void *self) { (void)self; return 0; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKcm", "敏感词检查；恒无命中", Result, h_ngc_Check, void *self, uint32_t *masks, uint32_t pat, const char **words, uint64_t n) {
    (void)self; (void)pat; (void)words;
    for (uint64_t i = 0; i < n; i++) masks[i] = 0;
    return RES_OK;
}

// ---------- nsd 服务器名解析 / pctl 自由通信：联网，排除范围 ----------
// ---------- nsd server name resolution / pctl free communication: networking, out of scope ----------
HLE_FORCE("_ZN2nn3nsd7ResolveEPNS0_4FqdnERKS1_", "服务器名解析，联网排除；剪口", Result, h_nsd_Resolve, void *out, const void *in) { (void)out; (void)in; return RES_FAIL; }
HLE_FORCE("_ZN2nn3nsd9ResolveExEPNS0_4FqdnERKS1_", "服务器名解析，联网排除；剪口", Result, h_nsd_ResolveEx, void *out, const void *in) { (void)out; (void)in; return RES_FAIL; }
// bool 参数只看低 8 位；返回 bool
// bool arguments only look at the low 8 bits; returns bool
HLE_FORCE("_ZN2nn4pctl25TryBeginFreeCommunicationEb", "家长控制·与他人通信，联网排除；恒不允许", unsigned, h_pctl_TryBegin, unsigned show_ui) { (void)show_ui; return 0; }
HLE_FORCE("_ZN2nn4pctl20EndFreeCommunicationEv", "家长控制·与他人通信", void, h_pctl_End, void) {}

// swkbd 软键盘：见 hle_swkbd.c
// swkbd software keyboard: see hle_swkbd.c

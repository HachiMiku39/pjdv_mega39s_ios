// PJDV native guest startup. No D2R cuts, seed patches, or application offsets.
#include "dm.h"
#include <unistd.h>
static pthread_mutex_t status_lock=PTHREAD_MUTEX_INITIALIZER;
static char state[192]="Horizon runtime pending";
void pjdv_guest_state(char *out,size_t n){pthread_mutex_lock(&status_lock);strlcpy(out,state,n);
strlcat(out," • AudioRenderer: CoreAudio 48 kHz stereo",n);
pthread_mutex_unlock(&status_lock);}
static void stage(const char *s){pthread_mutex_lock(&status_lock);strlcpy(state,s,sizeof state);pthread_mutex_unlock(&status_lock);LOG("PJDV >>> %s",s);}
#include "pjdv_session.inc"
extern void pjdv_guest_relocate(void),guest_thread_init(void),crash_install(void),stubs_report(void);
extern uint32_t svc_thread_main_init(void);
static void *required(const char *s){void *p=guest_sym(s);if(!p)die("PJDV startup symbol missing: %s",s);return p;}
static void call(const char *s){stage(s);((void(*)(void))required(s))();}
static void guest_boot_run(const char *rom,const char *dlc,const char *save,const char *temp,const char *log){
    if(freopen(log,"w",stderr))setvbuf(stderr,NULL,_IONBF,0);
    setenv("DM_ROMFS",rom,1);setenv("DM_SAVE",save,1);setenv("DM_TEMP",temp,1);setenv("DM_ROOT",temp,1);
    setenv("PJDV_DLC_ROOT",dlc,1);
    #if TARGET_OS_SIMULATOR || TARGET_OS_MACCATALYST
    #if TARGET_OS_SIMULATOR
    setenv("DM_NVN_SHMAP","/Volumes/Switch-iOS-Dev/GameBuild/MEGA39-v1.0.9/Shaders/shader_map.tsv",1);
    setenv("DM_MSL_DIR","/Volumes/Switch-iOS-Dev/GameBuild/MEGA39-v1.0.9/MetalCache",1);
    #else
    // Catalyst follows the selected resource folder, just like the iPad build.
    // A packaged shader update must not depend on this developer's SSD name.
    char parent[1200],map[1400],cache[1400];strlcpy(parent,rom,sizeof parent);char *slash=strrchr(parent,'/');if(slash)*slash=0;
    snprintf(map,sizeof map,"%s/Shaders/shader_map.tsv",parent);snprintf(cache,sizeof cache,"%s/MetalCache",parent);
    setenv("DM_NVN_SHMAP",map,1);setenv("DM_MSL_DIR",cache,1);
    #endif
    setenv("DM_PRESENT_LINK","0",1);
    char diagnostic[1600];
    // Expensive exports are explicit color diagnostics, never default gameplay.
    const char *colorDiag=getenv("PJDV_COLOR_DIAG");
    if(colorDiag && !strcmp(colorDiag,"1")){
        setenv("PJDV_DIAG_SAMPLE","1",1);
        snprintf(diagnostic,sizeof diagnostic,"1000,1300,1500,2000,3500,9500:%s/pjdv-frame-%%d.png",temp);setenv("DM_NVN_SHOT",diagnostic,1);
        setenv("PJDV_INPUT_TRACE","1",1);
        snprintf(diagnostic,sizeof diagnostic,"3500:%s/pjdv-target-%%d.png",temp);setenv("DM_NVN_TEXDUMP",diagnostic,1);
        snprintf(diagnostic,sizeof diagnostic,"%s/pjdv-fs.tsv",temp);setenv("DM_FSLOG",diagnostic,1);
        setenv("DM_NVN_CBDUMP",temp,1);setenv("DM_NVN_VBDUMP",temp,1);
        setenv("DM_NVN_TEXDUMP_INPUT","1",1);
        setenv("DM_NVN_PASSDUMP","3500",1);setenv("DM_NVN_PASSDUMP_ALL","1",1);
        setenv("DM_NVN_ATTRTRACE","1",1);
        setenv("PJDV_CAPTURE_REQUEST","/Volumes/Switch-iOS-Dev/Build/Temp/pjdv-capture.request",1);
        setenv("DM_NVN_ENC_LABEL","1",1);
        setenv("DM_NVN_SNAPRAW","1",1); // retain native float intermediates, not just clipped PNGs
    }
    // Enable PJDV_GPU_CAPTURE in the launch environment for one bounded trace.
    if (getenv("PJDV_GPU_CAPTURE")) { snprintf(diagnostic,sizeof diagnostic,"1500:%s/pjdv-frame-1500.gputrace",temp);setenv("DM_NVN_CAPTURE",diagnostic,1); }
#elif TARGET_OS_IPHONE
    char parent[1200],map[1400],cache[1400];strlcpy(parent,rom,sizeof parent);char *slash=strrchr(parent,'/');if(slash)*slash=0;
    snprintf(map,sizeof map,"%s/Shaders/shader_map.tsv",parent);snprintf(cache,sizeof cache,"%s/MetalCache",parent);
    setenv("DM_NVN_SHMAP",map,1);setenv("DM_MSL_DIR",cache,1);
#endif
    // Swift validated this exact bundle/cache chain before starting the guest.
    // It remains independent of the selected (possibly read-only) game folder.
    const char *render_root=getenv("PJDV_RENDER_ROOT");
    if(render_root && *render_root){char map[1600],cache[1600];
        snprintf(map,sizeof map,"%s/Shaders/shader_map.tsv",render_root);
        snprintf(cache,sizeof cache,"%s/MetalCache",render_root);
        setenv("DM_NVN_SHMAP",map,1);setenv("DM_MSL_DIR",cache,1);
    }
    // PJDV_TBDR=1 is opt-in until matched-frame PJDV lighting and timing pass.
    // Cross-submission prediction stays off: a future loading frame may sample
    // a target that looked transient in the previous submission.
    const char *tbdr=getenv("PJDV_TBDR");
    setenv("DM_NVN_TBDR",tbdr && !strcmp(tbdr,"1")?"1":"0",1);
    setenv("DM_NVN_XV","0",1);setenv("DM_NVN_LOG","1",1);
    LOG("PJDV conservative TBDR: %s (cross-submission prediction off)",getenv("DM_NVN_TBDR"));
    setenv("DM_LANG",getenv("PJDV_LANGUAGE")?:"zh-Hans",1);
    const char *language=getenv("DM_LANG"),*tag="en";
    if(strstr(language,"Hant") || !strcmp(language,"tw"))tag="tw";
    else if(!strncmp(language,"zh",2) || !strcmp(language,"cn"))tag="cn";
    else if(!strncmp(language,"ja",2) || !strcmp(language,"jp"))tag="jp";
    else if(!strncmp(language,"ko",2) || !strcmp(language,"kr"))tag="kr";
    const char *menu_root=getenv("PJDV_EXIT_MENU_ROOT");
    // Capture the caller's original overlays once; never prepend old language
    // variants again on a second boot, or shadow unrelated resource overrides.
    static char *base_overlay;static int base_overlay_captured;
    if(!base_overlay_captured){const char *v=getenv("DM_ROMFS_OVERLAY");base_overlay=v?strdup(v):NULL;base_overlay_captured=1;}
    if(menu_root){char overlay[4096];const char *prior=base_overlay;
        snprintf(overlay,sizeof overlay,"%s/%s%s%s",menu_root,tag,prior?":":"",prior?:"");setenv("DM_ROMFS_OVERLAY",overlay,1);
        LOG("PJDV exit menu: language=%s, original-font sprite override",tag);
    }
    const char *quality=getenv("PJDV_GAME_DOCKED");
    setenv("DM_OPMODE",quality && !strcmp(quality,"1")?"1":"0",1);
    LOG("PJDV original render profile: %s",getenv("DM_OPMODE"));
    g_t0_ns=now_ns();crash_install();stage("Guest cross-module relocation");
    extern void pjdv_diag_start(void);pjdv_diag_start();
    pjdv_guest_relocate();stubs_report();guest_thread_init();
    uint32_t main=svc_thread_main_init();
    call("_init_libc0");stage("nnosInitialize");((void(*)(uint64_t,uint64_t))required("nnosInitialize"))(main,0);
    call("_init_libc1");call("nninitInitializeSdkModule");call("nninitStartup");call("_init_libc2");
    stage("Guest module constructors");run_module_inits();
    ((void(*)(int))required("_ZN2nn2os11SetHostArgcEi"))(1);
    static char *args[]={"PJDV M39",NULL};((void(*)(char **))required("_ZN2nn2os11SetHostArgvEPPc"))(args);
    pjdv_metal_session_begin();atomic_store(&session_phase,2);call("nnMain");stage("nnMain returned");
}

typedef struct { char *path[5]; } guest_boot_args;
static void boot_args_free(guest_boot_args *a){for(int i=0;i<5;i++)free(a->path[i]);free(a);}
static void guest_boot_body(void *opaque){
    guest_boot_args *a=opaque;guest_boot_run(a->path[0],a->path[1],a->path[2],a->path[3],a->path[4]);
}
static void *guest_boot_thread(void *opaque){
    extern int pjdv_thread_scope(void (*)(void *),void *);extern void pjdv_thread_main_finished(void);
    pjdv_thread_scope(guest_boot_body,opaque);boot_args_free(opaque);pjdv_thread_main_finished();return NULL;
}
void pjdv_guest_boot(const char *rom,const char *dlc,const char *save,const char *temp,const char *log){
    int idle=0;if(!atomic_compare_exchange_strong(&session_phase,&idle,1))return;
    // The title's NPDM requests a 2 MiB main stack. Its save initializer alone
    // reserves 0x1526c0 bytes; a libdispatch worker's stack is insufficient.
    // Reserve additional room for the host bridge and diagnostics on a pthread.
    guest_boot_args *a=calloc(1,sizeof(*a));
    if(!a){stage("Guest startup allocation failed");atomic_store(&session_phase,6);return;}
    const char *paths[]={rom,dlc,save,temp,log};
    for(int i=0;i<5;i++)if(!(a->path[i]=strdup(paths[i]))){boot_args_free(a);stage("Guest startup allocation failed");atomic_store(&session_phase,6);return;}
    pthread_attr_t attr;pthread_attr_init(&attr);
    int result=pthread_attr_setstacksize(&attr,8*1024*1024);
    pthread_t thread;
    if(!result)result=pthread_create(&thread,&attr,guest_boot_thread,a);
    pthread_attr_destroy(&attr);
    if(result){boot_args_free(a);stage("Guest main thread creation failed");atomic_store(&session_phase,6);return;}
    pthread_detach(thread);
}

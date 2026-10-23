#include "dm.h"
#include "front.h"
#include <stdatomic.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <unistd.h>
#include <dlfcn.h>
uint64_t g_t0_ns;
struct dm_flags g_flag={.dbg=1,.imports=0,.svc=1};
_Atomic int g_dm_frozen;
static _Atomic uint64_t load_ns[PROF_N],load_bytes[PROF_N],load_calls[PROF_N];
void dm_prof_add(int id,uint64_t ns,uint64_t bytes){if(id<0 || id>=PROF_N)return;
    atomic_fetch_add(&load_ns[id],ns);atomic_fetch_add(&load_bytes[id],bytes);atomic_fetch_add(&load_calls[id],1);}
void dm_prof_mark(const char *s){LOG("PJDV stage: %s",s);}
uint64_t front_game_res(int docked){return (720ull<<32)|1280;}
int front_text_input(const char *title,const char *sub,const char *guide,const char *initial,int max_chars,char *out,int out_cap){return -1;}

// Diagnostic snapshots copy register/frame data while a guest thread is
// suspended, then resume it before taking locks or writing to stdio.
extern int thr_diag_targets(thread_t *,char (*)[80],int);
static void sample_guest_threads(void) {
    thread_t ports[128];char names[128][80];int count=thr_diag_targets(ports,names,128);
    LOG("PJDV diagnostic guest snapshot: %d threads",count);
    for(int i=0;i<count;i++) {
        thread_t port=ports[i];
        if(thread_suspend(port)!=KERN_SUCCESS){mach_port_deallocate(mach_task_self(),port);continue;}
        arm_thread_state64_t state;mach_msg_type_number_t n=ARM_THREAD_STATE64_COUNT;
        uint64_t pcs[18];int used=0;uint64_t regs[10]={0},object[18]={0},node[8]={0},movie[8]={0};int object_ok=0,node_ok=0,movie_ok=0;
        if(thread_get_state(port,ARM_THREAD_STATE64,(thread_state_t)&state,&n)==KERN_SUCCESS) {
            pcs[used++]=__darwin_arm_thread_state64_get_pc(state);
            pcs[used++]=__darwin_arm_thread_state64_get_lr(state);
            uint64_t fp=__darwin_arm_thread_state64_get_fp(state);
            while(fp && used<18) {
                uint64_t frame[2];vm_size_t got=0;
                if(vm_read_overwrite(mach_task_self(),fp,sizeof frame,(vm_address_t)frame,&got)!=KERN_SUCCESS || got!=sizeof frame)break;
                pcs[used++]=frame[1];if(frame[0]<=fp)break;fp=frame[0];
            }
            if(strstr(names[i],"MovieReceiveInput") || strstr(names[i],"主线程")){
                for(int j=0;j<10;j++)regs[j]=state.__x[19+j];vm_size_t got=0;
                object_ok=regs[0]>0x100000000ull && vm_read_overwrite(mach_task_self(),regs[0],sizeof object,(vm_address_t)object,&got)==KERN_SUCCESS && got==sizeof object;
                node_ok=regs[5]>0x100000000ull && vm_read_overwrite(mach_task_self(),regs[5],sizeof node,(vm_address_t)node,&got)==KERN_SUCCESS && got==sizeof node;
                movie_ok=regs[0]>0x100000000ull && vm_read_overwrite(mach_task_self(),regs[0]+0x730,sizeof movie,(vm_address_t)movie,&got)==KERN_SUCCESS && got==sizeof movie;
            }
        }
        thread_resume(port);
        mach_port_deallocate(mach_task_self(),port);
        if(!used)continue;
        char line[1400];size_t at=(size_t)snprintf(line,sizeof line,"PJDV sample %s:",names[i]);
        for(int j=0;j<used && at<sizeof line-80;j++) {
            module_t *m=module_of((void *)pcs[j]);
            if(m)at+=(size_t)snprintf(line+at,sizeof line-at," %s+%#llx",m->name,pcs[j]-(uint64_t)m->base);
        }
        LOG("%s",line);
        if(object_ok){LOG("PJDV movie regs %s x19=%#llx x20=%#llx x21=%#llx x22=%#llx x23=%#llx x24=%#llx",names[i],regs[0],regs[1],regs[2],regs[3],regs[4],regs[5]);
            LOG("PJDV movie object +0x60: %016llx %016llx %016llx %016llx",object[12],object[13],object[14],object[15]);}
        if(node_ok)LOG("PJDV movie node: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",node[0],node[1],node[2],node[3],node[4],node[5],node[6],node[7]);
        if(movie_ok)LOG("PJDV movie +0x730: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",movie[0],movie[1],movie[2],movie[3],movie[4],movie[5],movie[6],movie[7]);
    }
}
static _Atomic int diagnostic_stop;
static pthread_t diagnostic_threads[2];static int diagnostic_count;
static int diagnostic_sleep(unsigned ms){for(unsigned n=0;n<ms;n+=100){if(atomic_load(&diagnostic_stop))return 0;usleep(100000);}return !atomic_load(&diagnostic_stop);}
static void *diagnostic_sample_thread(void *unused) {
    (void)unused;if(!diagnostic_sleep(45000))return NULL;sample_guest_threads();
    if(!diagnostic_sleep(20000))return NULL;sample_guest_threads();
    if(!diagnostic_sleep(60000))return NULL;sample_guest_threads();return NULL;
}
// Opt-in physical-device loading samples. Only read this process's guest
// threads; resume before symbol lookup or logging. CPU deltas distinguish a
// busy decoder from waits; I/O counters measure actual ReadFile wall time.
static void *loading_sample_thread(void *unused){
    (void)unused;uint64_t previous_cpu[128]={0};mach_port_t previous_port[128]={0};
    const char *labels[]={"read","lock","condvar","address","sync","sleep","mainwait","present","shader","archive-gzip","path"};
    for(int tick=0;tick<240;tick++){
        if(!diagnostic_sleep(2000))break;double second=(now_ns()-g_t0_ns)/1e9;
        for(int j=0;j<PROF_N;j++){uint64_t count=atomic_exchange(&load_calls[j],0),ns=atomic_exchange(&load_ns[j],0),bytes=atomic_exchange(&load_bytes[j],0);
            if(count)LOG("PJDV load t=%.3f kind=%s calls=%llu ms=%.3f bytes=%llu",second,labels[j],(unsigned long long)count,ns/1e6,(unsigned long long)bytes);}
        thread_t ports[128];char names[128][80];int count=thr_diag_targets(ports,names,128);
        for(int i=0;i<count;i++){
            thread_basic_info_data_t info;mach_msg_type_number_t size=THREAD_BASIC_INFO_COUNT;
            uint64_t cpu=0,delta=0,pcs[12];int used=0;
            if(thread_info(ports[i],THREAD_BASIC_INFO,(thread_info_t)&info,&size)==KERN_SUCCESS){
                cpu=(uint64_t)(info.user_time.seconds+info.system_time.seconds)*1000000+info.user_time.microseconds+info.system_time.microseconds;
                delta=previous_port[i]==ports[i] && cpu>=previous_cpu[i]?cpu-previous_cpu[i]:0;
            }
            previous_port[i]=ports[i];previous_cpu[i]=cpu;
            if(delta>=10000 && thread_suspend(ports[i])==KERN_SUCCESS){
                arm_thread_state64_t state;size=ARM_THREAD_STATE64_COUNT;
                if(thread_get_state(ports[i],ARM_THREAD_STATE64,(thread_state_t)&state,&size)==KERN_SUCCESS){
                    pcs[used++]=__darwin_arm_thread_state64_get_pc(state);pcs[used++]=__darwin_arm_thread_state64_get_lr(state);
                    uint64_t fp=__darwin_arm_thread_state64_get_fp(state);
                    while(fp && used<12){uint64_t frame[2];vm_size_t got=0;
                        if(vm_read_overwrite(mach_task_self(),fp,sizeof frame,(vm_address_t)frame,&got)!=KERN_SUCCESS || got!=sizeof frame)break;
                        pcs[used++]=frame[1];if(frame[0]<=fp)break;fp=frame[0];}
                }
                thread_resume(ports[i]);
            }
            mach_port_deallocate(mach_task_self(),ports[i]);
            if(!used)continue;
            char line[1800];size_t at=snprintf(line,sizeof line,"PJDV loadcpu t=%.3f cpu_ms=%.1f %s:",second,delta/1000.0,names[i]);
            for(int j=0;j<used && at<sizeof line-140;j++){
                module_t *m=module_of((void *)pcs[j]);Dl_info symbol;
                if(m)at+=snprintf(line+at,sizeof line-at," %s+%#llx",m->name,pcs[j]-(uint64_t)m->base);
                else if(dladdr((void *)pcs[j],&symbol) && symbol.dli_sname)at+=snprintf(line+at,sizeof line-at," %s+%#llx",symbol.dli_sname,pcs[j]-(uint64_t)symbol.dli_saddr);
            }
            LOG("%s",line);
        }
    }
    return NULL;
}
void pjdv_diag_start(void) {
    atomic_store(&diagnostic_stop,0);
    const char *load=getenv("PJDV_LOAD_DIAG");
    if(load && !strcmp(load,"1")){g_flag.bootprof=1;if(!pthread_create(&diagnostic_threads[diagnostic_count],NULL,loading_sample_thread,NULL))diagnostic_count++;}
#if TARGET_OS_SIMULATOR
    if(!getenv("PJDV_DIAG_SAMPLE"))return;
    if(!pthread_create(&diagnostic_threads[diagnostic_count],NULL,diagnostic_sample_thread,NULL))diagnostic_count++;
#endif
}

void pjdv_diag_stop(void){atomic_store(&diagnostic_stop,1);for(int i=0;i<diagnostic_count;i++)pthread_join(diagnostic_threads[i],NULL);diagnostic_count=0;g_flag.bootprof=0;}

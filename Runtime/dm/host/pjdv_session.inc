// PJDV session control. The only request producer is the verified eShop callback.
// All UI decisions are supplied by the main-thread host alert.
#include <stdatomic.h>
#include <errno.h>
static _Atomic int session_phase,exit_prompt,exit_decision,exit_error;
static pthread_mutex_t exit_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t exit_cv=PTHREAD_COND_INITIALIZER;
extern int pjdv_threads_quiesce(uint64_t),pjdv_threads_reap(uint64_t);
extern void pjdv_threads_resume(void),pjdv_threads_stop(void),pjdv_thread_checkpoint(void);
extern int pjdv_fs_exit_commit(void),pjdv_metal_session_end(void),pjdv_metal_session_finish(void),pjdv_guest_reset(char *,size_t);
extern void pjdv_diag_stop(void),pjdv_audio_session_end(void),pjdv_avc_session_end(void);
extern void pjdv_vibration_session_end(void);
extern void pjdv_nvn_session_end(void),pjdv_vi_session_end(void),pjdv_fs_session_end(void);
extern void pjdv_os_session_end(void),pjdv_oe_session_end(void),pjdv_svc_session_end(void);
extern void pjdv_hle_session_end(void),pjdv_loader_session_end(void),pjdv_end_game_graphics(void);
extern void dm_gfx_suspend(int),mtl_present_discard(int),pjdv_metal_session_begin(void);
int pjdv_session_phase(void){return atomic_load(&session_phase);}
int pjdv_exit_prompt_pending(void){return atomic_load(&exit_prompt);}
int pjdv_exit_last_error(void){return atomic_exchange(&exit_error,0);}
void pjdv_exit_answer(int yes){
    pthread_mutex_lock(&exit_lock);
    if(atomic_load(&exit_prompt)){
        atomic_store(&exit_prompt,0);atomic_store(&exit_decision,yes?1:-1);pthread_cond_broadcast(&exit_cv);
    }
    pthread_mutex_unlock(&exit_lock);
}
static void exit_recover(int error){
    pjdv_threads_resume();atomic_store(&exit_error,error);atomic_store(&session_phase,2);
    LOG("PJDV exit refused before teardown: errno=%d; guest resumed",error);
}
static void *session_exit_run(void *unused){
    (void)unused;
    // Dropping only presentation during a pending exit prevents an unavailable
    // drawable from keeping a guest thread outside its checkpoint forever.
    mtl_present_discard(1);
    if(!pjdv_threads_quiesce(5000000000ull)){mtl_present_discard(0);exit_recover(ETIMEDOUT);return NULL;}
    int error=pjdv_fs_exit_commit();
    if(error){mtl_present_discard(0);exit_recover(error);return NULL;}
    LOG("PJDV exit: save commit and durability barrier completed");
    atomic_store(&session_phase,5);pjdv_diag_stop();
    pjdv_vibration_session_end();pjdv_audio_session_end();pjdv_avc_session_end();
    dm_gfx_suspend(1);
    if(!pjdv_metal_session_end()){
        // Never remap memory while a command encoder or guest pointer is live.
        atomic_store(&exit_error,EBUSY);atomic_store(&session_phase,6);return NULL;
    }
    pjdv_threads_stop();
    if(!pjdv_threads_reap(5000000000ull)){
        atomic_store(&exit_error,ETIMEDOUT);atomic_store(&session_phase,6);return NULL;
    }
    if(!pjdv_metal_session_finish()){
        atomic_store(&exit_error,EBUSY);atomic_store(&session_phase,6);return NULL;
    }
    pjdv_nvn_session_end();pjdv_vi_session_end();pjdv_fs_session_end();
    pjdv_os_session_end();pjdv_oe_session_end();pjdv_svc_session_end();
    pjdv_hle_session_end();pjdv_loader_session_end();
    char error_text[256];
    if(!pjdv_guest_reset(error_text,sizeof error_text)){
        stage(error_text);atomic_store(&exit_error,EFAULT);atomic_store(&session_phase,6);return NULL;
    }
    pjdv_end_game_graphics();dm_gfx_suspend(0);
    return (void *)1;
}
static void *session_exit_worker(void *unused){
    extern void *objc_autoreleasePoolPush(void);extern void objc_autoreleasePoolPop(void *);
    void *pool=objc_autoreleasePoolPush();void *released=session_exit_run(unused);objc_autoreleasePoolPop(pool);
    if(released){extern void pjdv_metal_session_report(void);pjdv_metal_session_report();stage("Guest session released; ready to launch");atomic_store(&session_phase,0);}return NULL;
}
void pjdv_exit_from_shop(uint64_t caller){
    module_t *m=module_of((void *)caller);
    uint64_t offset=m?caller-(uint64_t)m->base:0;
    if(!m || strcmp(m->name,"main") || (offset!=0x6f4eb4 && offset!=0x6f4ebc)){
        LOG("PJDV eShop remap ignored: unverified caller %s+%#llx",m?m->name:"host",offset);return;
    }
    int running=2;if(!atomic_compare_exchange_strong(&session_phase,&running,3))return;
    LOG("PJDV eShop menu callback main+%#llx -> exit confirmation",offset);
    pthread_mutex_lock(&exit_lock);atomic_store(&exit_decision,0);atomic_store(&exit_prompt,1);
    while(!atomic_load(&exit_decision))pthread_cond_wait(&exit_cv,&exit_lock);
    int yes=atomic_load(&exit_decision)>0;pthread_mutex_unlock(&exit_lock);
    if(!yes){atomic_store(&session_phase,2);LOG("PJDV exit cancelled");return;}
    atomic_store(&session_phase,4);pthread_t worker;
    if(pthread_create(&worker,NULL,session_exit_worker,NULL)){
        atomic_store(&exit_error,EAGAIN);atomic_store(&session_phase,2);return;
    }
    pthread_detach(worker);
    // Let the coordinator include this very callback in the quiescence barrier.
    // Until it arms the barrier, do not let the original main loop advance.
    while(atomic_load(&session_phase)==4 || atomic_load(&session_phase)==5){pjdv_thread_checkpoint();usleep(1000);}
    // A failed pre-teardown check resumes and returns to the same menu. A
    // successful stop unwinds this thread to its owned host stack boundary.
}


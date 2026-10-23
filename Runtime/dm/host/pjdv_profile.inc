// Default progression policy, applied on the game's save thread at mount and
// transaction commit. No instruction patches, synthesized scores or PV IDs.
#include "pjdv_profile.h"
static int pjdv_unlock_enabled(void){const char *v=getenv("PJDV_UNLOCK_ALL");return !v || strcmp(v,"0");}
static int pjdv_profile_write_all(int fd,const uint8_t *b,size_t n){
    while(n){ssize_t done=write(fd,b,n);if(done<0 && errno==EINTR)continue;if(done<=0)return -1;b+=done;n-=done;}return 0;
}
static int pjdv_profile_backup(const char *root,const uint8_t *b,size_t n){
    char dir[1200],path[1300];
    if(snprintf(dir,sizeof dir,"%s.unlock-backup-v1",root)>=(int)sizeof dir ||
       snprintf(path,sizeof path,"%s/sys.dat",dir)>=(int)sizeof path){errno=ENAMETOOLONG;return -1;}
    if(mkdir(dir,0700) && errno!=EEXIST)return -1;
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0)return errno==EEXIST?0:-1;
    int result=pjdv_profile_write_all(fd,b,n);if(!result)result=fsync(fd);
    int saved=errno;if(close(fd) && !result){result=-1;saved=errno;}
    if(result)unlink(path);errno=saved;return result;
}
// Returns -1 on I/O failure; unknown formats are logged and left untouched.
static int pjdv_profile_file(const char *dir,const char *backup_root){
    if(!pjdv_unlock_enabled())return 0;
    char path[1300],temp[1340];
    if(snprintf(path,sizeof path,"%s/sys.dat",dir)>=(int)sizeof path){errno=ENAMETOOLONG;return -1;}
    int fd=open(path,O_RDONLY);if(fd<0)return errno==ENOENT?0:-1;
    struct stat st;if(fstat(fd,&st) || st.st_size!=PJDV_PROFILE_BYTES){close(fd);LOG("PJDV unlock: unknown sys.dat size, left unchanged");return 0;}
    uint8_t *b=malloc(PJDV_PROFILE_BYTES);if(!b){close(fd);errno=ENOMEM;return -1;}
    size_t at=0;while(at<PJDV_PROFILE_BYTES){ssize_t got=read(fd,b+at,PJDV_PROFILE_BYTES-at);if(got<0 && errno==EINTR)continue;if(got<=0)break;at+=got;}
    close(fd);if(at!=PJDV_PROFILE_BYTES){free(b);errno=EIO;return -1;}
    uint8_t *updated=malloc(PJDV_PROFILE_BYTES);if(!updated){free(b);errno=ENOMEM;return -1;}
    memcpy(updated,b,PJDV_PROFILE_BYTES);PjdvUnlockChanges changes;
    if(!pjdv_profile_unlock(updated,PJDV_PROFILE_BYTES,&changes)){
        LOG("PJDV unlock: unknown profile layout, left unchanged");free(updated);free(b);return 0;
    }
    if(!memcmp(b,updated,PJDV_PROFILE_BYTES)){free(updated);free(b);return 0;}
    if(pjdv_profile_backup(backup_root,b,PJDV_PROFILE_BYTES)){free(updated);free(b);return -1;}
    free(b);
    snprintf(temp,sizeof temp,"%s.pjdv-unlock-XXXXXX",path);fd=mkstemp(temp);
    if(fd<0){free(updated);return -1;}
    int result=pjdv_profile_write_all(fd,updated,PJDV_PROFILE_BYTES);
    if(!result)result=fsync(fd);int saved=errno;
    if(close(fd) && !result){result=-1;saved=errno;}
    free(updated);
    if(!result && rename(temp,path)){result=-1;saved=errno;}
    if(result)unlink(temp);
    if(!result)LOG("PJDV unlock profile: songs=%u difficulty-flags=%u modules=%u items=%u (scores preserved)",changes.songs,changes.difficulties,changes.modules,changes.items);
    errno=saved;return result;
}
static void pjdv_profile_live(void){
    if(!pjdv_unlock_enabled())return;
    for(int i=0;i<g_nmod;i++){
        module_t *m=&g_mod[i];if(strcmp(m->name,"main"))continue;
        // Fingerprints from the analyzed JP v1.0.9 image. A different binary
        // must not turn these BSS offsets into arbitrary writes.
        uint32_t flag,module;memcpy(&flag,m->base+0xca300,4);memcpy(&module,m->base+0xc8850,4);
        if(flag!=0x39447400 || module!=0x8b21c408 || m->size<0x4d0f18c8ull+PJDV_PROFILE_BYTES){
            LOG("PJDV unlock: unsupported main layout, live profile unchanged");return;
        }
        PjdvUnlockChanges changes;
        if(pjdv_profile_unlock(m->base+0x4d0f18c8,PJDV_PROFILE_BYTES,&changes))
            LOG("PJDV unlock live: songs=%u difficulty-flags=%u modules=%u items=%u",changes.songs,changes.difficulties,changes.modules,changes.items);
        return;
    }
}

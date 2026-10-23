#include "/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm/host/pjdv_profile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static int allowed(size_t at,const uint8_t *before){
    if(at>=PJDV_MODULE_OFFSET && at<PJDV_MODULE_OFFSET+2048)return !((at-PJDV_MODULE_OFFSET)%2);
    if(at>=PJDV_ITEM_OFFSET && at<PJDV_ITEM_OFFSET+1536)return 1;
    for(unsigned i=0;i<300;i++){
        int32_t id;memcpy(&id,before+4+i*PJDV_SONG_BYTES,4);if(id<=0)continue;
        for(unsigned d=0;d<15;d++)if(at==8+i*PJDV_SONG_BYTES+d*0x120+0x11d)return 1;
    }
    return 0;
}
int main(int argc,char **argv){
    assert(argc==2);FILE *f=fopen(argv[1],"rb");assert(f);
    uint8_t *a=malloc(PJDV_PROFILE_BYTES),*b=malloc(PJDV_PROFILE_BYTES);
    assert(fread(a,1,PJDV_PROFILE_BYTES,f)==PJDV_PROFILE_BYTES && fgetc(f)==EOF);fclose(f);
    memcpy(b,a,PJDV_PROFILE_BYTES);PjdvUnlockChanges changes;
    assert(pjdv_profile_unlock(b,PJDV_PROFILE_BYTES,&changes));assert(changes.songs>0 && changes.difficulties>0);
    unsigned changed=0;for(size_t i=0;i<PJDV_PROFILE_BYTES;i++)if(a[i]!=b[i]){
        assert(allowed(i,a));if(i>=PJDV_MODULE_OFFSET)assert((a[i]^b[i])<=3);else assert(b[i]==1);changed++;
    }
    assert(changed);memcpy(a,b,PJDV_PROFILE_BYTES);
    assert(pjdv_profile_unlock(b,PJDV_PROFILE_BYTES,&changes));assert(!changes.difficulties && !changes.modules && !changes.items);
    assert(!memcmp(a,b,PJDV_PROFILE_BYTES));
    assert(!pjdv_profile_unlock(b,PJDV_PROFILE_BYTES-1,&changes));assert(!memcmp(a,b,PJDV_PROFILE_BYTES));
    uint32_t version=7;memcpy(b,&version,4);memcpy(a,b,PJDV_PROFILE_BYTES);
    assert(!pjdv_profile_unlock(b,PJDV_PROFILE_BYTES,&changes));assert(!memcmp(a,b,PJDV_PROFILE_BYTES));
    version=0;memcpy(b,&version,4);memcpy(b+4+PJDV_SONG_BYTES,b+4,4);memcpy(a,b,PJDV_PROFILE_BYTES);
    assert(!pjdv_profile_unlock(b,PJDV_PROFILE_BYTES,&changes));assert(!memcmp(a,b,PJDV_PROFILE_BYTES));
    // A native fresh-profile shape: no scores, unused slots -1, one registered
    // PV. No progress or records may be synthesized into the unused slots.
    memset(b,0,PJDV_PROFILE_BYTES);int32_t id=-1;
    for(unsigned i=0;i<300;i++)memcpy(b+4+i*PJDV_SONG_BYTES,&id,4);
    id=268;memcpy(b+4,&id,4);memcpy(a,b,PJDV_PROFILE_BYTES);
    assert(pjdv_profile_unlock(b,PJDV_PROFILE_BYTES,&changes));assert(changes.songs==1 && changes.difficulties==15);
    for(size_t i=0;i<PJDV_PROFILE_BYTES;i++)if(a[i]!=b[i])assert(allowed(i,a));
    free(a);free(b);puts("Profile unlock passed: real save score-byte preservation, ownership masks, all 15 difficulty slots, unused slots, idempotency, malformed input rejection and fresh-profile shape");
}

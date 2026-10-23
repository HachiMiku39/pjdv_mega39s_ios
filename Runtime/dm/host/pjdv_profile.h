// JP M39 v1.0.9 native sys.dat layout. Only progression availability changes.
// c9720 serializes 0x15264c raw bytes; c8850/c8870 locate module/item flags;
// ca300/ca310 read/set the difficulty flag in each 0x120-byte score entry.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
enum { PJDV_PROFILE_BYTES=0x15264c, PJDV_SONG_BYTES=0x11f4,
       PJDV_SONG_COUNT=300, PJDV_MODULE_OFFSET=4+0x1509f0,
       PJDV_ITEM_OFFSET=4+0x1511f0 };
typedef struct { unsigned songs,difficulties,modules,items; } PjdvUnlockChanges;
static int pjdv_profile_unlock(uint8_t *b,size_t n,PjdvUnlockChanges *changes){
    PjdvUnlockChanges out={0};
    if(changes)*changes=out;
    if(!b || n!=PJDV_PROFILE_BYTES)return 0;
    uint32_t version;memcpy(&version,b,4);if(version!=0)return 0;
    int32_t ids[PJDV_SONG_COUNT];unsigned valid=0;
    // Validate the entire layout before the first write. Empty native slots
    // use -1; zero or duplicate IDs indicate an uninitialized/unknown format.
    for(unsigned i=0;i<PJDV_SONG_COUNT;i++){
        memcpy(&ids[i],b+4+i*PJDV_SONG_BYTES,4);
        if(ids[i]==-1)continue;
        if(ids[i]<=0 || ids[i]>24575)return 0;
        for(unsigned j=0;j<i;j++)if(ids[i]==ids[j])return 0;
        valid++;
        for(unsigned d=0;d<15;d++)if(b[8+i*PJDV_SONG_BYTES+d*0x120+0x11d]>1)return 0;
    }
    if(!valid)return 0;
    out.songs=valid;
    for(unsigned i=0;i<PJDV_SONG_COUNT;i++)if(ids[i]!=-1)
        for(unsigned d=0;d<15;d++){
            uint8_t *flag=b+8+i*PJDV_SONG_BYTES+d*0x120+0x11d;
            if(!*flag){*flag=1;out.difficulties++;}
        }
    // The native initializer itself sets low bits 0/1 for owned/available,
    // then removes them for shop items. Preserve every other flag and byte.
    for(unsigned i=0;i<1024;i++){
        uint8_t *flag=b+PJDV_MODULE_OFFSET+i*2;
        if((*flag&3)!=3){*flag|=3;out.modules++;}
    }
    for(unsigned i=0;i<1536;i++){
        uint8_t *flag=b+PJDV_ITEM_OFFSET+i;
        if((*flag&3)!=3){*flag|=3;out.items++;}
    }
    if(changes)*changes=out;
    return 1;
}

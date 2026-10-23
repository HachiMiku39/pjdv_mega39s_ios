#pragma once
#include <stddef.h>
#include <string.h>
enum { PJDV_MAX_DLC = 256, PJDV_DLC_ENV_BYTES = 2048 };
// The Swift resource validator supplies the exact imported manifest. Reject
// the entire declaration on malformed, duplicate or out-of-range indexes.
static int pjdv_parse_dlc_indexes(const char *text,int out[PJDV_MAX_DLC]) {
    if(!text || strlen(text)>=PJDV_DLC_ENV_BYTES)return -1;
    if(!*text)return 0;
    int count=0;
    while(*text){
        if(count>=PJDV_MAX_DLC || *text<'1' || *text>'9')return -1;
        unsigned value=0,digits=0;
        while(*text>='0' && *text<='9'){
            if(++digits>4)return -1;
            value=value*10+(unsigned)(*text++-'0');
        }
        if(value>0xfff)return -1;
        for(int i=0;i<count;i++)if(out[i]==(int)value)return -1;
        out[count++]=(int)value;
        if(!*text)break;
        if(*text++!=',' || !*text)return -1;
    }
    for(int i=1;i<count;i++)for(int j=i;j>0 && out[j]<out[j-1];j--){int t=out[j];out[j]=out[j-1];out[j-1]=t;}
    return count;
}

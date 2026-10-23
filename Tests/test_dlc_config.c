#include "/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm/host/pjdv_dlc_config.h"
#include <assert.h>
#include <stdio.h>
int main(void){
    int indexes[PJDV_MAX_DLC];
    assert(pjdv_parse_dlc_indexes("",indexes)==0);
    assert(pjdv_parse_dlc_indexes("99,2,23",indexes)==3);
    assert(indexes[0]==2 && indexes[1]==23 && indexes[2]==99);
    assert(pjdv_parse_dlc_indexes("4095",indexes)==1 && indexes[0]==4095);
    const char *bad[]={"0","4096","-1","2,2","2,"," 2","2 3","2,,3","0001","x","1;99"};
    for(unsigned i=0;i<sizeof bad/sizeof *bad;i++)assert(pjdv_parse_dlc_indexes(bad[i],indexes)<0);
    char excessive[2048];memset(excessive,'1',sizeof excessive-1);excessive[sizeof excessive-1]=0;
    assert(pjdv_parse_dlc_indexes(excessive,indexes)<0);
    puts("PASS exact imported DLC list: empty, subset, new index, sorting, duplicates, range and malformed input");
}

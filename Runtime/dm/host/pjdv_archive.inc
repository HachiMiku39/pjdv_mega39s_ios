// Only the verified v1.0.9 common archive call uses this private service.
// It does not change archive layouts, resource bytes, or song selection.
#include "pjdv_archive.h"
static uint64_t pjdv_archive_gzip(uint64_t *r,uint64_t original){
    module_t *m=NULL;for(int i=0;i<g_nmod;i++)if(!strcmp(g_mod[i].name,"main"))m=&g_mod[i];
    if(!m || original!=0x1f0850)
        die("M39 archive gate at unexpected caller %#llx",original);
    typedef int (*decoder)(void *,uint64_t *,const void *,uint32_t);
    decoder guest=(decoder)(m->base+0x38430);
    static int mode=-1,verify=-1;
    if(mode<0)mode=getenv("PJDV_GZIP_ORIGINAL")!=NULL;
    if(verify<0)verify=getenv("PJDV_GZIP_VERIFY")!=NULL;
    void *out=(void *)r[0];uint64_t *size=(uint64_t *)r[1];
    const void *in=(const void *)r[2];uint32_t bytes=(uint32_t)r[3];
    uint64_t start=g_flag.bootprof?now_ns():0;
    int result;
    if(mode)result=guest(out,size,in,bytes);
    else if(verify && (uint32_t)*size<=128u*1024u*1024u){
        uint64_t capacity=*size,reference_size=capacity;
        void *reference=malloc((uint32_t)capacity?:1);
        if(!reference)die("M39 gzip verification allocation failed");
        uint64_t measured=now_ns();int expected=guest(reference,&reference_size,in,bytes);
        uint64_t guest_ns=now_ns()-measured;measured=now_ns();
        result=pjdv_gzip_decode(out,size,in,bytes);
        uint64_t native_ns=now_ns()-measured;
        if(result!=expected || *size!=reference_size ||
            (!result && memcmp(out,reference,(size_t)*size)))
            die("M39 gzip verification mismatch status=%d/%d size=%llu/%llu",result,expected,*size,reference_size);
        free(reference);
        LOG("PJDV gzip compare compressed=%u decoded=%llu original_ms=%.3f native_ms=%.3f status=%d",bytes,*size,guest_ns/1e6,native_ns/1e6,result);
    }else result=pjdv_gzip_decode(out,size,in,bytes);
    if(start)dm_prof_add(PROF_TACT,now_ns()-start,!result?*size:0);
    return (uint32_t)result;
}

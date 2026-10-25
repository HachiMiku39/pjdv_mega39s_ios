// Stage one: load signed guest sections and validate their native mapping.
// No game entry point is called until relocation and Horizon services exist.
#include "GuestLayout.h"
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

typedef struct { uint32_t name; uint8_t info,other;uint16_t shndx;uint64_t value,size; } GuestSymbol;
typedef struct { int64_t tag;uint64_t value; } GuestDynamic;
typedef struct { const pjdv_guest_layout *layout;vm_address_t allocation;uint8_t *base; } GuestMapping;
static GuestMapping images[8];
static pthread_key_t keys[8];
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static int loaded;

int pjdv_guest_autoplay_supported(void) {
    for (size_t i = 0; i < sizeof(pjdv_gates)/sizeof(*pjdv_gates); i++)
        if (pjdv_gates[i].arg == 0x91 && !strcmp(pjdv_gates[i].kind, "svc")) return 1;
    return 0;
}

static int remap(vm_address_t to, const void *source, uint64_t length, boolean_t copy, vm_prot_t need) {
    vm_address_t address=to;vm_prot_t cur=0,max=0;
    kern_return_t k=vm_remap(mach_task_self(),&address,length,0,VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE,
                                 mach_task_self(),(vm_address_t)source,copy,&cur,&max,VM_INHERIT_NONE);
    return k==KERN_SUCCESS && address==to && (cur&need)==need;
}

int pjdv_guest_load(char *error, size_t capacity) {
    pthread_mutex_lock(&state_lock);
    if (loaded) { pthread_mutex_unlock(&state_lock);return loaded==1; }
    const size_t count=sizeof(pjdv_layouts)/sizeof(pjdv_layouts[0]);
    if(count>8){snprintf(error,capacity,"Module count exceeds loader bound");goto fail;}
    for(int i=0;i<8;i++)if(pthread_key_create(&keys[i],NULL)){
        snprintf(error,capacity,"Cannot allocate guest thread slots");goto fail;
    }
    for(size_t i=0;i<count;i++){
        const pjdv_guest_layout *l=&pjdv_layouts[i];GuestMapping *m=&images[i];m->layout=l;
        if((uintptr_t)l->text%0x4000 || (uintptr_t)l->rw%0x4000 || (uintptr_t)l->patch%0x4000){
            snprintf(error,capacity,"%s signed section alignment mismatch",l->name);goto fail;
        }
        uint64_t total=l->prefix+l->virtual_bytes;
        if(vm_allocate(mach_task_self(),&m->allocation,total,VM_FLAGS_ANYWHERE)!=KERN_SUCCESS){
            snprintf(error,capacity,"%s virtual address reservation failed",l->name);goto fail;
        }
        m->base=(uint8_t *)(m->allocation+l->prefix);
        vm_protect(mach_task_self(),m->allocation,l->prefix,FALSE,VM_PROT_NONE);
        if(!remap((vm_address_t)m->base,l->text,l->text_pages,FALSE,VM_PROT_READ|VM_PROT_EXECUTE) ||
           !remap((vm_address_t)m->base+l->text_pages,l->rw,l->rw_pages,TRUE,VM_PROT_READ|VM_PROT_WRITE) ||
           !remap(m->allocation,l->patch,l->patch_pages,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)){
            snprintf(error,capacity,"%s signed section remap failed",l->name);goto fail;
        }
        uint64_t *page=(uint64_t *)(m->base+l->virtual_bytes-0x4000);
        for(int k=0;k<8;k++)page[k]=(uint64_t)keys[k]*8;
        if(vm_protect(mach_task_self(),(vm_address_t)page,0x4000,FALSE,VM_PROT_READ)!=KERN_SUCCESS){
            snprintf(error,capacity,"%s key page protection failed",l->name);goto fail;
        }
        fprintf(stderr,"[PJDV] mapped %s: virtual=%llu initialized=%llu BSS=anonymous\n",l->name,
                (unsigned long long)l->virtual_bytes,(unsigned long long)(l->text_pages+l->rw_pages));
    }
    loaded=1;pthread_mutex_unlock(&state_lock);return 1;
fail:
    for(size_t i=0;i<8;i++)if(images[i].allocation){
        vm_deallocate(mach_task_self(),images[i].allocation,images[i].layout->prefix+images[i].layout->virtual_bytes);
        images[i].allocation=0;images[i].base=NULL;
    }
    loaded=-1;pthread_mutex_unlock(&state_lock);return 0;
}

static void *symbol(GuestMapping *m,const char *wanted){
    uint64_t limit=m->layout->text_pages+m->layout->rw_pages;
    uint32_t mod0;memcpy(&mod0,m->base+4,4);
    if(mod0+8>limit || memcmp(m->base+mod0,"MOD0",4))return NULL;
    int32_t delta;memcpy(&delta,m->base+mod0+4,4);
    int64_t dyn=(int64_t)mod0+delta;if(dyn<0 || (uint64_t)dyn>=limit)return NULL;
    uint64_t sym=0,str=0,strsize=0;
    for(uint64_t at=(uint64_t)dyn;at+16<=limit;at+=16){
        GuestDynamic d;memcpy(&d,m->base+at,16);if(!d.tag)break;
        if(d.tag==6)sym=d.value;if(d.tag==5)str=d.value;if(d.tag==10)strsize=d.value;
    }
    if(!sym || str<=sym || str+strsize>limit)return NULL;
    for(uint64_t at=sym;at+sizeof(GuestSymbol)<=str;at+=sizeof(GuestSymbol)){
        GuestSymbol s;memcpy(&s,m->base+at,sizeof s);
        if(!s.shndx || (s.info&15)!=2 || s.name>=strsize || s.value>=m->layout->text_pages)continue;
        const char *name=(const char *)m->base+str+s.name;
        if(!memchr(name,0,strsize-s.name))return NULL;
        if(!strcmp(name,wanted))return m->base+s.value;
    }
    return NULL;
}

int pjdv_guest_math_probe(void) {
#if defined(__aarch64__) || defined(__arm64__)
    if(loaded!=1)return 0;
    size_t count=sizeof(pjdv_layouts)/sizeof(pjdv_layouts[0]);
    for(size_t i=0;i<count;i++)if(!strcmp(images[i].layout->name,"sdk")){
        float(*fn)(float)=symbol(&images[i],"sqrtf");
        if(!fn)return 0;
        float result=fn(4.0f);
        fprintf(stderr,"[PJDV] native guest sdk sqrtf(4)=%g\n",result);
        return result==2.0f;
    }
#endif
    return 0;
}

// Metadata and thread keys are shared with the Horizon runtime. Keys in signed
// thunks must match the read-only key page written by the sparse mapper.
size_t pjdv_guest_count(void) { return loaded==1 ? sizeof(pjdv_layouts)/sizeof(pjdv_layouts[0]) : 0; }
void *pjdv_guest_base(size_t i) { return i<pjdv_guest_count() ? images[i].base : NULL; }
const pjdv_guest_layout *pjdv_guest_layout_at(size_t i) { return i<pjdv_guest_count() ? images[i].layout : NULL; }
pthread_key_t pjdv_guest_key(unsigned i) { return i<8 ? keys[i] : 0; }

// Caller has joined/drained every guest thread, decoder, AudioUnit and GPU
// completion. Keep signed text and virtual addresses stable; recreate data/BSS
// from pristine COW pages, so cached native SDK function addresses stay valid.
int pjdv_guest_reset(char *error,size_t capacity) {
    pthread_mutex_lock(&state_lock);
    if(loaded!=1){snprintf(error,capacity,"Guest images are not mapped");pthread_mutex_unlock(&state_lock);return 0;}
    for(size_t i=0;i<sizeof(pjdv_layouts)/sizeof(*pjdv_layouts);i++){
        GuestMapping *m=&images[i];const pjdv_guest_layout *l=m->layout;
        vm_address_t start=(vm_address_t)m->base+l->text_pages;
        vm_size_t bytes=l->virtual_bytes-l->text_pages-0x4000;
        vm_address_t address=start;
        kern_return_t k=vm_allocate(mach_task_self(),&address,bytes,VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE);
        if(k!=KERN_SUCCESS || address!=start || !remap(start,l->rw,l->rw_pages,TRUE,VM_PROT_READ|VM_PROT_WRITE)){
            snprintf(error,capacity,"%s data reset failed (%d)",l->name,k);pthread_mutex_unlock(&state_lock);return 0;
        }
    }
    pthread_mutex_unlock(&state_lock);return 1;
}

// Metal replaces nvdrv setup. SetGraphicsAllocator remains in the original SDK:
// it only installs callback tables, also used by NvOsAlloc in the AAC decoder.
// Replacing that registration with a host-only copy leaves those SDK tables
// uninitialized and makes android::HeapObject::operator new return NULL.
#include "../host/hle.h"
#include <stdatomic.h>
#include <errno.h>

typedef void *(*nv_alloc_fn)(unsigned long size, unsigned long align, void *user);
typedef void (*nv_free_fn)(void *p, void *user);
typedef void *(*nv_realloc_fn)(void *p, unsigned long size, void *user);
struct nv_allocator { nv_alloc_fn alloc; nv_free_fn free; nv_realloc_fn realloc; void *user; };
struct nv_allocator g_nv_devtools_alloc;

#define WHY "Metal owns GPU driver setup; no Nintendo nvdrv service"
HLE_FORCE("_ZN2nv28SetGraphicsDevtoolsAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_", WHY "；分配器记入 g_nv_devtools_alloc",
          void, h_nv_SetDevAlloc, nv_alloc_fn a, nv_free_fn f, nv_realloc_fn r, void *u) { g_nv_devtools_alloc = (struct nv_allocator){a, f, r, u}; }
HLE_FORCE("_ZN2nv18InitializeGraphicsEPvm", WHY, void, h_nv_Init, void *mem, unsigned long size) { (void)mem; (void)size; }
HLE_FORCE("_ZN2nv16FinalizeGraphicsEv", WHY, void, h_nv_Fin, void) {}

// Video OMX plugins also call the Nintendo GPU driver. Return the ordinary
// failed-open value so their software decoder fallback can run; never enter
// the SDK's uninitialized nvdrv IPC client.
HLE_FORCE("NvOsDrvOpen", "Nintendo device nodes are unavailable; let OMX choose a software decoder", int, h_nv_DrvOpen, const char *path) {
    static _Atomic int reported;
    if(!atomic_exchange(&reported,1))LOG("PJDV Nintendo video driver unavailable: %s; software decoder fallback requested",path?path:"(null)");
    errno=ENOTSUP;
    return -1;
}

// Select the software codec before ACodec records the component identity.
// Replacing only NVOMXPlugin::makeComponentInstance leaves the Nvidia name
// and native-window quirks attached to a Google component, which cannot be
// configured consistently. Keep the SDK's own factory, callbacks and lifetime.
HLE_FORCE("_ZN7android8OMXCodec18findMatchingCodecsEPKcbS2_jPNS_6VectorINS_7String8EEE", "Select the SDK software H.264 decoder with its correct component metadata on Apple platforms", void, h_nv_FindCodecs, const char *mime,int encoder,const char *match,uint32_t flags,void *out) {
    typedef void (*find_fn)(const char *,int,const char *,uint32_t,void *);
    find_fn find=(find_fn)guest_sym("_ZN7android8OMXCodec18findMatchingCodecsEPKcbS2_jPNS_6VectorINS_7String8EEE");
    if(!find || find==(find_fn)h_nv_FindCodecs)die("Original OMX codec selection is unavailable");
    if(mime && !encoder && flags==0 && !strcasecmp(mime,"video/avc") && (!match || !strcmp(match,"OMX.Nvidia.h264.decode"))) {
        // Nintendo's codec preference table lists only Tegra AVC even though
        // SoftOMXPlugin includes a working Google AVC factory. Build the result
        // with the SDK's String8/Vector methods so its C++ ownership is intact.
        typedef void (*clear_fn)(void *);
        typedef void (*string_ctor_fn)(void *,const char *);
        typedef void (*string_dtor_fn)(void *);
        typedef long (*push_fn)(void *,const void *);
        clear_fn clear=(clear_fn)guest_sym("_ZN7android10VectorImpl5clearEv");
        string_ctor_fn ctor=(string_ctor_fn)guest_sym("_ZN7android7String8C1EPKc");
        string_dtor_fn dtor=(string_dtor_fn)guest_sym("_ZN7android7String8D1Ev");
        push_fn push=(push_fn)guest_sym("_ZN7android10VectorImpl4pushEPKv");
        if(!out || !clear || !ctor || !dtor || !push)die("Native OMX codec list methods are missing");
        void *name=NULL; // String8 contains one pointer in the shipped SDK ABI.
        clear(out);
        ctor(&name,"OMX.google.h264.decoder");
        long index=push(out,&name);
        dtor(&name);
        if(index<0)die("Native OMX software codec list allocation failed: %ld",index);
        LOG("PJDV H.264 selecting OMX.google.h264.decoder before allocation");
        return;
    }
    find(mime,encoder,match,flags,out);
}
HLE_FORCE("_ZN7android6ACodec14configureCodecEPKcRKNS_2spINS_8AMessageEEE", "Record native media configuration results for black-screen diagnostics", int, h_nv_CodecConfigure,void *codec,const char *mime,const void *message) {
    typedef int (*configure_fn)(void *,const char *,const void *);
    configure_fn configure=(configure_fn)guest_sym("_ZN7android6ACodec14configureCodecEPKcRKNS_2spINS_8AMessageEEE");
    if(!configure || configure==(configure_fn)h_nv_CodecConfigure)die("Original codec configuration is unavailable");
    int result=configure(codec,mime,message);
    LOG("PJDV codec configure mime=%s result=%d",mime?mime:"(null)",result);
    return result;
}
HLE_FORCE("_ZN7android6ACodec17setupVideoDecoderEPKcRKNS_2spINS_8AMessageEEEb", "Trace native video port configuration without suppressing decoder failures", int, h_nv_VideoConfigure,void *codec,const char *mime,const void *message,int native_buffers) {
    typedef int (*setup_fn)(void *,const char *,const void *,int);
    setup_fn setup=(setup_fn)guest_sym("_ZN7android6ACodec17setupVideoDecoderEPKcRKNS_2spINS_8AMessageEEEb");
    if(!setup || setup==(setup_fn)h_nv_VideoConfigure)die("Original video configuration is unavailable");
    int result=setup(codec,mime,message,native_buffers);
    LOG("PJDV video setup mime=%s native_buffers=%d result=%d",mime?mime:"(null)",native_buffers&1,result);
    return result;
}
HLE_FORCE("_ZN7android16SoftOMXComponent6notifyE13OMX_EVENTTYPEjjPv", "Expose the native decoder OMX error while preserving its notification", void, h_nv_OMXNotify,void *component,uint32_t event,uint32_t data1,uint32_t data2,void *data) {
    if(event==1) {
        void *caller=__builtin_return_address(0);module_t *m=module_of(caller);
        LOG("PJDV OMX decoder error=%#x detail=%#x caller=%s+%#llx",data1,data2,m?m->name:"host",m?(uint64_t)caller-(uint64_t)m->base:0);
    }
    typedef void (*notify_fn)(void *,uint32_t,uint32_t,uint32_t,void *);
    notify_fn notify=(notify_fn)guest_sym("_ZN7android16SoftOMXComponent6notifyE13OMX_EVENTTYPEjjPv");
    if(!notify || notify==(notify_fn)h_nv_OMXNotify)die("Original OMX notification is unavailable");
    notify(component,event,data1,data2,data);
}

// The shipped Android logger formats messages but does not emit them. Keep
// variadic arguments as raw register values, avoiding the Darwin va_list ABI.
HLE_FORCE("__android_log_print", "Expose media warnings for codec diagnostics without parsing guest varargs", int, h_nv_AndroidLog, int priority,const char *tag,const char *format,uint64_t a3,uint64_t a4,uint64_t a5,uint64_t a6,uint64_t a7) {
    if(priority>=5)LOG("PJDV Android[%d] %s: %s args=%#llx/%#llx/%#llx/%#llx/%#llx",priority,tag?tag:"",format?format:"",a3,a4,a5,a6,a7);
    return 1;
}
HLE_FORCE("_ZN7android6ACodec11signalErrorE13OMX_ERRORTYPEi", "Diagnose media errors then forward the original error notification", void, h_nv_CodecError, void *codec,uint32_t error,int internal) {
    void *caller=__builtin_return_address(0);module_t *m=module_of(caller);
    LOG("PJDV codec error=%#x internal=%d caller=%s+%#llx",error,internal,m?m->name:"host",m?(uint64_t)caller-(uint64_t)m->base:0);
    typedef void (*error_fn)(void *,uint32_t,int);
    error_fn notify=(error_fn)guest_sym("_ZN7android6ACodec11signalErrorE13OMX_ERRORTYPEi");
    if(!notify || notify==(error_fn)h_nv_CodecError)die("Original codec error notification is unavailable");
    notify(codec,error,internal);
}

HLE_FORCE("_ZN2nv26InitializeGraphicsDevtoolsEPvm", "NVN is executed by Metal; Nintendo debug driver is replaced", void, h_nv_InitDevtools, void *mem, unsigned long size) {(void)mem;(void)size;}
HLE_FORCE("_ZN2nv24FinalizeGraphicsDevtoolsEv", "Host Metal owns graphics debug resources", void, h_nv_FinDevtools, void) {}

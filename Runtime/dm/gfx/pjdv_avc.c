// Apple AVC backend for the SDK's H264SwDec API. The original OMX component
// retains buffer allocation, timestamps, port changes and callbacks. ABI field
// layouts were checked against the shipped SDK and the public AOSP header.
#include "../host/hle.h"
#include <VideoToolbox/VideoToolbox.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <stdatomic.h>

typedef struct { const uint8_t *bytes; uint32_t size,id,concealment; } avc_input;
typedef struct { const uint8_t *position; } avc_output;
typedef struct { uint8_t *pixels; uint32_t id,idr,errors; } avc_picture;
typedef struct { uint32_t profile,width,height,range,matrix,par_width,par_height,crop,left,crop_width,top,crop_height; } avc_info;
typedef struct avc_frame { struct avc_frame *next; uint8_t *pixels; uint32_t id,idr; int64_t pts; } avc_frame;
typedef struct {
    pthread_mutex_t lock;
    pthread_t worker;pthread_mutex_t work_lock;pthread_cond_t work_condition;
    int job,done,result;const avc_input *job_input;avc_output *job_output;
    uint8_t *sps,*pps;size_t sps_size,pps_size;
    CMVideoFormatDescriptionRef format;
    VTDecompressionSessionRef session;
    avc_info info;
    avc_frame *head,*tail,*last;
    uint32_t queued,decoded,reorder;int flushing;
    OSStatus error;
} avc_decoder;
static avc_decoder *avc_owned[16];
static pthread_mutex_t avc_owned_lock=PTHREAD_MUTEX_INITIALIZER;
typedef struct { uint32_t id,idr; int64_t pts; } avc_token;
HLE_FORCE("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi", "Record the title's requested movie decoder output layout", void,h_avc_DecoderCtor,void *self,int type,int format,int mode,int priority){
    typedef void (*ctor_fn)(void *,int,int,int,int);
    ctor_fn fn=(ctor_fn)guest_sym("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi");
    if(!fn || fn==(ctor_fn)h_avc_DecoderCtor)die("Original movie decoder constructor unavailable");
    fn(self,type,format,mode,priority);
    LOG("PJDV movie decoder type=%d requested_format=%d mode=%d implementation=%p",type,format,mode,*(void **)((uint8_t *)self+8));
}
// The SDK's software GetOutputBuffer path copies a planar OMX payload as if
// it already contained NV12. Fix that client boundary, not H264SwDecNextPicture:
// SoftAVC's own output copy still requires the original planar contract.
// Field offsets and both public callers' PLT references were verified against
// this title's subsdk1; native allocation, range and timestamps stay in charge.
static void avc_client_nv12(void *self,void *buffer,int color,int stride,int slice){
    const uint8_t *impl=self;
    if(!impl || !buffer || *(const int *)(impl+0xe0)!=1 ||
       *(const int *)(impl+0xdc)!=4 || *(const int *)(impl+0xe4)!=1)return;
    uint8_t *b=buffer,*base=*(uint8_t **)(b+0x28);
    int offset=*(const int *)(b),bytes=*(const int *)(b+4);
    uint64_t capacity=*(const uint64_t *)(b+0x18);
    if(!bytes)return; // Empty EOS carries no image.
    int w=*(const int *)(impl+0x38),h=*(const int *)(impl+0x3c);
    if(color==21)return; // OMX_COLOR_FormatYUV420SemiPlanar is already NV12.
    // SoftAVC copies the visible picture into a packed output range, while its
    // port metadata can retain the coded macroblock height (1088 for 1080p).
    // Validate the actual range below; do not mistake that metadata for padding
    // in the returned payload or move the chroma planes by eight extra rows.
    if(color!=19 || w<=0 || h<=0 || w>4096 || h>4096 || (w&1) || (h&1) || stride!=w || slice<h || slice>4096 || (slice&1) ||
       offset<0 || (uint64_t)offset>capacity || !base ||
       (uint64_t)bytes>capacity-(uint64_t)offset || (uint64_t)bytes!=(uint64_t)w*h*3/2)
        die("PJDV unsupported movie client layout: format=%d dimensions=%dx%d stride=%d slice=%d bytes=%d offset=%d capacity=%llu",color,w,h,stride,slice,bytes,offset,capacity);
    size_t ysize=(size_t)w*h,chroma=ysize/4;
    uint8_t *dst=base+offset+ysize,*uv=malloc(chroma*2);
    if(!uv)die("PJDV movie chroma conversion allocation failed");
    for(size_t i=0;i<chroma;i++){uv[2*i]=dst[i];uv[2*i+1]=dst[chroma+i];}
    memcpy(dst,uv,chroma*2);free(uv);
    static _Atomic unsigned count;unsigned n=atomic_fetch_add(&count,1)+1;
    if(n<=6)LOG("PJDV movie client planar->NV12 n=%u %dx%d bytes=%d source_color_format=%d",n,w,h,bytes,color);
    if((n==50 || n==200) && getenv("DM_TEMP")){
        char path[1500];snprintf(path,sizeof path,"%s/pjdv-client-%u.nv12",getenv("DM_TEMP"),n);
        FILE *f=fopen(path,"wb");if(f){fwrite(base+offset,1,bytes,f);fclose(f);LOG("PJDV NV12 client diagnostic saved n=%u",n);}
    }
}
HLE_FORCE("_ZN5movie11DecoderImpl15GetOutputBufferEiPNS_6BufferE", "Interleave planar software AVC output when the client requested NV12", int,h_avc_Output,void *self,int index,void *buffer){
    typedef int (*output_fn)(void *,int,void *);
    output_fn fn=(output_fn)guest_sym("_ZN5movie11DecoderImpl15GetOutputBufferEiPNS_6BufferE");
    if(!fn || fn==(output_fn)h_avc_Output)die("Original movie output method unavailable");
    int result=fn(self,index,buffer);
    const uint8_t *impl=self;
    if(!result && impl && buffer && *(const int *)(impl+0xe0)==1 &&
       *(const int *)(impl+0xdc)==4 && *(const int *)(impl+0xe4)==1 && *(const int *)((uint8_t *)buffer+4)>0){
        typedef int (*format_fn)(void *,uint64_t,void **);
        typedef int (*find_fn)(const void *,const char *,int *);
        typedef void (*release_fn)(const void *,const void *);
        format_fn get_format=(format_fn)guest_sym("_ZN7android10MediaCodec15getOutputFormatEmPNS_2spINS_8AMessageEEE");
        find_fn find=(find_fn)guest_sym("_ZNK7android8AMessage9findInt32EPKcPi");
        release_fn release=(release_fn)guest_sym("_ZNK7android7RefBase9decStrongEPKv");
        void *message=NULL;int color=0,stride=0,slice=0;
        if(!get_format || !find || !release || get_format(*(void *const *)(impl+8),(uint64_t)index,&message) || !message)
            die("PJDV movie output format query failed");
        int found=find(message,"color-format",&color)&1;
        found&=find(message,"stride",&stride)&1;
        found&=find(message,"slice-height",&slice)&1;
        release(message,&message);
        if(!found)die("PJDV movie output layout metadata missing");
        avc_client_nv12(self,buffer,color,stride,slice);
    }
    return result;
}
enum { AVC_JOB_NONE,AVC_JOB_DECODE,AVC_JOB_FLUSH,AVC_JOB_STOP };
static int avc_decode(avc_decoder *,const avc_input *,avc_output *);
static void *avc_worker(void *);
static int avc_job(avc_decoder *,int,const avc_input *,avc_output *);

// OMX timestamps are in microseconds. Capture them before the native component
// queues the buffer; H264SwDecInput carries only a picture ID, so otherwise B
// pictures would be returned in decode order and break the movie's sorted queue.
static pthread_mutex_t avc_stamp_lock=PTHREAD_MUTEX_INITIALIZER;
static struct { const uint8_t *start;size_t size;int64_t pts; } avc_stamps[256];
static uint32_t avc_stamp_next;
HLE_FORCE("_ZN7android16SoftOMXComponent20notifyFillBufferDoneEP20OMX_BUFFERHEADERTYPE", "Trace real decoded OMX output timestamps while forwarding the original callback", void,h_avc_Filled,void *component,const uint8_t *header){
    static pthread_mutex_t log_lock=PTHREAD_MUTEX_INITIALIZER;
    static struct{void *component;unsigned count;int64_t last_pts;int has_pts,closed;} counters[16];unsigned count=0;int adjusted=0;
    uint32_t bytes=header?*(const uint32_t *)(header+0x14):0,flags=header?*(const uint32_t *)(header+0x60):0;
    int64_t pts=header?*(const int64_t *)(header+0x58):0;
    pthread_mutex_lock(&log_lock);int slot=-1;
    for(unsigned i=0;i<16;i++)if(counters[i].component==component){slot=(int)i;break;}
    if(slot<0)for(unsigned i=0;i<16;i++)if(!counters[i].component || counters[i].closed){memset(&counters[i],0,sizeof counters[i]);counters[i].component=component;slot=(int)i;break;}
    if(slot>=0){
        count=++counters[slot].count;
        if(bytes){counters[slot].last_pts=pts;counters[slot].has_pts=1;counters[slot].closed=0;}
        else if(flags&1){
            // A zero-byte OMX EOS buffer has no picture timestamp. The Google
            // component resets it to zero; the native movie's ordered frame
            // queue requires the EOS marker after its last picture instead.
            if(counters[slot].has_pts && pts<counters[slot].last_pts){pts=counters[slot].last_pts;memcpy((uint8_t *)header+0x58,&pts,sizeof pts);adjusted=1;}
            counters[slot].closed=1;
        }
    }
    pthread_mutex_unlock(&log_lock);
    if(count==50 && bytes==1280*720*3/2 && getenv("DM_TEMP")){
        const uint8_t *base=*(const uint8_t *const *)(header+8);uint32_t capacity=*(const uint32_t *)(header+0x10),offset=*(const uint32_t *)(header+0x18);
        if(base && offset<=capacity && bytes<=capacity-offset){
            char path[1500];snprintf(path,sizeof path,"%s/pjdv-omx-%llx-frame50.yuv",getenv("DM_TEMP"),(unsigned long long)(uintptr_t)component);
            FILE *f=fopen(path,"wb");if(f){fwrite(base+offset,1,bytes,f);fclose(f);LOG("PJDV OMX diagnostic frame saved pts=%lld bytes=%u",pts,bytes);}
        }
    }
    if(adjusted)LOG("PJDV OMX empty EOS timestamp aligned to last output: %lld",pts);
    if(count && count<=12 && header)LOG("PJDV OMX output component=%p n=%u bytes=%u pts=%lld flags=%#x",component,count,*(const uint32_t *)(header+0x14),*(const int64_t *)(header+0x58),*(const uint32_t *)(header+0x60));
    typedef void (*filled_fn)(void *,const void *);
    filled_fn filled=(filled_fn)guest_sym("_ZN7android16SoftOMXComponent20notifyFillBufferDoneEP20OMX_BUFFERHEADERTYPE");
    if(!filled || filled==(filled_fn)h_avc_Filled)die("Original OMX output callback is missing");filled(component,header);
}
HLE_FORCE("_ZN7android22SimpleSoftOMXComponent15emptyThisBufferEP20OMX_BUFFERHEADERTYPE", "Preserve native OMX presentation timestamps for AVC display ordering", uint32_t,h_avc_Empty,void *component,const uint8_t *header){
    if(header && *(const uint32_t *)header>=0x70){
        const uint8_t *base=*(const uint8_t *const *)(header+8);
        uint32_t size=*(const uint32_t *)(header+0x14),offset=*(const uint32_t *)(header+0x18),capacity=*(const uint32_t *)(header+0x10);
        if(base && offset<=capacity && size<=capacity-offset){
            pthread_mutex_lock(&avc_stamp_lock);uint32_t slot=avc_stamp_next++%256;
            avc_stamps[slot].start=base+offset;avc_stamps[slot].size=size;avc_stamps[slot].pts=*(const int64_t *)(header+0x58);pthread_mutex_unlock(&avc_stamp_lock);
        }
    }
    typedef uint32_t (*empty_fn)(void *,const void *);
    empty_fn empty=(empty_fn)guest_sym("_ZN7android22SimpleSoftOMXComponent15emptyThisBufferEP20OMX_BUFFERHEADERTYPE");
    if(!empty || empty==(empty_fn)h_avc_Empty)die("Original OMX input queue is missing");return empty(component,header);
}
static int avc_timestamp(const uint8_t *p,size_t size,int64_t *pts){
    int found=0;pthread_mutex_lock(&avc_stamp_lock);
    for(uint32_t i=0;i<256;i++){
        uint32_t slot=(avc_stamp_next-1-i)%256;uintptr_t a=(uintptr_t)avc_stamps[slot].start,b=(uintptr_t)p;
        if(a && b>=a && b-a<=avc_stamps[slot].size && size<=avc_stamps[slot].size-(b-a)){*pts=avc_stamps[slot].pts;found=1;break;}
    }
    pthread_mutex_unlock(&avc_stamp_lock);return found;
}
typedef struct { uint8_t data[2048];size_t size,bit;int bad; } avc_bits;
static uint32_t avc_read(avc_bits *b,unsigned n){uint32_t v=0;if(n>32 || b->bit+n>b->size*8){b->bad=1;return 0;}while(n--){v=(v<<1)|((b->data[b->bit/8]>>(7-b->bit%8))&1);b->bit++;}return v;}
static uint32_t avc_ue(avc_bits *b){unsigned zero=0;while(!b->bad && !avc_read(b,1)){if(++zero>30){b->bad=1;return 0;}}return zero?((1u<<zero)-1)+avc_read(b,zero):0;}
static int32_t avc_se(avc_bits *b){uint32_t v=avc_ue(b);return v&1?(int32_t)((v+1)/2):-(int32_t)(v/2);}
static unsigned avc_reorder_depth(const uint8_t *sps,size_t n){
    avc_bits b={0};unsigned zeros=0;
    for(size_t i=1;i<n;i++){if(zeros==2 && sps[i]==3){zeros=0;continue;}if(b.size==sizeof(b.data))return 16;b.data[b.size++]=sps[i];zeros=sps[i]?0:zeros+1;}
    uint32_t profile=avc_read(&b,8);avc_read(&b,16);avc_ue(&b);
    if(profile==100 || profile==110 || profile==122 || profile==244 || profile==44 || profile==83 || profile==86 || profile==118 || profile==128 || profile==138 || profile==139 || profile==134 || profile==135){
        uint32_t chroma=avc_ue(&b);if(chroma==3)avc_read(&b,1);avc_ue(&b);avc_ue(&b);avc_read(&b,1);
        if(avc_read(&b,1))for(unsigned i=0;i<(chroma==3?12:8);i++)if(avc_read(&b,1)){int last=8,next=8;for(unsigned j=0;j<(i<6?16:64);j++){if(next)next=(last+avc_se(&b)+256)%256;last=next?next:last;}}
    }
    avc_ue(&b);uint32_t poc=avc_ue(&b);
    if(!poc)avc_ue(&b);else if(poc==1){avc_read(&b,1);avc_se(&b);avc_se(&b);uint32_t count=avc_ue(&b);if(count>256)return 16;while(count--)avc_se(&b);}
    uint32_t refs=avc_ue(&b);return b.bad?16:profile==66?0:refs>16?16:refs;
}

static void avc_frame_free(avc_frame *f){if(f){free(f->pixels);free(f);}}
static void avc_clear_frames(avc_decoder *d){
    avc_frame *f=d->head;while(f){avc_frame *n=f->next;avc_frame_free(f);f=n;}
    avc_frame_free(d->last);d->head=d->tail=d->last=NULL;d->queued=0;
}
static void avc_stop_session(avc_decoder *d){
    if(d->session){VTDecompressionSessionWaitForAsynchronousFrames(d->session);VTDecompressionSessionInvalidate(d->session);CFRelease(d->session);d->session=NULL;}
    if(d->format){CFRelease(d->format);d->format=NULL;}
}
static void avc_decoded(void *opaque,void *ref,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef image,CMTime pts,CMTime duration){
    (void)flags;(void)pts;(void)duration;
    avc_decoder *d=opaque;avc_token *token=ref;
    if(status || !image){if(status){pthread_mutex_lock(&d->lock);d->error=status;pthread_mutex_unlock(&d->lock);LOG("PJDV VideoToolbox callback error=%d",(int)status);}free(token);return;}
    size_t w=CVPixelBufferGetWidth(image),h=CVPixelBufferGetHeight(image);
    if(CVPixelBufferGetPixelFormatType(image)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || CVPixelBufferGetPlaneCount(image)!=2 || w>d->info.width || h>d->info.height){
        pthread_mutex_lock(&d->lock);d->error=kVTVideoDecoderUnsupportedDataFormatErr;pthread_mutex_unlock(&d->lock);free(token);return;
    }
    avc_frame *f=calloc(1,sizeof(*f));size_t ysize=(size_t)d->info.width*d->info.height;
    if(f)f->pixels=malloc(ysize+ysize/2);
    if(!f || !f->pixels){avc_frame_free(f);pthread_mutex_lock(&d->lock);d->error=kCVReturnAllocationFailed;pthread_mutex_unlock(&d->lock);free(token);return;}
    f->id=token->id;f->idr=token->idr;f->pts=token->pts;free(token);
    memset(f->pixels,16,ysize);memset(f->pixels+ysize,128,ysize/2);
    CVReturn err=CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
    if(err){avc_frame_free(f);pthread_mutex_lock(&d->lock);d->error=err;pthread_mutex_unlock(&d->lock);return;}
    const uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(image,0),*uv=CVPixelBufferGetBaseAddressOfPlane(image,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(image,0),uvs=CVPixelBufferGetBytesPerRowOfPlane(image,1),stride=d->info.width;
    for(size_t row=0;row<h;row++)memcpy(f->pixels+row*stride,y+row*ys,w);
    uint8_t *u=f->pixels+ysize,*v=u+ysize/4;
    for(size_t row=0;row<(h+1)/2;row++)for(size_t col=0;col<(w+1)/2;col++){u[row*(stride/2)+col]=uv[row*uvs+col*2];v[row*(stride/2)+col]=uv[row*uvs+col*2+1];}
    CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
    pthread_mutex_lock(&d->lock);
    if(d->queued>=32){d->error=kVTVideoDecoderBadDataErr;pthread_mutex_unlock(&d->lock);avc_frame_free(f);return;}
    avc_frame **at=&d->head;while(*at && (*at)->pts<=f->pts)at=&(*at)->next;f->next=*at;*at=f;
    if(!f->next)d->tail=f;d->queued++;d->decoded++;
    uint32_t count=d->decoded;pthread_mutex_unlock(&d->lock);
    if(count<=8 || count%300==0)LOG("PJDV VideoToolbox decoded frame=%u %zux%zu",count,w,h);
}
static OSStatus avc_start_session(avc_decoder *d){
    avc_stop_session(d);
    const uint8_t *sets[]={d->sps,d->pps};size_t sizes[]={d->sps_size,d->pps_size};
    OSStatus err=CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,2,sets,sizes,4,&d->format);
    if(err)return err;
    CMVideoDimensions dim=CMVideoFormatDescriptionGetDimensions(d->format);
    if(dim.width<=0 || dim.height<=0 || dim.width>4096 || dim.height>4096)return kVTVideoDecoderUnsupportedDataFormatErr;
    d->info=(avc_info){.profile=d->sps_size>1?d->sps[1]:0,.width=(dim.width+15)&~15u,.height=(dim.height+15)&~15u,.range=0,.matrix=1,.par_width=1,.par_height=1,.crop=1,.crop_width=dim.width,.crop_height=dim.height};
    d->reorder=avc_reorder_depth(d->sps,d->sps_size);d->flushing=0;
    int32_t fmt=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef number=CFNumberCreate(NULL,kCFNumberSInt32Type,&fmt);
    const void *keys[]={kCVPixelBufferPixelFormatTypeKey};const void *values[]={number};
    CFDictionaryRef attributes=CFDictionaryCreate(NULL,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord callback={avc_decoded,d};
    err=VTDecompressionSessionCreate(NULL,d->format,NULL,attributes,&callback,&d->session);
    CFRelease(attributes);CFRelease(number);
    LOG("PJDV VideoToolbox create profile=%u size=%ux%u reorder=%u result=%d",d->info.profile,d->info.width,d->info.height,d->reorder,(int)err);
    return err;
}
static size_t avc_start_code(const uint8_t *p,size_t n,size_t from,size_t *prefix){
    for(size_t i=from;i+2<n;i++)if(!p[i] && !p[i+1]){
        if(p[i+2]==1){*prefix=3;return i;}
        if(i+3<n && !p[i+2] && p[i+3]==1){*prefix=4;return i;}
    }
    *prefix=0;return n;
}
static int avc_parameter(uint8_t **dst,size_t *length,const uint8_t *src,size_t n){
    if(*length==n && *dst && !memcmp(*dst,src,n))return 0;
    uint8_t *copy=malloc(n);if(!copy)return -1;memcpy(copy,src,n);free(*dst);*dst=copy;*length=n;return 1;
}
HLE_FORCE("H264SwDecInit", "Use Apple's AVC decoder for Main/High Profile videos unsupported by the SDK Baseline decoder", int, h_avc_Init,void **out,uint32_t no_reorder){
    (void)no_reorder;if(!out)return -1;*out=NULL;avc_decoder *d=calloc(1,sizeof(*d));if(!d)return -4;
    pthread_mutex_init(&d->lock,NULL);pthread_mutex_init(&d->work_lock,NULL);pthread_cond_init(&d->work_condition,NULL);
    // VideoToolbox's simulator codec exceeds the guest's 128 KiB stack.
    // All Apple decoder calls run on a normal host thread with a 4 MiB stack.
    pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setstacksize(&attr,4*1024*1024);
    int error=pthread_create(&d->worker,&attr,avc_worker,d);pthread_attr_destroy(&attr);
    if(error){pthread_cond_destroy(&d->work_condition);pthread_mutex_destroy(&d->work_lock);pthread_mutex_destroy(&d->lock);free(d);return -4;}
    pthread_mutex_lock(&avc_owned_lock);int slot=0;while(slot<16 && avc_owned[slot])slot++;
    if(slot==16)die("AVC session limit");avc_owned[slot]=d;pthread_mutex_unlock(&avc_owned_lock);
    *out=d;return 0;
}
HLE_FORCE("H264SwDecRelease", "Release the Apple AVC session and its output frames", void, h_avc_Release,avc_decoder *d){
    if(!d)return;
    pthread_mutex_lock(&avc_owned_lock);for(int i=0;i<16;i++)if(avc_owned[i]==d)avc_owned[i]=NULL;pthread_mutex_unlock(&avc_owned_lock);
    LOG("PJDV AVC release decoded=%u queued=%u",d->decoded,d->queued);avc_job(d,AVC_JOB_STOP,NULL,NULL);pthread_join(d->worker,NULL);free(d->sps);free(d->pps);
    pthread_cond_destroy(&d->work_condition);pthread_mutex_destroy(&d->work_lock);pthread_mutex_destroy(&d->lock);free(d);
}
HLE_FORCE("H264SwDecGetInfo", "Report the actual Apple AVC format in the SDK's video info layout", int, h_avc_Info,avc_decoder *d,avc_info *out){
    if(!d || !out)return -1;if(!d->format)return -6;*out=d->info;return 0;
}
HLE_FORCE("H264SwDecDecode", "Decode the game's Annex-B AVC access units with VideoToolbox", int, h_avc_Decode,avc_decoder *d,const avc_input *input,avc_output *out){
    if(!d)return -1;return avc_job(d,AVC_JOB_DECODE,input,out);
}
static int avc_decode(avc_decoder *d,const avc_input *input,avc_output *out){
    if(!d || !input || !out || !input->bytes || !input->size)return -1;
    const uint8_t *p=input->bytes;size_t n=input->size,prefix=0,start=avc_start_code(p,n,0,&prefix);
    out->position=p;if(start!=0)return -2;
    size_t sample_size=0;unsigned slices=0;int idr=0;
    while(start<n){
        size_t nal=start+prefix,next_prefix=0,next=avc_start_code(p,n,nal,&next_prefix),size=next-nal;
        if(!size)return -2;
        uint32_t type=p[nal]&31;
        if(type==7 || type==8){
            int changed=type==7?avc_parameter(&d->sps,&d->sps_size,p+nal,size):avc_parameter(&d->pps,&d->pps_size,p+nal,size);
            if(changed<0)return -4;
            if(d->sps && d->pps && (changed || !d->session)){
                OSStatus err=avc_start_session(d);if(err){LOG("PJDV VideoToolbox format error=%d",(int)err);return -2;}
                out->position=p+next;return 4; // Native OMX negotiates its output port.
            }
        }
        if(type!=7 && type!=8){
            if(size>UINT32_MAX || sample_size>SIZE_MAX-size-4)return -2;
            sample_size+=size+4;
            if(type>=1 && type<=5){slices++;idr|=type==5;}
        }
        out->position=p+next;start=next;prefix=next_prefix;
    }
    if(!slices)return 1;
    if(!d->session)return -6;
    // The native extractor supplies one access unit/picture ID, potentially
    // containing several VCL slices. Submit the whole picture once: decoding
    // each slice separately duplicates that ID and the OMX timestamp map entry
    // is removed after the first output (PV216 has four slices per frame).
    int64_t pts=0;if(!avc_timestamp(input->bytes,input->size,&pts)){LOG("PJDV AVC input timestamp missing id=%u",input->id);return -2;}
    CMBlockBufferRef block=NULL;CMSampleBufferRef sample=NULL;
    OSStatus err=CMBlockBufferCreateWithMemoryBlock(NULL,NULL,sample_size,NULL,NULL,0,sample_size,0,&block);
    start=avc_start_code(p,n,0,&prefix);size_t offset=0;
    while(!err && start<n){
        size_t nal=start+prefix,next_prefix=0,next=avc_start_code(p,n,nal,&next_prefix),size=next-nal;
        uint32_t type=p[nal]&31;
        if(type!=7 && type!=8){uint32_t len=CFSwapInt32HostToBig((uint32_t)size);
            err=CMBlockBufferReplaceDataBytes(&len,block,offset,4);
            if(!err)err=CMBlockBufferReplaceDataBytes(p+nal,block,offset+4,size);
            offset+=size+4;}
        start=next;prefix=next_prefix;
    }
    CMSampleTimingInfo timing={kCMTimeInvalid,CMTimeMake(pts,1000000),kCMTimeInvalid};
    if(!err)err=CMSampleBufferCreateReady(NULL,block,d->format,1,1,&timing,1,&sample_size,&sample);
    avc_token *token=NULL;
    if(!err){token=malloc(sizeof(*token));if(!token)err=kCVReturnAllocationFailed;else *token=(avc_token){input->id,(uint32_t)idr,pts};}
    if(!err)err=VTDecompressionSessionDecodeFrame(d->session,sample,0,token,NULL);
    if(sample)CFRelease(sample);if(block)CFRelease(block);
    if(err){free(token);LOG("PJDV VideoToolbox decode error=%d id=%u",(int)err,input->id);return -2;}
    if(slices>1){static _Atomic unsigned count;unsigned q=atomic_fetch_add(&count,1)+1;
        if(q<=3)LOG("PJDV AVC grouped access unit id=%u slices=%u bytes=%zu",input->id,slices,sample_size);}
    pthread_mutex_lock(&d->lock);OSStatus error=d->error;pthread_mutex_unlock(&d->lock);
    // PIC_RDY means one input picture was accepted, irrespective of whether
    // asynchronous/reordered output is already available to NextPicture.
    return error?-2:3;
}
static void *avc_worker(void *opaque){
    avc_decoder *d=opaque;pthread_setname_np("PJDV Apple AVC");pthread_mutex_lock(&d->work_lock);
    for(;;){
        while(d->job==AVC_JOB_NONE || d->done)pthread_cond_wait(&d->work_condition,&d->work_lock);
        int stop=d->job==AVC_JOB_STOP;
        if(d->job==AVC_JOB_DECODE)d->result=avc_decode(d,d->job_input,d->job_output);
        else if(d->job==AVC_JOB_FLUSH){d->result=d->session?VTDecompressionSessionWaitForAsynchronousFrames(d->session):0;pthread_mutex_lock(&d->lock);d->flushing=1;pthread_mutex_unlock(&d->lock);LOG("PJDV AVC flush decoded=%u queued=%u result=%d",d->decoded,d->queued,d->result);}
        else{avc_stop_session(d);avc_clear_frames(d);d->result=0;}
        d->done=1;pthread_cond_broadcast(&d->work_condition);
        if(stop)break;
    }
    pthread_mutex_unlock(&d->work_lock);return NULL;
}
static int avc_job(avc_decoder *d,int job,const avc_input *input,avc_output *out){
    pthread_mutex_lock(&d->work_lock);
    while(d->job!=AVC_JOB_NONE)pthread_cond_wait(&d->work_condition,&d->work_lock);
    d->job=job;d->done=0;d->job_input=input;d->job_output=out;pthread_cond_broadcast(&d->work_condition);
    while(!d->done)pthread_cond_wait(&d->work_condition,&d->work_lock);
    int result=d->result;d->job=AVC_JOB_NONE;d->done=0;pthread_cond_broadcast(&d->work_condition);
    pthread_mutex_unlock(&d->work_lock);return result;
}
HLE_FORCE("H264SwDecNextPicture", "Deliver real decoded planar YUV pictures to the original OMX output buffers", int, h_avc_Next,avc_decoder *d,avc_picture *out,uint32_t end){
    if(!d || !out)return -1;if(end)avc_job(d,AVC_JOB_FLUSH,NULL,NULL);
    pthread_mutex_lock(&d->lock);avc_frame *f=d->head;
    if(!f || (!d->flushing && d->queued<=d->reorder)){pthread_mutex_unlock(&d->lock);return 0;}
    d->head=f->next;if(!d->head)d->tail=NULL;d->queued--;avc_frame *last=d->last;d->last=f;
    *out=(avc_picture){f->pixels,f->id,f->idr,0};pthread_mutex_unlock(&d->lock);avc_frame_free(last);return 2;
}

void pjdv_avc_session_end(void) {
    for(int i=0;i<16;i++){pthread_mutex_lock(&avc_owned_lock);avc_decoder *d=avc_owned[i];pthread_mutex_unlock(&avc_owned_lock);if(d)h_avc_Release(d);}
    pthread_mutex_lock(&avc_stamp_lock);memset(avc_stamps,0,sizeof avc_stamps);avc_stamp_next=0;pthread_mutex_unlock(&avc_stamp_lock);
}

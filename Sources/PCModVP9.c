// Decoder-only, bounded libvpx bridge for offline MOD import. No PC plugin code.
#include <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>
#include <vpx/vpx_frame_buffer.h>
typedef struct {
    vpx_codec_ctx_t codec;
    unsigned width,height;
    size_t allocated;
    pthread_mutex_t lock;
    vpx_image_t *image;
    CVPixelBufferPoolRef pool;
} pjdv_vp9;
static int get_frame(void *opaque,size_t size,vpx_codec_frame_buffer_t *fb){
    pjdv_vp9 *d=opaque;if(size>32u*1024*1024)return -1;
    pthread_mutex_lock(&d->lock);
    if(d->allocated>96u*1024*1024-size){pthread_mutex_unlock(&d->lock);return -1;}
    d->allocated+=size;pthread_mutex_unlock(&d->lock);
    fb->data=calloc(1,size);fb->size=size;fb->priv=fb->data;
    if(!fb->data){pthread_mutex_lock(&d->lock);d->allocated-=size;pthread_mutex_unlock(&d->lock);return -1;}return 0;
}
static int release_frame(void *opaque,vpx_codec_frame_buffer_t *fb){
    pjdv_vp9 *d=opaque;if(fb->data){free(fb->data);pthread_mutex_lock(&d->lock);d->allocated-=fb->size;pthread_mutex_unlock(&d->lock);fb->data=NULL;fb->priv=NULL;fb->size=0;}return 0;
}
void *pjdv_mod_vp9_create(int width,int height){
    if(width<=0||height<=0||width>4096||height>4096||(width&1)||(height&1))return NULL;
    pjdv_vp9 *d=calloc(1,sizeof *d);if(!d)return NULL;
    d->width=width;d->height=height;pthread_mutex_init(&d->lock,NULL);
    vpx_codec_dec_cfg_t config={.threads=2,.w=(unsigned)width,.h=(unsigned)height};
    if(vpx_codec_dec_init(&d->codec,vpx_codec_vp9_dx(),&config,0)!=VPX_CODEC_OK){pthread_mutex_destroy(&d->lock);free(d);return NULL;}
    if(vpx_codec_set_frame_buffer_functions(&d->codec,get_frame,release_frame,d)!=VPX_CODEC_OK){vpx_codec_destroy(&d->codec);pthread_mutex_destroy(&d->lock);free(d);return NULL;}return d;
}
void pjdv_mod_vp9_destroy(void *opaque){pjdv_vp9 *d=opaque;if(!d)return;vpx_codec_destroy(&d->codec);if(d->pool)CVPixelBufferPoolRelease(d->pool);pthread_mutex_destroy(&d->lock);free(d);}
int pjdv_mod_vp9_decode(void *opaque,const void *bytes,size_t size){
    pjdv_vp9 *d=opaque;if(!d||!bytes||!size||size>16u*1024*1024)return -1;
    if(vpx_codec_decode(&d->codec,bytes,(unsigned)size,NULL,0)!=VPX_CODEC_OK){fprintf(stderr,"PJDV MOD VP9 decode: %s\n",vpx_codec_error(&d->codec));return -10;}
    vpx_codec_iter_t it=NULL;d->image=vpx_codec_get_frame(&d->codec,&it);
    if(!d->image)return 1;
    if(vpx_codec_get_frame(&d->codec,&it))return -11;
    vpx_image_t *p=d->image;
    if(p->fmt!=VPX_IMG_FMT_I420||p->d_w!=d->width||p->d_h!=d->height||p->bit_depth!=8||p->stride[0]<(int)d->width||p->stride[1]<(int)d->width/2||p->stride[2]<(int)d->width/2){fprintf(stderr,"PJDV MOD VP9 layout fmt=%u size=%ux%u bits=%u strides=%d,%d,%d\n",p->fmt,p->d_w,p->d_h,p->bit_depth,p->stride[0],p->stride[1],p->stride[2]);return -12;}
    return 0;
}
// Returns a retained pixel buffer; nil means bounded writer backpressure.
void *pjdv_mod_vp9_copy_pixel(void *opaque){
    pjdv_vp9 *d=opaque;if(!d||!d->image)return NULL;
    vpx_image_t *p=d->image;
    if(!d->pool){
        int32_t w=d->width,h=d->height,format=p->range==VPX_CR_FULL_RANGE?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        CFNumberRef nw=CFNumberCreate(NULL,kCFNumberSInt32Type,&w),nh=CFNumberCreate(NULL,kCFNumberSInt32Type,&h),nf=CFNumberCreate(NULL,kCFNumberSInt32Type,&format);
        const void *keys[]={kCVPixelBufferWidthKey,kCVPixelBufferHeightKey,kCVPixelBufferPixelFormatTypeKey};const void *values[]={nw,nh,nf};
        CFDictionaryRef attrs=CFDictionaryCreate(NULL,keys,values,3,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CVReturn code=CVPixelBufferPoolCreate(NULL,NULL,attrs,&d->pool);CFRelease(attrs);CFRelease(nw);CFRelease(nh);CFRelease(nf);if(code!=kCVReturnSuccess)return NULL;
    }
    int32_t six=6;CFNumberRef threshold=CFNumberCreate(NULL,kCFNumberSInt32Type,&six);const void *keys[]={kCVPixelBufferPoolAllocationThresholdKey},*values[]={threshold};
    CFDictionaryRef aux=CFDictionaryCreate(NULL,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CVPixelBufferRef pixel=NULL;CVReturn code=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,d->pool,aux,&pixel);CFRelease(aux);CFRelease(threshold);
    if(code!=kCVReturnSuccess)return NULL;
    if(CVPixelBufferLockBaseAddress(pixel,0)!=kCVReturnSuccess){CVPixelBufferRelease(pixel);return NULL;}
    uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(pixel,0),*uv=CVPixelBufferGetBaseAddressOfPlane(pixel,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(pixel,0),uvs=CVPixelBufferGetBytesPerRowOfPlane(pixel,1);
    if(!y||!uv||ys<d->width||uvs<d->width){CVPixelBufferUnlockBaseAddress(pixel,0);CVPixelBufferRelease(pixel);return NULL;}
    for(unsigned row=0;row<d->height;row++)memcpy(y+row*ys,p->planes[0]+row*p->stride[0],d->width);
    for(unsigned row=0;row<d->height/2;row++)for(unsigned x=0;x<d->width/2;x++){uv[row*uvs+2*x]=p->planes[1][row*p->stride[1]+x];uv[row*uvs+2*x+1]=p->planes[2][row*p->stride[2]+x];}
    CVPixelBufferUnlockBaseAddress(pixel,0);
    CFStringRef matrix=p->cs==VPX_CS_BT_709?kCVImageBufferYCbCrMatrix_ITU_R_709_2:kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,matrix,kCVAttachmentMode_ShouldPropagate);
    return pixel;
}

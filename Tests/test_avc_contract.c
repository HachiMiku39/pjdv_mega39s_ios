#include "/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm/gfx/pjdv_avc.c"
#include <stdarg.h>
static unsigned forwarded;
static void fake_filled(void *component,const void *header){(void)component;(void)header;forwarded++;}
void *guest_sym(const char *name){return strstr(name,"notifyFillBufferDone")?(void *)fake_filled:NULL;}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"failed line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void){
 // A client NV12 request must receive interleaved chroma, while OMX keeps its
 // planar ABI. Nonzero Buffer offsets and the luma/prefix guard must survive.
 uint8_t impl[0x130]={0},client[0x30]={0},pixels[40];memset(pixels,0xee,sizeof pixels);
 int width=4,height=2,format=4,type=1,mode=1,color=19,offset=8,bytes=12;uint64_t capacity=sizeof pixels;uint8_t *base=pixels;
 memcpy(impl+0x38,&width,4);memcpy(impl+0x3c,&height,4);memcpy(impl+0xdc,&format,4);memcpy(impl+0xe0,&type,4);memcpy(impl+0xe4,&mode,4);
 memcpy(client,&offset,4);memcpy(client+4,&bytes,4);memcpy(client+0x18,&capacity,8);memcpy(client+0x28,&base,8);
 for(int i=0;i<8;i++)pixels[8+i]=(uint8_t)(16+i);pixels[16]=32;pixels[17]=33;pixels[18]=230;pixels[19]=231;
 avc_client_nv12(impl,client,color,width,height);CHECK(pixels[7]==0xee && pixels[20]==0xee);for(int i=0;i<8;i++)CHECK(pixels[8+i]==16+i);
 CHECK(pixels[16]==32 && pixels[17]==230 && pixels[18]==33 && pixels[19]==231);
 color=21;avc_client_nv12(impl,client,color,width,height);CHECK(pixels[16]==32 && pixels[17]==230 && pixels[18]==33 && pixels[19]==231);
 type=4;memcpy(impl+0xe0,&type,4);avc_client_nv12(impl,client,color,width,height);CHECK(pixels[7]==0xee && pixels[20]==0xee);
 avc_decoder *d=NULL;CHECK(h_avc_Init((void**)&d,0)==0);d->info=(avc_info){.width=16,.height=16};d->reorder=3;
 CVPixelBufferRef image=NULL;CHECK(CVPixelBufferCreate(NULL,2,2,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,NULL,&image)==0);
 CHECK(CVPixelBufferLockBaseAddress(image,0)==0);uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(image,0),*uv=CVPixelBufferGetBaseAddressOfPlane(image,1);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(image,0);
 y[0]=200;y[1]=201;y[ys]=202;y[ys+1]=203;uv[0]=32;uv[1]=230;CVPixelBufferUnlockBaseAddress(image,0);
 int64_t pts[]={300,0,200,100,400};for(unsigned i=0;i<5;i++){avc_token *t=malloc(sizeof(*t));*t=(avc_token){i,0,pts[i]};avc_decoded(d,t,0,0,image,kCMTimeInvalid,kCMTimeInvalid);}
 avc_picture pic;CHECK(h_avc_Next(d,&pic,0)==2 && pic.id==1);CHECK(pic.pixels[0]==200 && pic.pixels[1]==201 && pic.pixels[16]==202 && pic.pixels[17]==203);CHECK(pic.pixels[2]==16 && pic.pixels[255]==16 && pic.pixels[256]==32 && pic.pixels[320]==230 && pic.pixels[257]==128);
 CHECK(h_avc_Next(d,&pic,0)==2 && pic.id==3);CHECK(h_avc_Next(d,&pic,0)==0);
 CHECK(h_avc_Next(d,&pic,1)==2 && pic.id==2);CHECK(h_avc_Next(d,&pic,1)==2 && pic.id==0);CHECK(h_avc_Next(d,&pic,1)==2 && pic.id==4);CHECK(h_avc_Next(d,&pic,1)==0);
 uint8_t bad[]={1,2,3};avc_input input={bad,sizeof(bad),0,0};avc_output output;CHECK(h_avc_Decode(d,&input,&output)==-2);
 uint8_t header[0x70]={0};uint32_t filled=100,flags=0;int64_t stamp=400400;void *component=(void *)0x1234;
 memcpy(header+0x14,&filled,4);memcpy(header+0x58,&stamp,8);h_avc_Filled(component,header);
 filled=0;flags=1;stamp=0;memcpy(header+0x14,&filled,4);memcpy(header+0x60,&flags,4);memcpy(header+0x58,&stamp,8);h_avc_Filled(component,header);memcpy(&stamp,header+0x58,8);CHECK(stamp==400400 && forwarded==2);
 stamp=0;flags=0;memcpy(header+0x60,&flags,4);memcpy(header+0x58,&stamp,8);h_avc_Filled(component,header);memcpy(&stamp,header+0x58,8);CHECK(stamp==0 && forwarded==3);
 CFRelease(image);h_avc_Release(d);puts("AVC contract passed: client planar-to-NV12 with offset guards, NV12 pass-through, audio exclusion, NV12 to padded planar YUV, B-frame ordering, bounded delay, EOS drain, malformed input, empty-EOS timestamp and callback preservation");return 0;
}

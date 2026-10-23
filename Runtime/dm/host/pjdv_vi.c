// Virtual Horizon display/layer handles backed by the host Metal canvas.
// Game rendering is performed by NVN/Metal; these objects never call Nintendo IPC.
#include "hle.h"
#include "front.h"
#include <unistd.h>
typedef struct { unsigned magic;int width,height; } HostDisplay;
typedef struct HostLayer { unsigned magic;HostDisplay *display;int width,height;struct HostLayer *next; } HostLayer;
static HostLayer *owned_layers;
static HostDisplay display={0x504a4456,1280,720};
HLE_FORCE("_ZN2nn2vi10InitializeEv","Host Metal display is already created",void,h_vi_Init,void){}
HLE_FORCE("_ZN2nn2vi17InitializeMinimumEv","Host Metal display is already created",void,h_vi_InitMin,void){}
HLE_FORCE("_ZN2nn2vi8FinalizeEv","Host owns Metal display lifetime",void,h_vi_Finalize,void){}
HLE_FORCE("_ZN2nn2vi11OpenDisplayEPPNS0_7DisplayEPKc","Open host virtual display",Result,h_vi_Open,HostDisplay **out,const char *name){if(!out)return RES_FAIL;*out=&display;return RES_OK;}
HLE_FORCE("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE","Open host virtual display",Result,h_vi_Default,HostDisplay **out){return h_vi_Open(out,"Default");}
HLE_FORCE("_ZN2nn2vi12CloseDisplayEPNS0_7DisplayE","Host owns display lifetime",Result,h_vi_Close,HostDisplay *d){return d==&display?RES_OK:RES_FAIL;}
HLE_FORCE("_ZN2nn2vi20GetDisplayResolutionEPiS1_PKNS0_7DisplayE","Original Switch panel dimensions",Result,h_vi_Res,int *w,int *h,const HostDisplay *d){if(d!=&display||!w||!h)return RES_FAIL;*w=d->width;*h=d->height;return RES_OK;}
HLE_FORCE("_ZN2nn2vi27GetDisplayLogicalResolutionEPiS1_PKNS0_7DisplayE","Original Switch panel dimensions",Result,h_vi_Logical,int *w,int *h,const HostDisplay *d){return h_vi_Res(w,h,d);}
HLE_FORCE("_ZN2nn2vi17SetDefaultDisplayEPNS0_7DisplayE","Host uses one Metal canvas",Result,h_vi_SetDefault,HostDisplay *d){return d==&display?RES_OK:RES_FAIL;}
static Result create_layer(HostLayer **out,HostDisplay *d,int w,int h){if(!out||d!=&display||w<1||h<1)return RES_FAIL;HostLayer *l=calloc(1,sizeof *l);if(!l)return RES_FAIL;*l=(HostLayer){0x4d33394c,d,w,h,owned_layers};owned_layers=l;*out=l;return RES_OK;}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE","Create NVN presentation layer",Result,h_vi_Create,HostLayer **out,HostDisplay *d){return create_layer(out,d,1280,720);}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayEii","Create NVN presentation layer",Result,h_vi_CreateSize,HostLayer **out,HostDisplay *d,int w,int h){return create_layer(out,d,w,h);}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayEPKNS0_21LayerCreationSettingsE","Create NVN presentation layer",Result,h_vi_CreateSettings,HostLayer **out,HostDisplay *d,const void *settings){return h_vi_Create(out,d);}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayENS_4util10BitFlagSetILi32ENS0_15CompositorFlagsEEE","Create NVN presentation layer",Result,h_vi_CreateFlags,HostLayer **out,HostDisplay *d,uint32_t flags){return h_vi_Create(out,d);}
HLE_FORCE("_ZN2nn2vi12DestroyLayerEPNS0_5LayerE","Release host layer handle",Result,h_vi_Destroy,HostLayer *l){if(!l||l->magic!=0x4d33394c)return RES_FAIL;for(HostLayer **p=&owned_layers;*p;p=&(*p)->next)if(*p==l){*p=l->next;break;}l->magic=0;free(l);return RES_OK;}
HLE_FORCE("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE","NVN window maps to host Metal canvas",Result,h_vi_Native,void **out,HostLayer *l){if(!out||!l||l->magic!=0x4d33394c)return RES_FAIL;*out=l;return RES_OK;}
HLE_FORCE("_ZN2nn2vi12SetLayerSizeEPNS0_5LayerEii","Set virtual layer extent",Result,h_vi_Size,HostLayer *l,int w,int h){if(!l||w<1||h<1)return RES_FAIL;l->width=w;l->height=h;return RES_OK;}
HLE_FORCE("_ZN2nn2vi16SetLayerPositionEPNS0_5LayerEff","Canvas centering handled by host aspect fit",Result,h_vi_Position,HostLayer *l,float x,float y){return l?RES_OK:RES_FAIL;}
HLE_FORCE("_ZN2nn2vi19SetLayerScalingModeEPNS0_5LayerENS0_11ScalingModeE","Host preserves original 16:9 content",Result,h_vi_Scaling,HostLayer *l,int mode){return l?RES_OK:RES_FAIL;}
HLE_FORCE("_ZN2nn2vi18SetLayerVisibilityEPNS0_5LayerEb","Application visibility belongs to host",Result,h_vi_Visible,HostLayer *l,unsigned on){return l?RES_OK:RES_FAIL;}
HLE_FORCE("_ZN2nn2vi13SetLayerAlphaEPNS0_5LayerEf","Host compositor uses game alpha",Result,h_vi_Alpha,HostLayer *l,float alpha){return l?RES_OK:RES_FAIL;}
HLE_FORCE("_ZN2nn2vi9SetLayerZEPNS0_5LayerEi","One application presentation layer",Result,h_vi_Z,HostLayer *l,int z){return l?RES_OK:RES_FAIL;}

void pjdv_vi_session_end(void){while(owned_layers)h_vi_Destroy(owned_layers);}

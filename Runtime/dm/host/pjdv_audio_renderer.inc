// Native audren REV7 voice records, with a host sample cursor per queue slot.
// No guest timing, chart, judgment or game volume constants are modified.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#ifndef AR_FAIL
#define AR_FAIL(...) die(__VA_ARGS__)
#endif
#define AR_VOICES 512
#define AR_CHANNELS 6
#define AR_SLOTS 4
typedef struct {uint64_t played;uint32_t consumed,generation;} ar_status;
typedef struct {
    const uint8_t *data,*context;uint64_t bytes,context_bytes;
    uint32_t start,end;uint8_t looping,eos,queued;
    float *decoded;
} ar_wave;
typedef struct {
    ar_wave wave[AR_SLOTS];uint8_t used,state,format,head;
    uint32_t rate,channels,generation;float pitch,volume,gain[AR_CHANNELS][2];
    double position,fraction;uint64_t played;uint32_t consumed;
    int16_t coefficients[16],history[2];
    ar_status delivered;
} ar_voice;
typedef struct {uint32_t count;ar_voice voice[AR_VOICES];float final_volume;} ar_core;
static uint32_t ar_u32(const void *p,size_t off){uint32_t v;memcpy(&v,(const uint8_t *)p+off,4);return v;}
static uint64_t ar_u64(const void *p,size_t off){uint64_t v;memcpy(&v,(const uint8_t *)p+off,8);return v;}
static float ar_f32(const void *p,size_t off){float v;memcpy(&v,(const uint8_t *)p+off,4);return v;}
static int16_t ar_s16(const void *p,size_t off){int16_t v;memcpy(&v,(const uint8_t *)p+off,2);return v;}
static void ar_clear_voice(ar_voice *v){
    uint32_t generation=v->generation+1;
    for(int k=0;k<AR_SLOTS;k++)free(v->wave[k].decoded);
    memset(v,0,sizeof *v);v->state=1;v->generation=generation;v->delivered.generation=generation;
}
static void ar_decode_adpcm(ar_voice *v,ar_wave *w){
    if(w->decoded)return;
    if(v->channels!=1 || w->end>(w->bytes/8)*14 || w->end>4*1024*1024)AR_FAIL("ADPCM extent/channel unsupported");
    w->decoded=malloc((size_t)w->end*sizeof(float));if(!w->decoded)AR_FAIL("ADPCM allocation failed");
    int h1=v->history[0],h2=v->history[1];
    for(uint32_t i=0;i<w->end;i++){
        uint32_t frame=i/14,n=i%14;uint8_t header=w->data[frame*8];
        unsigned predictor=header>>4,shift=header&15;
        if(predictor>7)AR_FAIL("ADPCM predictor %u invalid",predictor);
        uint8_t packed=w->data[frame*8+1+n/2];int sample=(n&1)?packed&15:packed>>4;if(sample>=8)sample-=16;
        int64_t value=(int64_t)sample*(1u<<shift)*2048+(int64_t)v->coefficients[predictor*2]*h1+(int64_t)v->coefficients[predictor*2+1]*h2+1024;
        value>>=11;if(value>32767)value=32767;if(value<-32768)value=-32768;
        h2=h1;h1=(int)value;w->decoded[i]=(float)value/32768.0f;
    }
    v->history[0]=(int16_t)h1;v->history[1]=(int16_t)h2;
}
static float ar_sample(ar_voice *v,ar_wave *w,uint32_t index,uint32_t channel){
    if(index>=w->end)index=w->end-1;
    uint64_t sample=(uint64_t)index*v->channels+channel;
    switch(v->format){
    case 1:return (float)((const int8_t *)w->data)[sample]/128.0f;
    case 2:return (float)ar_s16(w->data,(size_t)sample*2)/32768.0f;
    case 3:{const uint8_t *b=w->data+sample*3;uint32_t bits=(uint32_t)b[0]|(uint32_t)b[1]<<8|(uint32_t)b[2]<<16;if(bits&0x800000)bits|=0xff000000;return (float)(int32_t)bits/8388608.0f;}
    case 4:{int32_t n;memcpy(&n,w->data+sample*4,4);return (float)((double)n/2147483648.0);}
    case 5:{float f=ar_f32(w->data,(size_t)sample*4);return isfinite(f)?f:0;}
    case 6:ar_decode_adpcm(v,w);return w->decoded[index];
    default:AR_FAIL("AudioRenderer sample format %u unsupported",v->format);return 0;
    }
}
static void ar_check_wave(ar_voice *v,ar_wave *w){
    static const uint8_t bpp[7]={0,1,2,3,4,4,0};
    if(!w->data || !w->bytes || w->end<=w->start || v->format<1 || v->format>6)AR_FAIL("Invalid audren wave buffer");
    if(v->format!=6 && (uint64_t)w->end*v->channels*bpp[v->format]>w->bytes)AR_FAIL("PCM wave buffer out of bounds");
    if(v->format==6 && ((uint64_t)w->end+13)/14*8>w->bytes)AR_FAIL("ADPCM wave buffer out of bounds");
}
static void ar_voice_update(ar_voice *v,const uint8_t *in,const uint8_t *channels,uint32_t channel_bytes){
    if(!in[9]){if(v->used)ar_clear_voice(v);return;}
    if(in[8] || !v->used){ar_clear_voice(v);v->head=(uint8_t)(ar_u32(in,0x40)&3);}
    // Stopping consumes the old queue once. Buffers submitted while already
    // stopped are a preload for the next start, and must remain available.
    if(in[10]==1 && v->state!=1){
        unsigned released=0;
        for(int k=0;k<AR_SLOTS;k++)if(v->wave[k].queued){v->wave[k].queued=0;released++;}
        v->consumed+=released;v->head=(v->head+released)&3;
        v->position=0;v->fraction=0;
    }
    v->used=1;v->state=in[10];v->format=in[11];v->rate=ar_u32(in,12);v->channels=ar_u32(in,24);
    v->pitch=ar_f32(in,28);v->volume=ar_f32(in,32);
    if(!v->rate || v->channels<1 || v->channels>AR_CHANNELS || !isfinite(v->pitch) || v->pitch<=0 || v->pitch>8 || !isfinite(v->volume))AR_FAIL("Invalid audren voice parameters");
    if(ar_u32(in,0x58)!=0)AR_FAIL("AudioRenderer submix destination is not yet supported");
    if(in[0x24] || in[0x30])AR_FAIL("AudioRenderer voice biquad requires a DSP implementation");
    for(unsigned j=0;j<v->channels;j++){
        uint32_t id=ar_u32(in,0x140+j*4);const uint8_t *ch=NULL;
        for(uint32_t k=0;k<channel_bytes/0x70;k++)if(ar_u32(channels,k*0x70)==id){ch=channels+k*0x70;break;}
        if(!ch)AR_FAIL("AudioRenderer channel resource unavailable");
        v->gain[j][0]=ar_f32(ch,4);v->gain[j][1]=ar_f32(ch,8);
    }
    if(v->format==6){
        const void *coef=(const void *)(uintptr_t)ar_u64(in,0x48);if(!coef || ar_u64(in,0x50)<32)AR_FAIL("ADPCM coefficients unavailable");
        memcpy(v->coefficients,coef,32);
    }
    for(int k=0;k<AR_SLOTS;k++){
        const uint8_t *b=in+0x60+k*0x38;ar_wave *w=&v->wave[k];
        // The SDK marks already submitted descriptors at byte 0x1a. Only new
        // descriptors enter the queue; a consumed stale slot must not replay.
        if(b[0x1a] || !ar_u64(b,0) || w->queued)continue;
        free(w->decoded);memset(w,0,sizeof *w);
        w->data=(const uint8_t *)(uintptr_t)ar_u64(b,0);w->bytes=ar_u64(b,8);w->start=ar_u32(b,16);w->end=ar_u32(b,20);
        w->looping=b[24];w->eos=b[25];w->context=(const uint8_t *)(uintptr_t)ar_u64(b,32);w->context_bytes=ar_u64(b,40);w->queued=1;
        ar_check_wave(v,w);
    }
}
static void ar_voice_mix(ar_voice *v,float *mix,unsigned frames){
    if(!v->used || v->state!=0)return;
    double step=(double)v->rate*v->pitch/48000.0;
    for(unsigned f=0;f<frames;f++){
        ar_wave *w=&v->wave[v->head];if(!w->queued)break;
        if(v->position<w->start)v->position=w->start;
        uint32_t i=(uint32_t)v->position;float frac=(float)(v->position-i);
        for(unsigned c=0;c<v->channels;c++){
            float a=ar_sample(v,w,i,c),b=ar_sample(v,w,i+1,c);float sample=(a+(b-a)*frac)*v->volume;
            mix[f*2]+=sample*v->gain[c][0];mix[f*2+1]+=sample*v->gain[c][1];
        }
        v->position+=step;v->fraction+=step;uint64_t advance=(uint64_t)v->fraction;v->fraction-=advance;v->played+=advance;
        while(v->position>=w->end){
            double remainder=v->position-w->end;
            if(w->looping){v->position=w->start+remainder;break;}
            w->queued=0;v->consumed++;v->head=(v->head+1)&3;w=&v->wave[v->head];
            if(!w->queued){v->position=0;break;}v->position=w->start+remainder;
        }
    }
}
static void ar_mix(ar_core *core,int16_t *out,unsigned frames){
    float mix[480*2]={0};if(frames>480)AR_FAIL("AudioRenderer period too large");
    for(uint32_t k=0;k<core->count;k++)ar_voice_mix(&core->voice[k],mix,frames);
    for(unsigned f=0;f<frames*2;f++){
        float s=mix[f]*core->final_volume*32768.0f;
        out[f]=(int16_t)(s>=32767?32767:s<=-32768?-32768:lroundf(s));
    }
}

// The following service keeps the SDK's serializer and queue ownership intact.
typedef struct { uint8_t *data; uint64_t size; } pjdv_audio_packet;
typedef struct {gbuf buffer;int16_t pcm[480*2];ar_status status[AR_VOICES];int queued;} ar_block;
typedef struct {
    ar_core core;char output_key[8];ar_block blocks[8];unsigned in_flight;
    uint64_t completed,nonzero,clipped;FILE *capture;unsigned capture_frames;int diagnostic;
} ar_runtime;
static void ar_put32(void *p,size_t off,uint32_t v){memcpy((uint8_t *)p+off,&v,4);}
static void ar_put64(void *p,size_t off,uint64_t v){memcpy((uint8_t *)p+off,&v,8);}
static void ar_wav_header(FILE *f,unsigned frames){
    uint8_t h[44]={0};memcpy(h,"RIFF",4);ar_put32(h,4,36+frames*4);memcpy(h+8,"WAVEfmt ",8);ar_put32(h,16,16);
    h[20]=1;h[22]=2;ar_put32(h,24,48000);ar_put32(h,28,192000);h[32]=4;h[34]=16;memcpy(h+36,"data",4);ar_put32(h,40,frames*4);
    fseek(f,0,SEEK_SET);fwrite(h,1,44,f);fseek(f,0,SEEK_END);
}
static void pjdv_renderer_init(renderer_probe *p){
    if(p->params[0]!=48000 || p->params[1]>480 || p->params[3] || p->params[4]>AR_VOICES || p->params[5]!=1 || p->params[6])die("Unsupported PJDV AudioRenderer graph profile");
    ar_runtime *a=calloc(1,sizeof *a);if(!a)die("AudioRenderer state allocation failed");p->audio_state=a;
    a->core.count=p->params[4];a->core.final_volume=1;
    uint8_t prm[8]={0};ar_put32(prm,0,48000);prm[4]=2;
    if(h_au_Open(a->output_key,p->event,"PJDV AudioRenderer",prm))die("AudioRenderer CoreAudio open failed");
    const char *diag=getenv("PJDV_AUDIO_DIAG");a->diagnostic=diag && atoi(diag);
    for(int k=0;k<8;k++)h_au_SetBuf(&a->blocks[k].buffer,a->blocks[k].pcm,sizeof a->blocks[k].pcm,p->params[1]*4);
}
static void pjdv_renderer_start(renderer_probe *p){h_au_Start(((ar_runtime *)p->audio_state)->output_key);}
static void pjdv_renderer_stop(renderer_probe *p){h_au_Stop(((ar_runtime *)p->audio_state)->output_key);}
static void pjdv_renderer_close(renderer_probe *p){
    ar_runtime *a=p->audio_state;h_au_Close(a->output_key);
    for(uint32_t k=0;k<a->core.count;k++)ar_clear_voice(&a->core.voice[k]);
    if(a->capture){ar_wav_header(a->capture,a->capture_frames);fclose(a->capture);}
    free(a);p->audio_state=NULL;
}
static void ar_drain(renderer_probe *p){
    ar_runtime *a=p->audio_state;gbuf *buffer;
    while((buffer=h_au_Released(a->output_key))){
        ar_block *block=NULL;for(int k=0;k<8;k++)if(&a->blocks[k].buffer==buffer){block=&a->blocks[k];break;}
        if(!block || !block->queued)die("AudioRenderer release queue corrupt");
        for(uint32_t k=0;k<a->core.count;k++){
            ar_voice *v=&a->core.voice[k];if(block->status[k].generation==v->generation)v->delivered=block->status[k];
        }
        int peak=0;for(unsigned k=0;k<p->params[1]*2;k++){int n=abs(block->pcm[k]);if(n>peak)peak=n;}
        if(peak>0)a->nonzero++;
        if(a->diagnostic && a->capture_frames<96000 && (a->capture || peak>32)){
            if(!a->capture){char path[1400];snprintf(path,sizeof path,"%s/pjdv-audio-played.wav",getenv("DM_TEMP"));a->capture=fopen(path,"wb+");if(a->capture)ar_wav_header(a->capture,0);}
            if(a->capture){unsigned frames=p->params[1];if(frames>96000-a->capture_frames)frames=96000-a->capture_frames;fwrite(block->pcm,4,frames,a->capture);a->capture_frames+=frames;if(a->capture_frames==96000){ar_wav_header(a->capture,a->capture_frames);fclose(a->capture);a->capture=NULL;}}
        }
        block->queued=0;a->in_flight--;a->completed++;
    }
}
static void ar_fill(renderer_probe *p){
    ar_runtime *a=p->audio_state;
    // Bound the ahead queue to 20 ms. This covers a simulator's 512-frame I/O
    // callback without unbounded latency; statuses are published only on release.
    while(a->in_flight<4){
        ar_block *b=NULL;for(int k=0;k<8;k++)if(!a->blocks[k].queued){b=&a->blocks[k];break;}
        if(!b)die("AudioRenderer block ownership invalid");
        ar_mix(&a->core,b->pcm,p->params[1]);
        for(uint32_t k=0;k<a->core.count;k++){ar_voice *v=&a->core.voice[k];b->status[k]=(ar_status){v->played,v->consumed,v->generation};}
        if(!h_au_Append(a->output_key,&b->buffer))die("AudioRenderer output queue full");b->queued=1;a->in_flight++;
    }
}
static Result pjdv_renderer_packet(renderer_probe *p,const pjdv_audio_packet *out,const pjdv_audio_packet *perf,const pjdv_audio_packet *in){
    (void)perf;ar_runtime *a=p->audio_state;
    if(in->size<64 || !in->data || !out->data)die("AudioRenderer packet unavailable");
    uint32_t revision=ar_u32(in->data,0),mempool=ar_u32(in->data,8),voices=ar_u32(in->data,12),channels=ar_u32(in->data,16);
    uint32_t effects=ar_u32(in->data,20),sinks=ar_u32(in->data,28),total=ar_u32(in->data,60);
    uint32_t nv=p->params[4],ns=p->params[5],ne=p->params[6];
    size_t sum=64;for(int k=1;k<=9;k++)sum+=ar_u32(in->data,k*4);
    if(revision!=0x37564552 || mempool%32 || !nv || voices!=nv*0x170 || channels%0x70 || total!=in->size || sum!=total || ne || effects || sinks!=ns*0x140)die("Unsupported AudioRenderer packet rev=%x voice=%u/%u effect=%u",revision,voices,nv,effects);
    size_t output=64+mempool/2+nv*16+ns*32+16+176+16;
    if(output!=out->size)die("AudioRenderer output size %zu != %llu",output,out->size);
    ar_drain(p);
    size_t po=64+ar_u32(in->data,4),co=po+mempool,vo=co+channels;
    const uint8_t *v=in->data+vo;uint32_t used=0,queued=0;
    for(uint32_t k=0;k<nv;k++){ar_voice_update(&a->core.voice[k],v+k*0x170,in->data+co,channels);used+=v[k*0x170+9]!=0;queued+=ar_u32(v,k*0x170+0x3c);}
    size_t mo=vo+voices+effects+ar_u32(in->data,36);uint32_t mix_bytes=ar_u32(in->data,24);
    if(mix_bytes<32 || ar_u32(in->data,mo)!=0xcafebabe || mix_bytes!=32+ar_u32(in->data,mo+4)*0x930)die("AudioRenderer mix update invalid");
    for(uint32_t k=0;k<ar_u32(in->data,mo+4);k++){
        const uint8_t *m=in->data+mo+32+k*0x930;
        if(ar_u32(m,16)!=0 || ar_u32(m,8)!=2 || ar_u32(m,4)!=48000)die("AudioRenderer mix profile unsupported");
        a->core.final_volume=m[12]?ar_f32(m,0):0;if(!isfinite(a->core.final_volume))die("AudioRenderer final volume invalid");
    }
    const uint8_t *sink=in->data+mo+mix_bytes;
    if(sink[0]!=1 || !sink[1] || ar_u32(sink,0x120)!=2 || sink[0x124]!=0 || sink[0x125]!=1)die("AudioRenderer sink channel map unsupported");
    ar_fill(p);
    memset(out->data,0,out->size);
    ar_put32(out->data,0,revision);ar_put32(out->data,4,176);ar_put32(out->data,8,mempool/2);ar_put32(out->data,12,nv*16);
    ar_put32(out->data,28,ns*32);ar_put32(out->data,32,16);ar_put32(out->data,40,16);ar_put32(out->data,60,(uint32_t)output);
    for(uint32_t k=0;k<mempool/32;k++){uint32_t state=ar_u32(in->data,po+k*32+16);ar_put32(out->data,64+k*16,state==4?5:state==2?3:state);}
    uint8_t *status=out->data+64+mempool/2;
    for(uint32_t k=0;k<nv;k++){ar_put64(status,k*16,a->core.voice[k].delivered.played);ar_put32(status,k*16+8,a->core.voice[k].delivered.consumed);}
    ar_put64(out->data,out->size-16,a->completed);
    if(!p->updates)LOG("PJDV AudioRenderer packets REV7 voices=%u channels=%u sinks=%u bytes=%llu/%llu",nv,channels/0x70,ns,in->size,out->size);
    if(p->updates%1000==0){
        LOG("PJDV AudioRenderer played blocks=%llu nonzero=%llu active=%u queued=%u callbacks=%llu final=%f",a->completed,a->nonzero,used,queued,dm_audio_render_calls(),a->core.final_volume);
        if(a->diagnostic)for(uint32_t k=0;k<nv;k++)if(a->core.voice[k].used){
            ar_voice *x=&a->core.voice[k];unsigned pending=0;for(int s=0;s<4;s++)pending+=x->wave[s].queued;
            LOG("PJDV audio voice %u new=%u state=%u fmt=%u rate=%u ch=%u head=%u/%u pending=%u pos=%.2f played=%llu/%llu consumed=%u/%u gain=%f,%f",k,v[k*0x170+8],x->state,x->format,x->rate,x->channels,x->head,ar_u32(v,k*0x170+0x40)&3,pending,x->position,x->played,x->delivered.played,x->consumed,x->delivered.consumed,x->gain[0][0],x->gain[0][1]);
        }
    }
    p->updates++;return RES_OK;
}

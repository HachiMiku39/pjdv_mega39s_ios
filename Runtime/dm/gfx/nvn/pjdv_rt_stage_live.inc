// The command-list preflight copies only RT inputs; it never executes a game
// command or writes guest memory. All geometry comes from this submission,
// so a camera cut, scene change or changed transform cannot use stale meshes.
typedef typeof(S) PJDVRTDrawState;
static NSMutableArray<PJDVRTStageScene *> *g_pjdv_stage_cache;
static PJDVRTStageScene *g_pjdv_stage_scene;
static NSSet<NSValue *> *g_pjdv_stage_draws;
static id<MTLFunction> g_pjdv_stage_function;
static int g_pjdv_stage_failed;
static NSMutableDictionary *g_pjdv_cpu_mesh_cache;
static NSMutableArray *g_pjdv_cpu_mesh_order;
static NSUInteger g_pjdv_cpu_mesh_bytes;
static NSMutableDictionary<NSData *,PJDVRTStageScene *> *g_pjdv_mesh_cache;
static NSMutableArray<NSData *> *g_pjdv_mesh_order;
static NSUInteger g_pjdv_mesh_bytes;
static NSMutableDictionary *g_pjdv_index_cache;static NSMutableArray *g_pjdv_index_order;static NSUInteger g_pjdv_index_bytes;
// Snapshots and their digests live only during one command-list preflight.
// Inline writes invalidate overlapping snapshots; unrelated UBO writes leave
// immutable vertex/index snapshots reusable. Nothing survives to next submit.
typedef struct { uint64_t address,length; uint32_t stride,kind; } PJDVRTReadRange;
static NSMutableDictionary<NSData *,NSData *> *g_pjdv_read_cache;
static NSMapTable<NSData *,NSData *> *g_pjdv_digest_cache;
static NSUInteger g_pjdv_read_bytes,g_pjdv_digest_bytes;
static struct { uint64_t reads,readHits,copied,hashes,hashHits,hashed,meshHits,meshMisses; } g_pjdv_preflight_stats;
static void pjdv_stage_read_begin(BOOL cache) {
    if(!cache)return;
    g_pjdv_read_cache=[NSMutableDictionary dictionary];
    g_pjdv_digest_cache=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
    g_pjdv_read_bytes=g_pjdv_digest_bytes=0;
}
static void pjdv_stage_read_end(void) {
    g_pjdv_read_cache=nil;g_pjdv_digest_cache=nil;g_pjdv_read_bytes=g_pjdv_digest_bytes=0;
}
static void pjdv_stage_note_write(uint64_t address,NSUInteger length) {
    if(!length)return;
    for(NSData *key in g_pjdv_read_cache.allKeys){PJDVRTReadRange r;memcpy(&r,key.bytes,sizeof r);
        if(address<r.address+r.length && r.address<address+length){g_pjdv_read_bytes-=[g_pjdv_read_cache[key] length];[g_pjdv_read_cache removeObjectForKey:key];}}
}
static NSData *pjdv_stage_content_digest(NSData *data) {
    if(!data)return [NSData data];
    g_pjdv_preflight_stats.hashes++;
    NSData *cached=[g_pjdv_digest_cache objectForKey:data];if(cached){g_pjdv_preflight_stats.hashHits++;return cached;}
    uint8_t digest[32];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);g_pjdv_preflight_stats.hashed+=data.length;
    NSData *value=[NSData dataWithBytes:digest length:32];
    if(g_pjdv_digest_cache && g_pjdv_digest_cache.count<512 && g_pjdv_digest_bytes+data.length<=32*1024*1024){[g_pjdv_digest_cache setObject:value forKey:data];g_pjdv_digest_bytes+=data.length;}
    return value;
}
static NSData *pjdv_stage_digest(NSData *v,NSData *i,const void *extra,size_t n) {
    // Hash each immutable source snapshot once, then combine the fixed digests
    // with draw layout. The full content is still authenticated every submit.
    NSData *vd=pjdv_stage_content_digest(v),*id_=pjdv_stage_content_digest(i);
    CC_SHA256_CTX c;CC_SHA256_Init(&c);CC_SHA256_Update(&c,vd.bytes,(CC_LONG)vd.length);
    CC_SHA256_Update(&c,id_.bytes,(CC_LONG)id_.length);if(n)CC_SHA256_Update(&c,extra,(CC_LONG)n);
    uint8_t digest[32];CC_SHA256_Final(digest,&c);return [NSData dataWithBytes:digest length:32];
}
static void pjdv_stage_append(NSMutableData *world,NSMutableData *indices,NSData *w,NSData *i) {
    uint32_t base=(uint32_t)(world.length/16);[world appendData:w];
    if(!base)[indices appendData:i];else{NSMutableData *copy=[i mutableCopy];uint32_t *ix=copy.mutableBytes;for(NSUInteger n=0;n<copy.length/4;n++)ix[n]+=base;[indices appendData:copy];}
}

static NSData *pjdv_stage_read(uint64_t address,NSUInteger length,NSArray *writes) {
    if(!length || length>16*1024*1024 || address>UINT64_MAX-length)return nil;
    void *object;uint64_t offset;
    // A pending GPU write from earlier in this submit cannot be CPU-read.
    if(pend_hits(address,length))return nil;
    g_pjdv_preflight_stats.reads++;PJDVRTReadRange range={address,length};
    NSData *key=g_pjdv_read_cache?[NSData dataWithBytes:&range length:sizeof range]:nil;
    NSData *cached=key?g_pjdv_read_cache[key]:nil;if(cached){g_pjdv_preflight_stats.readHits++;return cached;}
    if(!mtl_addr(address,length,&object,&offset))return nil;
    const uint8_t *bytes=[(__bridge id<MTLBuffer>)object contents];if(!bytes)return nil;
    NSMutableData *copy=[NSMutableData dataWithBytes:bytes+offset length:length];
    for(NSArray *write in writes) {
        uint64_t begin=[write[0] unsignedLongLongValue];NSData *data=write[1];
        uint64_t lo=MAX(address,begin),hi=MIN(address+length,begin+data.length);
        if(lo<hi)memcpy((uint8_t *)copy.mutableBytes+lo-address,(const uint8_t *)data.bytes+lo-begin,hi-lo);
    }
    g_pjdv_preflight_stats.copied+=length;
    if(key && g_pjdv_read_cache.count<512 && g_pjdv_read_bytes+length<=32*1024*1024){g_pjdv_read_cache[key]=copy;g_pjdv_read_bytes+=length;}
    return copy;
}
// Ray tracing consumes positions, not UV/normal/tangent padding. Snapshot
// just XYZ into tightly packed float4s; overlay only bytes actually written
// into those positions, in original command order. The live buffer is never
// modified, and this cache is invalidated by the full source address span.
static NSData *pjdv_stage_positions(uint64_t address,NSUInteger span,uint32_t stride,NSUInteger count,NSArray *writes) {
    if(!count || count>250001 || stride<12 || span!=(count-1)*stride+12 || address>UINT64_MAX-span || pend_hits(address,span))return nil;
    g_pjdv_preflight_stats.reads++;PJDVRTReadRange range={address,span,stride,1};
    NSData *key=g_pjdv_read_cache?[NSData dataWithBytes:&range length:sizeof range]:nil;
    NSData *cached=key?g_pjdv_read_cache[key]:nil;if(cached){g_pjdv_preflight_stats.readHits++;return cached;}
    void *object;uint64_t offset;if(!mtl_addr(address,span,&object,&offset))return nil;
    const uint8_t *base=[(__bridge id<MTLBuffer>)object contents];if(!base)return nil;
    NSMutableData *data=[NSMutableData dataWithLength:count*16];uint8_t *dst=data.mutableBytes;
    for(NSUInteger v=0;v<count;v++){memcpy(dst+v*16,base+offset+v*stride,12);((float *)(dst+v*16))[3]=1;}
    for(NSArray *write in writes){uint64_t begin=[write[0] unsignedLongLongValue];NSData *bytes=write[1];uint64_t end=begin+bytes.length;
        if(begin>=address+span || end<=address)continue;
        NSUInteger first=begin>=address+12?(NSUInteger)((begin-address-12)/stride+1):0;
        NSUInteger last=MIN(count-1,(NSUInteger)((end-address-1)/stride));
        for(NSUInteger v=first;v<=last;v++){uint64_t pos=address+v*stride,lo=MAX(pos,begin),hi=MIN(pos+12,end);
            if(lo<hi)memcpy(dst+v*16+lo-pos,(const uint8_t *)bytes.bytes+lo-begin,hi-lo);}
    }
    for(NSUInteger v=0;v<count;v++){const float *p=(const float *)(dst+v*16);if(!isfinite(p[0])||!isfinite(p[1])||!isfinite(p[2]))return nil;}
    g_pjdv_preflight_stats.copied+=data.length;
    if(key && g_pjdv_read_cache.count<512 && g_pjdv_read_bytes+data.length<=32*1024*1024){g_pjdv_read_cache[key]=data;g_pjdv_read_bytes+=data.length;}
    return data;
}
static BOOL pjdv_stage_pair(NvProg *p) {
    return p && p->sh[0] && p->sh[1] && !strcmp(p->sh[0]->key,"d5400adf2d33a2e2_b") && !strcmp(p->sh[1]->key,"07b21d5490e3e7d2_b");
}
static NSArray *pjdv_stage_mesh_data(const PJDVRTDrawState *s,const p_draw *dw,const p_draw_idx *di,NSArray *writes,BOOL objectSpace,float *transformOut) {
    if(s->color.blend_en || s->attr[0].fmt!=NVN_FORMAT_RGB32F || s->poly.cull==NVN_FACE_FRONT_AND_BACK)return nil;
    int count=dw?dw->count:di->count,primitive=dw?dw->prim:di->prim;
    if(count<3 || count>200000 || (di && (di->instances!=1 || di->base_instance || (di->itype!=1 && di->itype!=2))) ||
       (primitive!=NVN_DRAW_PRIMITIVE_TRIANGLES && primitive!=NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP))return nil;
    va_st attribute=s->attr[0];int stream=attribute.stream;
    if(stream<0 || stream>=16 || s->stream[stream].divisor || s->stream[stream].stride<12)return nil;
    NVNbufferRange vb=s->vbuf[stream];p_bind_buf ub=s->ubo[0][2];
    if(!vb.address || !vb.size || vb.size>8*1024*1024 || ub.size<112)return nil;
    NSData *matrix=pjdv_stage_read(ub.addr,112,writes);
    NSData *index=di?pjdv_stage_read(di->ibuf,(NSUInteger)count*(di->itype==1?2:4),writes):nil;
    if(!matrix || (di && !index))return nil;
    const float *m=matrix.bytes;for(int k=16;k<28;k++)if(!isfinite(m[k]))return nil;
    if(transformOut)memcpy(transformOut,m+16,48);
    if(objectSpace){simd_float3 a={m[16],m[20],m[24]},b={m[17],m[21],m[25]},c={m[18],m[22],m[26]};float determinant=simd_dot(a,simd_cross(b,c));if(!isfinite(determinant)||fabsf(determinant)<1.e-10)return nil;}
    struct {float transform[12];uint32_t stride,offset,primitive,first,count,itype,base,restart,index,objectSpace;} signature={0};
    if(!objectSpace)memcpy(signature.transform,m+16,48);signature.objectSpace=objectSpace;signature.stride=s->stream[stream].stride;signature.offset=attribute.offset;signature.primitive=primitive;signature.first=dw?dw->first:0;signature.count=count;signature.itype=di?di->itype:0;signature.base=di?di->base_vertex:0;signature.restart=s->primitive_restart.enabled;signature.index=s->primitive_restart.index;
    // Index layout is independent of vertex bytes and model transform. Bound
    // size remains in the key so a formerly valid index cannot bypass bounds.
    struct {uint64_t vbSize;uint32_t stride,offset,primitive,first,count,itype,base,restart,index;} indexSignature={0};
    indexSignature.vbSize=vb.size;indexSignature.stride=signature.stride;indexSignature.offset=signature.offset;indexSignature.primitive=primitive;indexSignature.first=signature.first;indexSignature.count=count;indexSignature.itype=signature.itype;indexSignature.base=signature.base;indexSignature.restart=signature.restart;indexSignature.index=signature.index;
    NSData *layoutKey=pjdv_stage_digest(index,nil,&indexSignature,sizeof indexSignature);NSArray *layout=g_pjdv_index_cache[layoutKey];
    NSMutableData *tri;uint32_t minimum,maximum;
    if(layout){tri=layout[0];minimum=[layout[1] unsignedIntValue];maximum=[layout[2] unsignedIntValue];}
    else {
    tri=[NSMutableData data];uint32_t previous[2]={0};maximum=0;minimum=UINT32_MAX;unsigned run=0;
    for(int j=0;j<count;j++) {
        uint32_t raw=dw?(uint32_t)(dw->first+j):di->itype==1?((const uint16_t *)index.bytes)[j]:((const uint32_t *)index.bytes)[j];
        if(di && s->primitive_restart.enabled && raw==s->primitive_restart.index){run=0;continue;}
        int64_t v=(int64_t)raw+(di?di->base_vertex:0);
        if(v<0 || (uint64_t)v*s->stream[stream].stride+attribute.offset+12>vb.size)return nil;
        uint32_t current=(uint32_t)v;maximum=MAX(maximum,current);minimum=MIN(minimum,current);
        if(primitive==NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP) {
            if(run>=2){uint32_t t[3]={previous[0],previous[1],current};if(run&1){t[0]=previous[1];t[1]=previous[0];}
                if(t[0]!=t[1] && t[1]!=t[2] && t[0]!=t[2])[tri appendBytes:t length:12];}
            previous[0]=previous[1];previous[1]=current;run++;
        } else {
            if(run%3==0)previous[0]=current;else if(run%3==1)previous[1]=current;else{uint32_t t[3]={previous[0],previous[1],current};
                if(t[0]!=t[1] && t[1]!=t[2] && t[0]!=t[2])[tri appendBytes:t length:12];}run++;
        }
    }
    if(!tri.length || maximum>250000 || minimum>maximum || tri.length>4*1024*1024)return nil;
    uint32_t *ix=tri.mutableBytes;for(NSUInteger n=0;n<tri.length/4;n++)ix[n]-=minimum;
    if(!g_pjdv_index_cache){g_pjdv_index_cache=[NSMutableDictionary dictionary];g_pjdv_index_order=[NSMutableArray array];}
    while(g_pjdv_index_order.count && (g_pjdv_index_order.count>=128 || g_pjdv_index_bytes+tri.length>4*1024*1024)){
        NSData *old=g_pjdv_index_order.firstObject;g_pjdv_index_bytes-=[g_pjdv_index_cache[old][0] length];[g_pjdv_index_cache removeObjectForKey:old];[g_pjdv_index_order removeObjectAtIndex:0];}
    layout=@[[tri copy],@(minimum),@(maximum)];g_pjdv_index_cache[layoutKey]=layout;[g_pjdv_index_order addObject:layoutKey];g_pjdv_index_bytes+=tri.length;tri=layout[0];
    }
    NSUInteger span=(NSUInteger)(maximum-minimum)*s->stream[stream].stride+12;
    uint64_t start=(uint64_t)minimum*s->stream[stream].stride+attribute.offset;
    if(start>vb.size || vb.address>UINT64_MAX-start || span>vb.size-start)return nil;
    NSData *vertex=pjdv_stage_positions(vb.address+start,span,s->stream[stream].stride,maximum-minimum+1,writes);if(!vertex)return nil;
    NSData *key=pjdv_stage_digest(vertex,tri,&signature,sizeof signature);NSArray *cached=g_pjdv_cpu_mesh_cache[key];
    if(cached){g_pjdv_preflight_stats.meshHits++;return cached;}
    g_pjdv_preflight_stats.meshMisses++;
    NSData *w=vertex;
    if(!objectSpace){NSMutableData *transformed=[vertex mutableCopy];float *out=transformed.mutableBytes;
        for(uint32_t v=0;v<=maximum-minimum;v++){const float *p=(const float *)vertex.bytes+v*4;
            for(int r=0;r<3;r++){out[v*4+r]=fmaf(1,m[(r+4)*4+3],fmaf(p[2],m[(r+4)*4+2],fmaf(p[1],m[(r+4)*4+1],p[0]*m[(r+4)*4])));if(!isfinite(out[v*4+r]))return nil;}}
        w=transformed;
    }
    if(!g_pjdv_cpu_mesh_cache){g_pjdv_cpu_mesh_cache=[NSMutableDictionary dictionary];g_pjdv_cpu_mesh_order=[NSMutableArray array];}
    while(g_pjdv_cpu_mesh_order.count && (g_pjdv_cpu_mesh_order.count>=128 || g_pjdv_cpu_mesh_bytes+w.length+tri.length>32*1024*1024)) {
        NSData *old=g_pjdv_cpu_mesh_order.firstObject;NSArray *data=g_pjdv_cpu_mesh_cache[old];g_pjdv_cpu_mesh_bytes-=[data[0] length]+[data[1] length];[g_pjdv_cpu_mesh_cache removeObjectForKey:old];[g_pjdv_cpu_mesh_order removeObjectAtIndex:0];
    }
    NSArray *result=@[[w copy],[tri copy],key];g_pjdv_cpu_mesh_cache[key]=result;[g_pjdv_cpu_mesh_order addObject:key];g_pjdv_cpu_mesh_bytes+=w.length+tri.length;
    return result;
}
static void pjdv_stage_register(PJDVRTStageScene *scene){for(id r in scene->resources)res_add(r);scene->releaseResources=^(NSArray *resources){for(id r in resources)res_remove(r);};}
static void pjdv_stage_retire(PJDVRTStageScene *scene) { defer_obj_unref(scene); }
static PJDVRTStageScene *pjdv_stage_mesh_scene(NSData *w,NSData *i,NSData *key) {
    PJDVRTStageScene *scene=g_pjdv_mesh_cache[key];if(scene)return scene;
    if(!g_pjdv_mesh_cache){g_pjdv_mesh_cache=[NSMutableDictionary dictionary];g_pjdv_mesh_order=[NSMutableArray array];}
    scene=[[PJDVRTStageScene alloc] initWithDevice:g_dev vertices:w indices:i];pjdv_stage_register(scene);
    while(g_pjdv_mesh_order.count && (g_pjdv_mesh_order.count>=128 || g_pjdv_mesh_bytes+w.length+i.length>32*1024*1024)) {
        NSData *old=g_pjdv_mesh_order.firstObject;PJDVRTStageScene *prior=g_pjdv_mesh_cache[old];g_pjdv_mesh_bytes-=prior->world.length+prior->indexData.length;pjdv_stage_retire(prior);[g_pjdv_mesh_cache removeObjectForKey:old];[g_pjdv_mesh_order removeObjectAtIndex:0];
    }
    g_pjdv_mesh_cache[key]=scene;[g_pjdv_mesh_order addObject:key];g_pjdv_mesh_bytes+=w.length+i.length;return scene;
}
static void pjdv_rt_stage_preflight(const uint8_t *commands) {
    g_pjdv_stage_scene=nil;g_pjdv_stage_draws=nil;
    if(!pjdv_rt_stage_mode()){atomic_store(&g_pjdv_rt_stage_status,0);return;}
    if(g_pjdv_stage_failed || !pjdv_rt_stage_supported((__bridge void *)g_dev)){atomic_store(&g_pjdv_rt_stage_status,3);return;}
    double start=pjdv_rt_clock();
    @autoreleasepool { @try {
        static int cache=-1;if(cache<0){const char *e=getenv("PJDV_RT_PREFLIGHT_CACHE");cache=!(e && !strcmp(e,"0"));}
        pjdv_stage_read_begin(cache);
        PJDVRTDrawState s=S;NSMutableArray *writes=[NSMutableArray array];NSUInteger writeBytes=0;
        NSMutableData *world=[NSMutableData data],*indices=[NSMutableData data];NSMutableArray *meshData=[NSMutableArray array];NSMutableSet *draws=[NSMutableSet set];
        const uint8_t *p=commands,*returns[16];unsigned depth=0,steps=0;BOOL complete=NO;
        while(++steps<200000) {
            op_hdr h;memcpy(&h,p,sizeof h);if(h.size<8 || h.size>16*1024*1024)break;const void *a=p+8;
            if(h.op==OP_END){if(depth){p=returns[--depth];continue;}complete=YES;break;}
            if(h.op==OP_JUMP){memcpy(&p,a,8);continue;}
            if(h.op==OP_CALL){if(depth==16)break;returns[depth++]=p+h.size;memcpy(&p,a,8);continue;}
            // Unknown GPU-produced data cannot be reconstructed by preflight.
            if(h.op==OP_DISPATCH || h.op==OP_COPY_T2B)break;
            if(h.op==OP_COPY_B2B || h.op==OP_UPDATE_UB) {
                uint64_t src=0,dst,n;NSData *data;
                if(h.op==OP_UPDATE_UB){memcpy(&dst,a,8);memcpy(&n,(const uint8_t *)a+8,8);if(n>h.size-24)break;data=[NSData dataWithBytesNoCopy:(void *)((const uint8_t *)a+16) length:n freeWhenDone:NO];}
                else {memcpy(&src,a,8);memcpy(&dst,(const uint8_t *)a+8,8);memcpy(&n,(const uint8_t *)a+16,8);data=pjdv_stage_read(src,n,writes);}
                if(!data || dst>UINT64_MAX-n || writes.count==512 || writeBytes+n>16*1024*1024)break;
                [writes addObject:@[@(dst),data]];writeBytes+=n;pjdv_stage_note_write(dst,n);
            } else switch(h.op) {
                case OP_BIND_PROGRAM:s.prog=((const p_bind_program *)a)->prog;break;
                case OP_BIND_STATE:{const p_bind_state *b=a;if(b->kind==1)memcpy(&s.color,b->bytes,sizeof s.color);else if(b->kind==4)memcpy(&s.poly,b->bytes,sizeof s.poly);break;}
                case OP_BIND_VATTR:{const p_bind_vattr *b=a;s.nattr=b->n;memcpy(s.attr,b->st,b->n*4);break;}
                case OP_BIND_VSTREAM:{const p_bind_vstream *b=a;s.nstream=b->n;memcpy(s.stream,b->st,b->n*8);break;}
                case OP_BIND_VBUF:{const p_bind_vbuf *b=a;memcpy(s.vbuf+b->first,b->r,b->n*sizeof *b->r);break;}
                case OP_BIND_UBO:{const p_bind_buf *b=a;if(b->stage>=0 && b->stage<6 && b->index>=0 && b->index<16)s.ubo[b->stage][b->index]=*b;break;}
                case OP_PRIMITIVE_RESTART:s.primitive_restart=*(const p_primitive_restart *)a;break;
                case OP_DRAW:case OP_DRAW_IDX:
                    if(pjdv_stage_pair(s.prog?prog_get(s.prog):nil) && draws.count<96) {
                        float transform[12];
                        NSArray *mesh=pjdv_stage_mesh_data(&s,h.op==OP_DRAW?a:NULL,h.op==OP_DRAW_IDX?a:NULL,writes,YES,transform);
                        if(mesh){[draws addObject:[NSValue valueWithPointer:p]];[meshData addObject:@[mesh[0],mesh[1],[NSData dataWithBytes:transform length:48],mesh[2]]];}
                    }
                    break;
                default:break;
            }
            p+=h.size;
        }
        if(!complete || !draws.count){atomic_store(&g_pjdv_rt_stage_status,2);return;}
        if(!g_pjdv_stage_function) {
            NSString *path=[g_msl_dir stringByAppendingPathComponent:@"07b21d5490e3e7d2_b.metallib"];
            NSString *source=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            pjdv_rt_check(source!=nil,@"RT stage source unavailable");NSError *error=nil;
            MTLCompileOptions *options=[MTLCompileOptions new];if (@available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *)) options.mathMode=MTLMathModeSafe; else options.fastMathEnabled=NO;
            id<MTLLibrary> library=[g_dev newLibraryWithSource:pjdv_rt_stage_source(source) options:options error:&error];
            pjdv_rt_check(library!=nil,error.localizedDescription?:@"RT stage shader failed");
            g_pjdv_stage_function=[library newFunctionWithName:@"pjdvStageRT"];pjdv_rt_check(g_pjdv_stage_function!=nil,@"RT stage entry missing");
        }
        if(!g_pjdv_stage_cache)g_pjdv_stage_cache=[NSMutableArray array];
        NSMutableArray *meshes=[NSMutableArray array];NSMutableData *transforms=[NSMutableData data];NSUInteger triangleCount=0;
        for(NSArray *data in meshData){[meshes addObject:pjdv_stage_mesh_scene(data[0],data[1],data[3])];triangleCount+=[data[1] length]/12;[transforms appendData:data[2]];}
        PJDVRTStageScene *scene=nil;
        for(PJDVRTStageScene *candidate in g_pjdv_stage_cache)if([candidate->children isEqual:meshes] && [candidate->instanceTransforms isEqual:transforms]){scene=candidate;break;}
        BOOL build=!scene;
        if(!scene){
            scene=[[PJDVRTStageScene alloc] initWithDevice:g_dev meshes:meshes transforms:transforms];
            pjdv_stage_register(scene);
            rp_flush();if(g_blit){enc_b_end(g_blit);g_blit=nil;}[scene encodeBuild:g_cb];
            if(g_pjdv_stage_cache.count==32){PJDVRTStageScene *old=g_pjdv_stage_cache.firstObject;pjdv_stage_retire(old);[g_pjdv_stage_cache removeObjectAtIndex:0];}
        }else [g_pjdv_stage_cache removeObjectIdenticalTo:scene];
        [g_pjdv_stage_cache addObject:scene];g_pjdv_stage_scene=scene;g_pjdv_stage_draws=draws;atomic_store(&g_pjdv_rt_stage_status,1);
        static uint64_t calls,builds;static double milliseconds;calls++;builds+=build;milliseconds+=(pjdv_rt_clock()-start)*1000;
        if(calls==1 || calls%300==0){MLOG("PJDV RT preflight IO: reads=%llu hits=%llu snapshot=%.2fMiB hashes=%llu hits=%llu hashed=%.2fMiB meshHits=%llu meshMisses=%llu cache=%d",g_pjdv_preflight_stats.reads,g_pjdv_preflight_stats.readHits,g_pjdv_preflight_stats.copied/1048576.,g_pjdv_preflight_stats.hashes,g_pjdv_preflight_stats.hashHits,g_pjdv_preflight_stats.hashed/1048576.,g_pjdv_preflight_stats.meshHits,g_pjdv_preflight_stats.meshMisses,cache);memset(&g_pjdv_preflight_stats,0,sizeof g_pjdv_preflight_stats);}
        if(calls==1 || calls%300==0)MLOG("PJDV RT stage active: calls=%llu builds=%llu draws=%lu triangles=%lu preflightMean=%.3fms scope=opaque-static-stage direct-light-only",calls,builds,(unsigned long)draws.count,(unsigned long)triangleCount,milliseconds/calls);
        if(g_pjdv_dump_frame==atomic_load(&g_cur_frame)) {
            uint64_t frame=g_pjdv_dump_frame;
            if(scene->statsFrame!=frame){id<MTLBuffer> old=scene->stats;scene->stats=[g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];res_add(scene->stats);defer_obj_release(old);[scene->resources removeObjectIdenticalTo:old];[scene->resources addObject:scene->stats];scene->statsFrame=frame;}
            id<MTLBuffer> counters=scene->stats;
            NSString *prefix=[@(getenv("DM_TEMP")) stringByAppendingPathComponent:[NSString stringWithFormat:@"rt-live-F%llu",(unsigned long long)g_pjdv_dump_frame]];
            for(NSArray *data in meshData){NSData *v=data[0];const float *src=v.bytes,*m=[data[2] bytes];NSMutableData *w=[NSMutableData dataWithLength:v.length];float *dst=w.mutableBytes;
                for(NSUInteger n=0;n<v.length/16;n++){for(int r=0;r<3;r++)dst[n*4+r]=fmaf(1,m[r*4+3],fmaf(src[n*4+2],m[r*4+2],fmaf(src[n*4+1],m[r*4+1],src[n*4]*m[r*4])));dst[n*4+3]=1;}
                pjdv_stage_append(world,indices,w,data[1]);}
            [world writeToFile:[prefix stringByAppendingString:@"-world.bin"] atomically:YES];[indices writeToFile:[prefix stringByAppendingString:@"-indices.bin"] atomically:YES];
            [g_commit_blocks addObject:^{const uint32_t *s=counters.contents;NSDictionary *j=@{@"frame":@(frame),@"draws":@(draws.count),@"triangles":@(indices.length/12),@"sampled_fragment_rays":@(s[0]),@"occluded_fragment_rays":@(s[1]),@"bias":@(scene->bias),@"maximum_distance":@(scene->maximum),@"scope":@"Same-command-list opaque static stage; original directional light; direct diffuse/specular only; ESM preserved for other casters"};
                NSData *data=[NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:nil];[data writeToFile:[prefix stringByAppendingString:@".json"] atomically:YES];}];
        }
    }@catch(NSException *e){g_pjdv_stage_failed=1;atomic_store(&g_pjdv_rt_stage_status,3);MLOG("PJDV RT stage fallback: %s",e.reason.UTF8String);}
    @finally {pjdv_stage_read_end();} }
}
static id<MTLFunction> pjdv_rt_stage_draw(NvProg *p) {
    if(!pjdv_rt_stage_mode() || !g_pjdv_stage_scene || !pjdv_stage_pair(p) || S.color.blend_en ||
       S.ubo[0][1].addr!=S.ubo[1][1].addr || ![g_pjdv_stage_draws containsObject:[NSValue valueWithPointer:g_exec_cur]])return nil;
    return g_pjdv_stage_function;
}
static void pjdv_rt_stage_bind(RENC en) {
    if (@available(macOS 14.0, macCatalyst 17.0, iOS 17.0, *)) {
    PJDVRTStageScene *s=g_pjdv_stage_scene;id<MTLBuffer> params;size_t offset=arena_alloc(16,&params);
    float v[4]={s->bias,s->maximum,g_pjdv_dump_frame==atomic_load(&g_cur_frame),getenv("PJDV_RT_STAGE_MASK")?1:0};memcpy((uint8_t *)params.contents+offset,v,16);
#if DM_NVN_M3
    [en setFragmentAccelerationStructure:s->tlas atBufferIndex:1];for(PJDVRTStageScene *child in s->children)[en useResource:child->blas usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    [en setFragmentBuffer:params offset:offset atIndex:2];[en setFragmentBuffer:s->stats offset:0 atIndex:3];
#else
    [g_ft setResource:s->tlas.gpuResourceID atBufferIndex:1];[g_ft setAddress:params.gpuAddress+offset atIndex:2];[g_ft setAddress:s->stats.gpuAddress atIndex:3];
#endif

    }
    
}
static void pjdv_rt_stage_release(void) {
    for(PJDVRTStageScene *s in g_pjdv_stage_cache)pjdv_stage_retire(s);
    for(PJDVRTStageScene *s in g_pjdv_mesh_cache.allValues)pjdv_stage_retire(s);
    g_pjdv_index_cache=nil;g_pjdv_index_order=nil;g_pjdv_index_bytes=0;
    g_pjdv_mesh_cache=nil;g_pjdv_mesh_order=nil;g_pjdv_mesh_bytes=0;
    g_pjdv_cpu_mesh_cache=nil;g_pjdv_cpu_mesh_order=nil;g_pjdv_cpu_mesh_bytes=0;pjdv_stage_read_end();
    g_pjdv_stage_cache=nil;g_pjdv_stage_scene=nil;g_pjdv_stage_draws=nil;g_pjdv_rt_active_fn=nil;g_pjdv_stage_failed=0;atomic_store(&g_pjdv_rt_stage_status,0);
}

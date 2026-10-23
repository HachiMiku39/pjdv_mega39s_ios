// One-frame geometry bridge for the authenticated opaque stage_blinn_nonsss
// shader. Other variants, skinning, instancing and transparency are excluded.
static void pjdv_rt_geometry_capture(NvProg *program,const p_draw *dw,const p_draw_idx *di) {
    static int enabled=-1;static uint64_t lastFrame=UINT64_MAX;static unsigned drawIndex;
    if(enabled<0){const char *e=getenv("PJDV_RT_GEOMETRY");enabled=e && !strcmp(e,"1");}
    uint64_t frame=atomic_load(&g_cur_frame);
    if(!enabled || frame!=g_pjdv_dump_frame || !program || !program->sh[0] || !program->sh[1])return;
    if(strcmp(program->sh[0]->key,"d5400adf2d33a2e2_b") || strcmp(program->sh[1]->key,"07b21d5490e3e7d2_b"))return;
    if(lastFrame!=frame){lastFrame=frame;drawIndex=0;}
    if(drawIndex>=16 || S.color.blend_en || S.attr[0].fmt!=NVN_FORMAT_RGB32F)return;
    int primitive=dw?dw->prim:di->prim,count=dw?dw->count:di->count;
    if(count<3 || count>200000 || (di && (di->instances!=1 || di->base_instance || di->itype<1 || di->itype>2)) ||
       (primitive!=NVN_DRAW_PRIMITIVE_TRIANGLES && primitive!=NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP))return;
    va_st attribute=S.attr[0];int stream=attribute.stream;
    if(stream<0 || stream>=16 || S.stream[stream].divisor || S.stream[stream].stride<12)return;
    NVNbufferRange vb=S.vbuf[stream];const p_bind_buf *uniform=&S.ubo[0][2];
    void *vobject,*cobject,*iobject;uint64_t voff,coff,ioff=0;const uint8_t *indexBytes=NULL;
    if(vb.size>16*1024*1024 || uniform->size<7*16 || pend_hits(vb.address,vb.size) || pend_hits(uniform->addr,7*16) ||
       !mtl_addr(vb.address,vb.size,&vobject,&voff) || !mtl_addr(uniform->addr,7*16,&cobject,&coff))return;
    const uint8_t *vdata=[(__bridge id<MTLBuffer>)vobject contents];const uint8_t *cdata=[(__bridge id<MTLBuffer>)cobject contents];
    if(!vdata || !cdata)return;vdata+=voff;cdata+=coff;
    if(di){size_t bytes=(size_t)count*(di->itype==1?2:4);
        if(pend_hits(di->ibuf,bytes) || !mtl_addr(di->ibuf,bytes,&iobject,&ioff))return;
        indexBytes=[(__bridge id<MTLBuffer>)iobject contents];if(!indexBytes)return;indexBytes+=ioff;
    }
    NSMutableData *triangles=[NSMutableData data];uint32_t previous[2]={0};unsigned run=0;uint32_t maxIndex=0;
    for(int i=0;i<count;i++){
        uint32_t raw=dw?(uint32_t)(dw->first+i):di->itype==1?((const uint16_t *)indexBytes)[i]:((const uint32_t *)indexBytes)[i];
        if(di && S.primitive_restart.enabled && raw==S.primitive_restart.index){run=0;continue;}
        int64_t vertex=(int64_t)raw+(di?di->base_vertex:0);
        if(vertex<0 || (uint64_t)vertex*S.stream[stream].stride+attribute.offset+12>vb.size)return;
        uint32_t current=(uint32_t)vertex;maxIndex=MAX(maxIndex,current);
        if(primitive==NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP){
            if(run>=2){uint32_t tri[3]={previous[0],previous[1],current};if(run&1){tri[0]=previous[1];tri[1]=previous[0];}
                if(tri[0]!=tri[1] && tri[1]!=tri[2] && tri[0]!=tri[2])[triangles appendBytes:tri length:sizeof(tri)];}
            previous[0]=previous[1];previous[1]=current;run++;
        }else{
            if(run%3==0)previous[0]=current;else if(run%3==1)previous[1]=current;else{uint32_t tri[3]={previous[0],previous[1],current};
                if(tri[0]!=tri[1] && tri[1]!=tri[2] && tri[0]!=tri[2])[triangles appendBytes:tri length:sizeof(tri)];}run++;
        }
    }
    if(!triangles.length || maxIndex>250000)return;
    float matrix[28];memcpy(matrix,cdata,sizeof(matrix));for(int i=0;i<28;i++)if(!isfinite(matrix[i]))return;
    NSMutableData *world=[NSMutableData dataWithLength:((size_t)maxIndex+1)*16],*clip=[NSMutableData dataWithLength:((size_t)maxIndex+1)*16];
    float *w=world.mutableBytes,*c=clip.mutableBytes;
    for(uint32_t i=0;i<=maxIndex;i++){
        float position[4]={0,0,0,1};memcpy(position,vdata+(size_t)i*S.stream[stream].stride+attribute.offset,12);
        if(!isfinite(position[0])||!isfinite(position[1])||!isfinite(position[2]))return;
        for(int r=0;r<7;r++){
            float value=fmaf(position[3],matrix[r*4+3],fmaf(position[2],matrix[r*4+2],fmaf(position[1],matrix[r*4+1],position[0]*matrix[r*4])));
            if(!isfinite(value))return;if(r<4)c[i*4+r]=value;else w[i*4+r-4]=value;
        }w[i*4+3]=1;
    }
    const char *temp=getenv("DM_TEMP");if(!temp)return;
    NSString *prefix=[@(temp) stringByAppendingPathComponent:[NSString stringWithFormat:@"rt-mesh-F%llu-D%u",(unsigned long long)frame,drawIndex++]];
    BOOL saved=[world writeToFile:[prefix stringByAppendingString:@"-world.bin"] atomically:YES] &&
               [clip writeToFile:[prefix stringByAppendingString:@"-clip.bin"] atomically:YES] &&
               [triangles writeToFile:[prefix stringByAppendingString:@"-indices.bin"] atomically:YES];
    NSMutableArray *rows=[NSMutableArray array];for(int r=0;r<7;r++)[rows addObject:@[@(matrix[r*4]),@(matrix[r*4+1]),@(matrix[r*4+2]),@(matrix[r*4+3])]];
    NSDictionary *metadata=@{@"frame":@(frame),@"draw":@(drawIndex-1),@"vertex_count":@(maxIndex+1),@"triangle_count":@(triangles.length/12),
        @"original_primitive":@(primitive),@"original_index_count":@(count),@"world_vertex_stride":@16,@"index_format":@"uint32 triangle list",
        @"vertex_shader":@(program->sh[0]->key),@"fragment_shader":@(program->sh[1]->key),@"original_vertex_stride":@(S.stream[stream].stride),
        @"original_cull":@(S.poly.cull),@"uniform_register":@2,@"transform_rows":rows,
        @"scope":@"Opaque static stage subset. World rows4-6 and clip rows0-3 follow this original vertex shader; no skinning, transparency or final RT composition."};
    NSData *json=[NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[prefix stringByAppendingString:@".json"] atomically:YES];
    MLOG("PJDV RT mesh capture F%llu D%u vertices=%u triangles=%lu saved=%d",(unsigned long long)frame,drawIndex-1,maxIndex+1,(unsigned long)(triangles.length/12),saved);
}

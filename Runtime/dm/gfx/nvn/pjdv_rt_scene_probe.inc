// Offscreen test of a single captured opaque stage mesh. No lighting or
// reflection is inserted into the game's final image by this diagnostic.
static NSDictionary *pjdv_rt_scene_validate(id<MTLDevice> device,NSString *prefix) API_AVAILABLE(ios(26.0), macos(26.0), macCatalyst(26.0)) {
    if (@available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *)) {} else
        return @{@"status":@"SKIP",@"reason":@"RT diagnostic requires OS 26"};
    @try {
        pjdv_rt_check(device.supportsRaytracing && [device supportsFamily:MTLGPUFamilyApple9],@"Apple9 ray tracing unavailable");
        NSData *v=[NSData dataWithContentsOfFile:[prefix stringByAppendingString:@"-world.bin"]];
        NSData *i=[NSData dataWithContentsOfFile:[prefix stringByAppendingString:@"-indices.bin"]];
        pjdv_rt_check(v.length>0 && v.length%16==0 && v.length<=4*1024*1024 && i.length>0 && i.length%12==0 && i.length<=1024*1024,@"Missing or oversized captured stage mesh");
        const simd_float4 *positions=v.bytes;const uint32_t *indices=i.bytes;NSUInteger nv=v.length/16,nt=i.length/12;
        simd_double3 lo={INFINITY,INFINITY,INFINITY},hi={-INFINITY,-INFINITY,-INFINITY},areas={0,0,0};
        for(NSUInteger j=0;j<nt;j++) {
            simd_double3 p[3];for(int k=0;k<3;k++) {
                pjdv_rt_check(indices[j*3+k]<nv,@"Stage index outside vertex buffer");simd_float4 f=positions[indices[j*3+k]];
                pjdv_rt_check(isfinite(f.x)&&isfinite(f.y)&&isfinite(f.z),@"Non-finite stage position");
                p[k]=(simd_double3){f.x,f.y,f.z};lo=simd_min(lo,p[k]);hi=simd_max(hi,p[k]);
            }
            areas+=simd_abs(simd_cross(p[1]-p[0],p[2]-p[0]));
        }
        int axis=areas.x>areas.y && areas.x>areas.z?2:areas.y>areas.z?1:0;
        int depthAxis=axis==0?2:axis==1?1:0,uAxis=axis==2?1:0,vAxis=axis==0?1:2;
        double span=simd_reduce_max(hi-lo),margin=MAX(span*.02,.1);
        pjdv_rt_check(isfinite(span)&&span>0 && span<1e7,@"Invalid stage bounds");
        PJDVRTProbe *probe=[[PJDVRTProbe alloc] initWithDevice:device];[probe setMeshVertices:v indices:i];
        float data[12]={(float)(lo[uAxis]-margin),(float)(lo[vAxis]-margin),(float)(hi[uAxis]-lo[uAxis]+2*margin),(float)(hi[vAxis]-lo[vAxis]+2*margin),
            (float)(lo[depthAxis]-margin),(float)(hi[depthAxis]-lo[depthAxis]+2*margin),1,0,probe->resolution,probe->resolution,axis,0};
        memcpy(probe->params.contents,data,sizeof(data));
        [probe begin];[probe build:YES refit:NO];[probe build:NO refit:NO];[probe encodeTrace];
        NSDictionary *build=[probe finish];
        // A warm trace isolates traversal cost from acceleration structure build.
        [probe begin];[probe encodeTrace];NSDictionary *trace=[probe finish];
        double cpuStart=pjdv_rt_clock(),maxError=0,tolerance=MAX(.01,span*1e-5);NSUInteger checked=0,ambiguous=0,mismatches=0,hits=0;
        simd_double3 direction={0,0,0};direction[depthAxis]=1;const float *gpu=probe->output.contents;
        for(NSUInteger y=4;y<probe->resolution;y+=8)for(NSUInteger x=4;x<probe->resolution;x+=8) {
            // Match the float-valued ray origins supplied to the GPU; reference
            // triangle intersections below use independent double arithmetic.
            float uf=data[0]+((float)x+.5f)/(float)probe->resolution*data[2],vf=data[1]+((float)y+.5f)/(float)probe->resolution*data[3];
            simd_double3 origin={0,0,0};origin[uAxis]=uf;origin[vAxis]=vf;origin[depthAxis]=data[4];
            double closest=INFINITY,edge=INFINITY;
            for(NSUInteger j=0;j<nt;j++) {
                simd_float4 fa=positions[indices[j*3]],fb=positions[indices[j*3+1]],fc=positions[indices[j*3+2]];
                simd_double3 a={fa.x,fa.y,fa.z},b={fb.x,fb.y,fb.z},c={fc.x,fc.y,fc.z},e1=b-a,e2=c-a,p=simd_cross(direction,e2);
                double determinant=simd_dot(e1,p);if(fabs(determinant)<1e-12)continue;
                simd_double3 s=origin-a,q=simd_cross(s,e1);double inverse=1/determinant,u=simd_dot(s,p)*inverse,z=simd_dot(direction,q)*inverse;
                if(u < -1e-6 || z < -1e-6 || u+z>1+1e-6)continue;
                double d=simd_dot(e2,q)*inverse;if(d<.001 || d>data[5] || d>=closest)continue;
                closest=d;edge=MIN(MIN(fabs(u),fabs(z)),fabs(1-u-z));
            }
            const float *r=gpu+(y*probe->resolution+x)*4;
            if(!isfinite(r[0])||!isfinite(r[1])||!isfinite(r[2])||!isfinite(r[3])){checked++;mismatches++;continue;}
            if(edge<1e-6){ambiguous++;continue;}
            BOOL expected=isfinite(closest);checked++;if(expected)hits++;
            if((r[0]>.5)!=expected){mismatches++;continue;}
            if(expected){double error=fabs(r[1]-closest);maxError=MAX(maxError,error);if(error>tolerance)mismatches++;}
        }
        NSString *status=checked>=1000 && hits>0 && mismatches==0?@"PASS":@"FAIL";
        NSData *rays=[NSData dataWithBytes:probe->output.contents length:probe->output.length];
        [rays writeToFile:[prefix stringByAppendingString:@"-rt-rays.bin"] atomically:YES];
        return @{@"status":status,@"scope":@"Captured opaque static stage mesh; offscreen orthographic ray test. No character skinning, alpha hair, game lighting or final RT composition.",
            @"mesh":prefix.lastPathComponent,@"device":device.name,@"backend":DM_NVN_M3?@"Metal 3":@"Metal 4",@"vertices":@(nv),@"triangles":@(nt),@"gpu_rays":@(probe->resolution*probe->resolution),
            @"cpu_checked_rays":@(checked),@"boundary_ambiguous_rays":@(ambiguous),@"cpu_hits":@(hits),@"mismatches":@(mismatches),@"max_distance_error":@(maxError),@"distance_tolerance":@(tolerance),
            @"projection_axis":@(depthAxis),@"ray_parameters":@[@(data[0]),@(data[1]),@(data[2]),@(data[3]),@(data[4]),@(data[5])],@"build_and_trace":build,@"warm_trace":trace,@"cpu_reference_ms":@((pjdv_rt_clock()-cpuStart)*1000)};
    }@catch(NSException *exception){return @{@"status":@"FAIL",@"reason":exception.reason?:exception.name};}
}

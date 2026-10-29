"""Bounded classic Auth3D conversion. Never discards or synthesizes curves.

Format research: ReDIVA src/KKdLib/a3da.cpp, a3dc_read_a3da_key_f16
and a3dc_read_a3da_model_transform. This implementation validates every range
and preserves unknown text properties rather than reconstructing whole scenes.
"""
import struct,math
MAX_BYTES=128*1024*1024

def convert(raw):
    if raw.startswith(b'#A3DA'):return raw,{'converted':False}
    if not raw.startswith(b'#A3DC') or len(raw)>MAX_BYTES:raise ValueError('Unsupported Auth3D container')
    def span(data,offset,length):
        if offset<0 or length<0 or offset+length>len(data):raise ValueError('Auth3D range outside input')
        return memoryview(data)[offset:offset+length]
    sub=struct.unpack_from('>I',raw,24)[0];count,stride=struct.unpack_from('>HH',raw,28)
    if count!=2 or stride<12:raise ValueError('Unsupported subheaders')
    chunks={}
    for i in range(count):
        h=span(raw,sub+i*stride,12);tag=bytes(h[:4]).rstrip(b'\0');off,size=struct.unpack_from('>II',h,4)
        chunks[tag]=span(raw,off,size)
    text=bytes(chunks[b'P']).rstrip(b'\0').decode('utf-8');binary=chunks[b'BL'];props={}
    for line in text.splitlines():
        if not line or line.startswith('#'):continue
        key,sep,value=line.partition('=')
        if not sep:raise ValueError('Malformed Auth3D property')
        if key in props:raise ValueError('Duplicate Auth3D property '+key)
        props[key]=value
    original=props.copy();compression=int(props.get('_.compress_f16','0'));assert compression in (0,1,2)
    stats={'converted':True,'curves':0,'keys':0,'transforms':0,'source_bytes':len(raw)}
    def f(v):
        if not math.isfinite(v):raise ValueError('Non-finite curve value')
        result=format(v,'.9g')
        assert struct.pack('<f',float(result))==struct.pack('<f',v),'Float precision changed'
        return result
    def emit(prefix,typ,pre,post,maximum,keys,value=0):
        stats['curves']+=1;props[prefix+'.type']=str(typ)
        if typ==0:return
        if typ==1:props[prefix+'.value']=f(value);return
        if typ not in (2,3,4):raise ValueError('Unknown curve type')
        props[prefix+'.max']=f(maximum)
        if pre:props[prefix+'.ep_type_pre']=str(pre)
        if post:props[prefix+'.ep_type_post']=str(post)
        props[prefix+'.key.length']=str(len(keys));stats['keys']+=len(keys)
        for i,key in enumerate(keys):
            props[f'{prefix}.key.{i}.type']='3';props[f'{prefix}.key.{i}.data']='('+','.join(map(f,key))+')'
    def curve(prefix,offset,compression=0):
        h=span(binary,offset,8);flags,value=struct.unpack('<If',h);typ=flags&255
        if typ<=1:emit(prefix,typ,0,0,0,[],value);return
        h=span(binary,offset,16);maximum,n=struct.unpack_from('<fI',h,8)
        if n>1000000:raise ValueError('Curve key limit exceeded')
        fmt=['<4f','<heff','<heee'][compression];size=struct.calcsize(fmt);data=span(binary,offset+16,n*size)
        keys=list(struct.iter_unpack(fmt,data));emit(prefix,typ,(flags>>8)&15,(flags>>12)&15,maximum,keys)
    for key,value in original.items():
        if key.endswith('.model_transform.bin_offset'):
            prefix=key[:-len('.model_transform.bin_offset')];off=int(value);pointers=struct.unpack('<10I',span(binary,off,40));stats['transforms']+=1
            for i,(name,pointer) in enumerate(zip(['scale.x','scale.y','scale.z','rot.x','rot.y','rot.z','trans.x','trans.y','trans.z','visibility'],pointers)):
                curve(prefix+'.'+name,pointer,compression if 3<=i<6 else 0)
            del props[key]
        elif key.endswith('.bin_offset'):
            curve(key[:-len('.bin_offset')],int(value));del props[key]
        elif key.endswith('.raw_data.value_list_offset'):
            prefix=key[:-len('.raw_data.value_list_offset')];n=int(original[prefix+'.raw_data.value_list_size'])
            if n%4:raise ValueError('Binary raw curve count is not four-wide')
            data=span(binary,int(value),n*4);keys=list(struct.iter_unpack('<4f',data))
            for suffix in ['.raw_data.value_list_offset','.raw_data.value_list_size','.raw_data.value_type','.raw_data_key_type']:props.pop(prefix+suffix,None)
            emit(prefix,int(original[prefix+'.type']),int(original.get(prefix+'.ep_type_pre','0')),int(original.get(prefix+'.ep_type_post','0')),float(original.get(prefix+'.max','0')),keys)
    props.pop('_.compress_f16',None)
    assert all('.bin_offset' not in k and not k.endswith('.value_list_offset') for k in props)
    for key,value in original.items():
        if key in props:assert props[key]==value,('Original property changed',key)
    result=b'#A3DA__________\n'+('\n'.join(k+'='+v for k,v in sorted(props.items()))+'\n').encode()
    if len(result)>MAX_BYTES:raise ValueError('Expanded Auth3D exceeds bounded conversion limit')
    stats['output_bytes']=len(result);return result,stats

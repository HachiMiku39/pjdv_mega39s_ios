// M39 main+0x38430: gzip-only, one bounded inflate(Z_FINISH).
// The guest truncates input/output capacity to u32 and only updates *size on
// stream end. Keep that contract, including CRC/ISIZE validation and errors.
#pragma once
#include <stdint.h>
#include <string.h>
#include <zlib.h>
static int pjdv_gzip_decode(void *out,uint64_t *size,const void *in,uint32_t bytes){
    z_stream stream;memset(&stream,0,sizeof stream);
    stream.next_in=(Bytef *)in;stream.avail_in=bytes;
    stream.next_out=(Bytef *)out;stream.avail_out=(uint32_t)*size;
    int result=inflateInit2(&stream,31);if(result)return result;
    result=inflate(&stream,Z_FINISH);
    if(result==Z_STREAM_END){*size=stream.total_out;return inflateEnd(&stream);}
    inflateEnd(&stream);return result==Z_OK?Z_BUF_ERROR:result;
}

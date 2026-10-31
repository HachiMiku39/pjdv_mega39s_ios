"""Bounded offline conversion of one unencrypted IVF/VP9 USM to H.264 MP4.

Container offsets cross-checked with darkruss48/usm-toolkit (MIT), commit
21d43276afc2edb627af9bab3486093c5c69d9b8, src/usm_stream.cpp.
No game assets, keys or external executable are bundled. FFmpeg is required.
"""
from pathlib import Path
import argparse,ctypes,errno,json,os,shutil,struct,subprocess,time
BLOCK=1024*1024
class UnsupportedVideo(ValueError):pass

def copy_video(source,write):
    """Write a single complete IVF stream; input chunks and frames are bounded."""
    size=source.stat().st_size;offset=0;meta=None;frames=0;last=-1;step=0;ended=False
    with source.open('rb') as f:
        while offset<size:
            f.seek(offset);h=f.read(32)
            if len(h)!=32:raise UnsupportedVideo('Truncated USM chunk header')
            if offset==0 and h[:4]!=b'CRID':raise UnsupportedVideo('Missing USM CRID header')
            length=struct.unpack_from('>I',h,4)[0];header,padding=struct.unpack_from('>HH',h,8)
            end=offset+8+length;start=offset+8+header;stop=end-padding
            if header<24 or not start<=stop<=end<=size or end<=offset:raise UnsupportedVideo('Invalid USM chunk bounds')
            if h[:4] not in (b'CRID',b'@SFV',b'@SFA',b'@SBT',b'@CUE',b'@ALP'):raise UnsupportedVideo('Unknown USM chunk type')
            if h[:4]==b'@ALP' and h[15]==0:raise UnsupportedVideo('Alpha video is outside this converter profile')
            if h[:4]==b'@SFV' and h[15]==2:
                f.seek(start);ended=f.read(min(32,stop-start)).startswith(b'#CONTENTS END') or ended
            if h[:4]==b'@SFV' and h[15]==0:
                if h[12]!=0:raise UnsupportedVideo('Multiple video channels are not supported')
                f.seek(start)
                if meta is None:
                    if stop-start<32:raise UnsupportedVideo('Truncated IVF header')
                    b=f.read(32);start+=len(b)
                    if len(b)!=32 or b[:4]!=b'DKIF' or b[8:12]!=b'VP90':raise UnsupportedVideo('Expected an unencrypted IVF/VP9 stream')
                    version,hlen=struct.unpack_from('<HH',b,4);w,ht=struct.unpack_from('<HH',b,12);rate,scale,count=struct.unpack_from('<III',b,16)
                    if version or hlen!=32 or not 0<w<=4096 or not 0<ht<=4096 or not scale or not 1<=rate/scale<=1000000 or count>1000000000:raise UnsupportedVideo('Unsupported IVF header')
                    meta={'width':w,'height':ht,'rate':rate,'scale':scale,'declared_frames':count};write(b)
                while start<stop:
                    b=f.read(12);start+=len(b)
                    if len(b)!=12 or start>stop:raise UnsupportedVideo('Truncated IVF frame header')
                    n,stamp=struct.unpack('<IQ',b)
                    if not 0<n<=16*BLOCK or start+n>stop or stamp<last:raise UnsupportedVideo('Invalid/split IVF frame')
                    step=stamp-last if last>=0 and stamp>last else step;last=stamp;write(b)
                    while n:
                        data=f.read(min(n,BLOCK))
                        if not data:raise UnsupportedVideo('Truncated IVF frame')
                        write(data);n-=len(data);start+=len(data)
                    frames+=1
                    if frames>1000000:raise UnsupportedVideo('Video exceeds the frame limit')
            offset=end
    if not meta or not frames:raise UnsupportedVideo('Missing IVF frames')
    semantics='frames'
    if meta['declared_frames'] not in (0,frames):
        # Some CRI writers put duration in the IVF count field and use a 1 ms
        # timebase. Accept only a complete stream with a matching end timestamp.
        if not (meta['rate']==1000 and meta['scale']==1 and ended and step>0 and 0<=meta['declared_frames']-last<=step+2):raise UnsupportedVideo('Incomplete IVF stream')
        semantics='duration_ms'
    return dict(meta,frames=frames,last_timestamp=last,count_semantics=semantics)

def publish_completed(partial,output):
    """Never overwrite an existing file, including on exFAT volumes."""
    rename=ctypes.CDLL(None,use_errno=True).renamex_np
    rename.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];rename.restype=ctypes.c_int
    if not rename(os.fsencode(partial),os.fsencode(output),4):return # Darwin RENAME_EXCL
    code=ctypes.get_errno()
    if code not in (errno.ENOTSUP,errno.EOPNOTSUPP):raise OSError(code,os.strerror(code),str(output))
    # exFAT lacks exclusive rename/hard links. Reserve the final file with O_EXCL
    # and copy bounded blocks. Callers may load it only after convert() returns;
    # the completion JSON is written last. Existing files are never replaced.
    identity=None
    try:
        with output.open('xb') as dst,partial.open('rb') as src:
            st=os.fstat(dst.fileno());identity=(st.st_dev,st.st_ino)
            shutil.copyfileobj(src,dst,BLOCK);dst.flush();os.fsync(dst.fileno())
        partial.unlink()
    except BaseException:
        if identity is not None:
            try:
                st=output.stat()
                if (st.st_dev,st.st_ino)==identity:output.unlink()
            except FileNotFoundError:pass
        raise

def convert(source,output,ffmpeg='ffmpeg'):
    source=Path(source).resolve();output=Path(output).resolve()
    if source==output or output.exists():raise ValueError('Use a new output path, separate from the source')
    output.parent.mkdir(parents=True,exist_ok=True);partial=output.with_name(output.stem+'.partial.mp4');log=output.with_suffix('.conversion.log')
    if partial.exists() or log.exists():raise ValueError('A previous conversion already uses this output name')
    started=time.monotonic();meta=None
    try:
        with log.open('xb') as errors:
            args=[ffmpeg,'-v','error','-err_detect','explode','-threads','2','-f','ivf','-i','pipe:0','-map','0:v:0','-an','-c:v','h264_videotoolbox','-b:v','8M','-maxrate','12M','-bufsize','24M','-pix_fmt','yuv420p','-fps_mode','passthrough','-movflags','+faststart','-n',str(partial)]
            proc=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=errors)
            try:
                meta=copy_video(source,proc.stdin.write);proc.stdin.close()
                if proc.wait()!=0:raise UnsupportedVideo('Video conversion failed; inspect the local conversion log')
            except BaseException:
                if proc.poll() is None:proc.kill()
                proc.wait();raise
            finally:
                if proc.stdin and not proc.stdin.closed:
                    try:proc.stdin.close()
                    except BrokenPipeError:pass
        if not partial.is_file() or not partial.stat().st_size:raise UnsupportedVideo('No output video')
        # A completion receipt is written only after successful publication.
        publish_completed(partial,output)
        result=dict(meta,seconds=time.monotonic()-started,source_bytes=source.stat().st_size,output_bytes=output.stat().st_size,codec='h264')
        output.with_suffix('.conversion.json').write_text(json.dumps(result,indent=2));return result
    except BaseException:
        if partial.is_file():partial.unlink() # this invocation's incomplete candidate only
        raise
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('output',type=Path);p.add_argument('--ffmpeg',default='ffmpeg');a=p.parse_args()
    try:os.nice(10)
    except OSError:pass
    print(json.dumps(convert(a.source,a.output,a.ffmpeg),ensure_ascii=False))

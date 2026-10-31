"""Synthetic parser regression cases; no game assets or encoder required."""
import io,struct,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Tools/pc_mods'))
from usm_video import copy_video,UnsupportedVideo,publish_completed

def chunk(tag,data,kind=0,padding=0):
 h=bytearray(32);h[:4]=tag;struct.pack_into('>IHH',h,4,24+len(data)+padding,24,padding);h[15]=kind
 return bytes(h)+data+bytes(padding)

def ivf(count=2):return struct.pack('<4sHH4sHHIIII',b'DKIF',0,32,b'VP90',1280,720,30000,1001,count,0)
class Streams(unittest.TestCase):
 def check_parse(self,b):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'video.usm';p.write_bytes(b);out=io.BytesIO();r=copy_video(p,out.write);return r,out.getvalue()
 def test_exact_video_audio_and_padding(self):
  frame=lambda t:struct.pack('<IQ',3,t)+b'abc';h=ivf();raw=chunk(b'CRID',b'table',1)+chunk(b'@SFV',b'meta',1)+chunk(b'@SFV',h+frame(0),padding=17)+chunk(b'@SFA',b'audio')+chunk(b'@SFV',frame(1))
  result,data=self.check_parse(raw);self.assertEqual(result['frames'],2);self.assertEqual(data,h+frame(0)+frame(1))
 def test_truncated_header_and_frame(self):
  for raw in [b'CRID',chunk(b'CRID',b't',1)+chunk(b'@SFV',ivf()+struct.pack('<IQ',1024,0)+b'x')]:
   with self.assertRaises(UnsupportedVideo):self.check_parse(raw)
 def test_bad_bounds_and_count(self):
  for raw in [chunk(b'CRID',b't',1)+chunk(b'@SFV',ivf(5)+struct.pack('<IQ',1,0)+b'x'),b'CRID'+struct.pack('>I',0xffffffff)+bytes(24)]:
   with self.assertRaises(UnsupportedVideo):self.check_parse(raw)
 def test_masked_or_other_codec_rejected(self):
  raw=chunk(b'CRID',b't',1)+chunk(b'@SFV',bytes(32))
  with self.assertRaises(UnsupportedVideo):self.check_parse(raw)
 def test_millisecond_duration_header_requires_end_marker(self):
  h=struct.pack('<4sHH4sHHIIII',b'DKIF',0,32,b'VP90',1920,1080,1000,1,67,0)
  frames=struct.pack('<IQ',1,0)+b'a'+struct.pack('<IQ',1,33)+b'b'
  raw=chunk(b'CRID',b't',1)+chunk(b'@SFV',h+frames)
  with self.assertRaises(UnsupportedVideo):self.check_parse(raw)
  meta,data=self.check_parse(raw+chunk(b'@SFV',b'#CONTENTS END   ===============',2))
  self.assertEqual(meta['count_semantics'],'duration_ms');self.assertEqual(meta['frames'],2)
 def test_existing_output_is_preserved(self):
  with tempfile.TemporaryDirectory() as d:
   a,b=Path(d)/'partial',Path(d)/'output';a.write_bytes(b'new');b.write_bytes(b'keep')
   with self.assertRaises(FileExistsError):publish_completed(a,b)
   self.assertEqual(b.read_bytes(),b'keep');self.assertEqual(a.read_bytes(),b'new')
 def test_split_frame_rejected(self):
  raw=chunk(b'CRID',b't',1)+chunk(b'@SFV',ivf()+struct.pack('<IQ',4,0)+b'ab')+chunk(b'@SFV',b'cd')
  with self.assertRaises(UnsupportedVideo):self.check_parse(raw)
if __name__=='__main__':unittest.main()

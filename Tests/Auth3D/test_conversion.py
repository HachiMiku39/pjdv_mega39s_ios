import unittest,struct,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Tools/pc_mods'))
from a3dc_to_a3da import convert

def container(text,binary):
    text=text.encode();off=(64+len(text)+15)//16*16;b=bytearray(off+len(binary));b[:16]=b'#A3DC__________\n';struct.pack_into('>IHH',b,24,32,2,16)
    b[32:36]=b'P\0\0\0';struct.pack_into('>II',b,36,64,len(text));b[48:52]=b'BL\0\0';struct.pack_into('>II',b,52,off,len(binary));b[64:64+len(text)]=text;b[off:]=binary;return bytes(b)
def properties(b):return dict(line.split('=',1) for line in b.decode().splitlines() if '=' in line)
class AuthConversionTests(unittest.TestCase):
    def test_curve_and_unknown_properties(self):
        keys=[(0.,.1,-.5,2.),(30.,1.25,0.,0.)];binary=struct.pack('<IffI',3|(2<<8)|(3<<12),0,60,2)+b''.join(struct.pack('<4f',*v) for v in keys)
        raw=container('curve.0.cv.bin_offset=0\nplay_control.begin=0\nplay_control.fps=60\ncustom.unknown=retained\n',binary);before=raw[:];out,s=convert(raw);d=properties(out)
        self.assertEqual(d['custom.unknown'],'retained');self.assertEqual(d['curve.0.cv.ep_type_pre'],'2');self.assertEqual(s['keys'],2);self.assertEqual(raw,before)
        for i,v in enumerate(keys):
            got=tuple(map(float,d[f'curve.0.cv.key.{i}.data'].strip('()').split(',')))
            self.assertEqual(struct.pack('<4f',*got),struct.pack('<4f',*v))
    def test_all_transform_compression_modes(self):
        for compression,fmt in [(0,'<4f'),(1,'<heff'),(2,'<heee')]:
            binary=bytearray(40);ptr=[]
            for i in range(10):
                ptr.append(len(binary))
                if 3<=i<6:binary.extend(struct.pack('<IffI',3,0,60,1)+struct.pack(fmt,12,.5,-.25,.75))
                else:binary.extend(struct.pack('<If',1,float(i)))
            struct.pack_into('<10I',binary,0,*ptr);out,s=convert(container(f'_.compress_f16={compression}\nobject.0.model_transform.bin_offset=0\n',binary));d=properties(out)
            self.assertEqual(s['transforms'],1);self.assertEqual(s['keys'],3);self.assertEqual(d['object.0.rot.x.key.0.data'],'(12,0.5,-0.25,0.75)');self.assertEqual(d['object.0.trans.z.value'],'8')
    def test_raw_curve(self):
        tx='curve.0.cv.type=3\ncurve.0.cv.raw_data.value_list_offset=0\ncurve.0.cv.raw_data.value_list_size=8\ncurve.0.cv.raw_data.value_type=float\ncurve.0.cv.raw_data_key_type=3\n'
        out,s=convert(container(tx,struct.pack('<8f',0,0,1,1,20,30,1,1)));self.assertEqual(s['keys'],2);self.assertNotIn(b'value_list_offset',out)
    def test_bounds_and_nonfinite(self):
        for raw in [container('curve.0.cv.bin_offset=100\n',b'1234'),container('object.0.model_transform.bin_offset=0\n',b'1234'),container('curve.0.cv.bin_offset=0\n',struct.pack('<If',1,float('nan')))]:
            with self.assertRaises(ValueError):convert(raw)
    def test_text_is_unchanged(self):
        raw=b'#A3DA__________\nplay_control.begin=0\n';self.assertEqual(convert(raw)[0],raw)
if __name__=='__main__':unittest.main()

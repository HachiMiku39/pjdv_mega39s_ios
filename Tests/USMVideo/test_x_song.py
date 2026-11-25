"""Regression for X Song's 3D stages which additionally declare a video."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools/pc_mods'))
import x_song_stage_movies as stage_movies


class XSongStageMovies(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'input'
        (self.source / 'rom/movie').mkdir(parents=True)
        self.relative = Path('rom/movie/pvstg_802.mp4')
        self.mp4 = self.source / self.relative
        self.usm = self.mp4.with_suffix('.usm')
        self.pv = {'pv_802.movie_file_name': str(self.relative), 'pv_814.song_name': 'Calc.'}
        self.overlay = self.root / 'result/overlay'
        self.work = self.overlay.parent

    def test_declared_sibling_only(self):
        self.usm.write_bytes(b'fixture')
        self.assertEqual(stage_movies.stage_movie_inputs(self.source, self.pv), {self.usm: self.relative})
        self.assertEqual(stage_movies.stage_movie_inputs(self.source, {'pv_814.song_name': 'Calc.'}), {})
        for key, path in [('pv_814.movie_file_name', str(self.relative)),
                          ('pv_802.movie_file_name', 'rom/movie/../pvstg_802.mp4'),
                          ('pv_802.movie_file_name', 'rom/movie/pvstg_820.mp4')]:
            with self.assertRaises(ValueError):
                stage_movies.stage_movie_inputs(self.source, {key: path})
        self.usm.unlink()
        with self.assertRaises(ValueError):
            stage_movies.stage_movie_inputs(self.source, self.pv)

    def test_conversion_publishes_only_the_declared_file(self):
        self.usm.write_bytes(b'fixture')
        def encode(source, output):
            self.assertEqual(source, self.usm)
            output.write_bytes(b'encoded movie')
            output.with_suffix('.conversion.json').write_text('{}')
        with patch.object(stage_movies.usm_video, 'convert', side_effect=encode):
            result = stage_movies.install_stage_movie(self.usm, self.relative, self.overlay, self.work)
        self.assertEqual(result['path'], 'rom_switch/rom/movie/pvstg_802.mp4')
        self.assertEqual(result['sha256'], hashlib.sha256(b'encoded movie').hexdigest())
        self.assertEqual([f for f in self.overlay.rglob('*') if f.is_file()], [self.overlay / result['path']])
        self.assertEqual(result, stage_movies.install_stage_movie(self.usm, self.relative, self.overlay, self.work, tables_only=True))
        with self.assertRaises(FileExistsError):
            stage_movies.install_stage_movie(self.usm, self.relative, self.overlay, self.work)

    def test_existing_mp4_has_precedence(self):
        self.usm.write_bytes(b'original')
        self.mp4.write_bytes(b'\x00\x00\x00\x10ftypisom' + bytes(4))
        self.assertEqual(stage_movies.stage_movie_inputs(self.source, self.pv), {self.mp4: self.relative})
        with patch.object(stage_movies.usm_video, 'convert', side_effect=AssertionError('unexpected transcoding')):
            result = stage_movies.install_stage_movie(self.mp4, self.relative, self.overlay, self.work)
        self.assertEqual((self.overlay / result['path']).read_bytes(), self.mp4.read_bytes())
        self.mp4.write_bytes(b'CRID')
        with self.assertRaises(ValueError):
            stage_movies.stage_movie_inputs(self.source, self.pv)

    def test_failed_transcode_does_not_publish_a_movie(self):
        self.usm.write_bytes(b'corrupt')
        with patch.object(stage_movies.usm_video, 'convert', side_effect=ValueError('bad movie')):
            with self.assertRaises(ValueError):
                stage_movies.install_stage_movie(self.usm, self.relative, self.overlay, self.work)
        self.assertFalse((self.overlay / 'rom_switch' / self.relative).exists())


if __name__ == '__main__':
    unittest.main()

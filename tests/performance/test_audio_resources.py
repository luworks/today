"""Alarm, event and reminder tone contract: python3 -m unittest discover -s tests/performance -p test_audio_resources.py."""
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOUNDS = ROOT / 'ios/One/Sounds'
SWIFT = ROOT / 'ios/Sources/TodayPlatform/AlarmSounds.swift'
ALARMS = dict.fromkeys(('Daybreak', 'Chimes', 'Marimba', 'Glass', 'Ripple', 'Crystal', 'Harp', 'MusicBox'), 22050)
ALARMS.update(dict.fromkeys(('Beacon', 'MorningPiano', 'Sunrise', 'Vibes', 'SteelDrum', 'Birdsong', 'Classic', 'Pulse'), 16000))
SHORT = dict.fromkeys(('HeadsUp', 'Doorbell', 'Agenda', 'Bloom', 'Knock', 'Prelude', 'Signal', 'Arrival',
                       'Ping', 'Note', 'Tap', 'Pop', 'Drop', 'Glint', 'Nudge', 'Pluck'), 32000)
RATES = {**ALARMS, **SHORT}


def caf_chunks(path):
    data = path.read_bytes()
    if data[:8] != b'caff\x00\x01\x00\x00':
        raise ValueError('Unexpected CAF header')
    chunks = {}
    offset = 8
    while offset < len(data):
        kind, size = struct.unpack_from('>4sq', data, offset)
        if size < 0 or offset + 12 + size > len(data) or kind in chunks:
            raise ValueError('Invalid or duplicate CAF chunk')
        chunks[kind] = data[offset + 12:offset + 12 + size]
        offset += 12 + size
    if offset != len(data):
        raise ValueError('Trailing incomplete chunk')
    return chunks


class AudioResourcesTests(unittest.TestCase):
    def test_swift_choices_match_bundled_files(self):
        names = re.findall(r'"([A-Z][A-Za-z ]+)"', SWIFT.read_text())
        self.assertEqual({n.replace(' ', '') for n in names}, set(RATES))
        self.assertEqual(len({n.lower() for n in RATES}), len(RATES))

    def test_choices_duration_and_supported_encoding(self):
        self.assertEqual({p.stem for p in SOUNDS.glob('*.caf')}, set(RATES))
        for name, rate in RATES.items():
            with self.subTest(tone=name):
                chunks = caf_chunks(SOUNDS / (name + '.caf'))
                sr, codec, flags, packet_bytes, packet_frames, channels, bits = struct.unpack('>d4sIIIII', chunks[b'desc'])
                self.assertEqual((sr, codec, channels, packet_bytes, packet_frames), (rate, b'ima4', 1, 34, 64))
                packets, valid, priming, remainder = struct.unpack('>qqii', chunks[b'pakt'][:24])
                if name in ALARMS:
                    self.assertEqual(valid, rate * 28)
                else:
                    self.assertLessEqual(valid, rate * 3)
                # Core Audio writes zero packet count for this constant-packet codec.
                payload_packets, leftover = divmod(len(chunks[b'data']) - 4, packet_bytes)
                self.assertEqual(leftover, 0)
                self.assertIn(packets, (0, payload_packets))
                self.assertEqual(payload_packets * packet_frames, valid + priming + remainder)
                self.assertNotIn(b'free', chunks)

    def test_audio_size_budget_and_distinct_payloads(self):
        paths = list(SOUNDS.glob('*.caf'))
        self.assertLessEqual(sum(p.stat().st_size for p in paths), 5000000)
        self.assertEqual(len({caf_chunks(p)[b'data'] for p in paths}), len(RATES))

    @unittest.skipUnless(Path('/usr/bin/afconvert').exists(), 'Requires macOS Core Audio decoder')
    def test_core_audio_decodes_exact_duration_without_clipping(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name, rate in RATES.items():
                with self.subTest(tone=name):
                    output = Path(temporary) / (name + '.caf')
                    subprocess.run(['/usr/bin/afconvert', '-f', 'caff', '-d', 'LEI16', str(SOUNDS / (name + '.caf')), str(output)], check=True, capture_output=True)
                    chunks = caf_chunks(output)
                    sr, codec, _, _, _, channels, bits = struct.unpack('>d4sIIIII', chunks[b'desc'])
                    payload = chunks[b'data'][4:]
                    self.assertEqual((sr, codec, channels, bits), (rate, b'lpcm', 1, 16))
                    if name in ALARMS:
                        self.assertEqual(len(payload), 28 * rate * 2)
                    samples = struct.unpack('<' + 'h' * (len(payload) // 2), payload)
                    peak = max(abs(value) for value in samples)
                    self.assertGreater(peak, 15000)
                    self.assertLess(peak, 32767)


if __name__ == '__main__':
    unittest.main()

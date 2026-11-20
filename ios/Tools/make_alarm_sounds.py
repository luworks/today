#!/usr/bin/env python3
"""Synthesizes the app's alarm, event and reminder tones into ios/One/Sounds/*.caf (numpy + macOS afconvert).

AlarmKit cannot use Apple's ringtones, only sound files bundled with the app, so the tones are made here: soft, musical,
exactly 28 seconds long (below the 30-second custom alert limit) and getting a little louder as they go.
Synthesis stays at 44.1 kHz; afconvert low-pass resamples before IMA4 encoding.
See docs/performance/audio-candidate.md for format evidence and fidelity limits.
Alarm tones are 28 seconds; event and reminder tones are short notification sounds that start at once.
Run:  uv run --with numpy python3 ios/Tools/make_alarm_sounds.py [--only NAME ...]
"""
import argparse, os, subprocess, tempfile, wave
import numpy as np

SR = 44100
# Keep bright upper partials at 22.05 kHz. These two voices have no synthesized
# partial above 5 kHz, so 16 kHz preserves their musical band with more headroom.
OUTPUT_RATES = {"Beacon": 16000, "Morning Piano": 16000}
DEFAULT_OUTPUT_RATE = 22050
LENGTH = 28.0
OUT = os.path.join(os.path.dirname(__file__), "..", "One", "Sounds")

N = dict(G4=392.0, A4=440.0, B4=493.88, C5=523.25, D5=587.33, E5=659.25, F5=698.46, G5=783.99, A5=880.0, B5=987.77,
         C6=1046.5, D6=1174.66, E6=1318.5, G6=1568.0, E4=329.63, C4=261.63)


def tone(freq, dur, partials, amps, decays, attack=0.004, vibrato=0.0):
    t = np.arange(int(SR * dur)) / SR
    y = np.zeros_like(t)
    for p, a, d in zip(partials, amps, decays):
        f = freq * p
        if f >= SR / 2: continue
        ph = 2 * np.pi * f * t + (vibrato * np.sin(2 * np.pi * 5.2 * t) if vibrato else 0)
        y += a * np.sin(ph) * np.exp(-d * t)
    env = np.minimum(1, t / attack) * np.minimum(1, (dur - t) / 0.03)
    return y * env


def bell(f, dur=2.5):    return tone(f, dur, [1, 2.76, 5.4, 8.93], [1, .35, .18, .08], [1.6, 2.6, 4, 6])
def chime(f, dur=3.5):   return tone(f, dur, [1, 2.0, 3.01, 4.2], [1, .3, .12, .05], [1.0, 1.8, 2.6, 4])
def marimba(f, dur=1.0): return tone(f, dur, [1, 4.0, 9.9], [1, .35, .08], [5, 11, 22], attack=0.002)
def glass(f, dur=4.0):   return tone(f, dur, [1, 2.0, 3.0, 4.07], [1, .45, .2, .1], [0.9, 1.5, 2.2, 3], attack=0.02, vibrato=0.25)
def kalimba(f, dur=1.6): return tone(f, dur, [1, 5.4, 12.0], [1, .12, .03], [3.2, 9, 18], attack=0.002)
def piano(f, dur=2.5):   return tone(f, dur, [1, 2, 3, 4, 5, 6], [1, .5, .28, .16, .08, .04], [1.3, 1.8, 2.4, 3, 3.8, 4.6], attack=0.006)
def crystal(f, dur=1.5): return tone(f, dur, [1, 2.0, 3.0, 5.0], [1, .5, .25, .12], [3, 4.5, 6, 9], attack=0.002, vibrato=0.1)
def beep(f, dur=0.22):   return tone(f, dur, [1, 2], [1, .12], [0, 0], attack=0.012)


def place(buf, y, start):
    i = int(start * SR)
    if i >= len(buf): return
    j = min(len(buf), i + len(y))
    buf[i:j] += y[:j - i]


def cycle(notes, voice, length, gain=1.0):
    """notes: (start, freq name, optional gain) within one cycle; repeated to fill the tone."""
    buf = np.zeros(int(SR * LENGTH))
    t = 0.0
    while t < LENGTH:
        for item in notes:
            s, n = item[0], item[1]
            g = item[2] if len(item) > 2 else 1.0
            place(buf, voice(N[n]) * g * gain, t + s)
        t += length
    return buf


def reverb(y, seconds=0.9, mix=0.22):
    rng = np.random.default_rng(7)
    n = int(SR * seconds)
    ir = rng.standard_normal(n) * np.exp(-np.arange(n) / (SR * seconds / 5))
    ir[0] = 0
    ir /= np.abs(ir).sum() * 0.35
    wet = np.fft.irfft(np.fft.rfft(y, len(y) + n) * np.fft.rfft(ir, len(y) + n))[:len(y)]
    return (1 - mix) * y + mix * wet


def finish(y):
    y = reverb(y)
    t = np.arange(len(y)) / SR
    y *= 0.55 + 0.45 * np.minimum(1, t / 20.0)          # a little louder over the first 20 s
    y *= np.minimum(1, (LENGTH - t) / 0.4) * np.minimum(1, t / 0.02)
    y /= max(1e-9, np.abs(y).max()) / 0.85
    return y


TONES = {
    "Daybreak": lambda: cycle([(0, "C5"), (.5, "E5"), (1.0, "G5"), (1.5, "C6"), (2.2, "E6", .8), (3.4, "G5", .7), (3.9, "C6", .7),
                               (4.4, "E6", .7), (5.2, "D6", .6)], bell, 7.0),
    "Chimes": lambda: cycle([(0, "C6"), (.7, "A5"), (1.3, "G5"), (2.2, "E5"), (3.0, "D5"), (3.5, "G5", .8), (4.4, "C6", .8)], chime, 7.0, .9),
    "Marimba": lambda: cycle([(0, "C5"), (.25, "E5"), (.5, "G5"), (.75, "E5"), (1.0, "C5"), (1.25, "E5"), (1.5, "G5"), (1.75, "C6"),
                              (2.5, "D5"), (2.75, "F5"), (3.0, "A5"), (3.25, "F5"), (3.5, "D5"), (3.75, "F5"), (4.0, "A5"), (4.25, "D6")],
                             marimba, 5.5),
    "Glass": lambda: cycle([(0, "C6"), (1.4, "G5"), (2.8, "E6"), (4.4, "D6"), (5.8, "G5", .8)], glass, 8.0, .85),
    "Ripple": lambda: cycle([(0, "C5"), (.2, "D5"), (.4, "E5"), (.6, "G5"), (.8, "A5"), (1.0, "C6"), (1.4, "A5"), (1.6, "G5"), (1.8, "E5"),
                             (2.0, "D5"), (2.2, "C5")], kalimba, 4.2),
    "Morning Piano": lambda: cycle([(0, "G4"), (.6, "C5"), (1.2, "E5"), (1.8, "G5"), (3.0, "E5", .8), (3.6, "D5", .8), (4.2, "C5", .9),
                                    (5.4, "E5", .8), (6.0, "D5", .7), (6.6, "C5", .8)], piano, 9.0),
    "Beacon": lambda: cycle([(0, "A5"), (.3, "D6"), (1.2, "A5"), (1.5, "D6")], beep, 2.4, .8),
    "Crystal": lambda: cycle([(0, "E5"), (.15, "G5"), (.3, "B5"), (.45, "E6"), (.6, "G6", .8), (.75, "E6"), (.9, "B5"), (1.05, "G5")],
                             crystal, 2.4, .85),
}


N.update(C3=130.81, G3=196.0, A3=220.0, B3=246.94, D4=293.66, F4=349.23, A4s=466.16, F5s=739.99, F6=1396.91, A6=1760.0,
         B6=1975.53, C7=2093.0, D7=2349.32, E7=2637.02, B4b=466.16, E5b=622.25, B5b=932.33)


def fm(f, dur, ratio, index, idecay, decay, attack=0.002):
    t = np.arange(int(SR * dur)) / SR
    mod = index * np.exp(-idecay * t) * np.sin(2 * np.pi * f * ratio * t)
    y = np.sin(2 * np.pi * f * t + mod) * np.exp(-decay * t)
    return y * np.minimum(1, t / attack) * np.minimum(1, (dur - t) / 0.03)


def sweep(f0, f1, dur):
    t = np.arange(int(SR * dur)) / SR
    f = f0 * (f1 / f0) ** (t / dur)
    y = np.sin(2 * np.pi * np.cumsum(f) / SR)
    return y * np.sin(np.pi * np.minimum(1, t / dur)) ** 2


def harp(f, dur=2.4):
    n = np.arange(1, 11)
    return tone(f, dur, list(n), list(0.9 / n ** 1.4), list(1.2 + 0.9 * n), attack=0.0015)


def musicbox(f, dur=2.2): return tone(f, dur, [1, 4.2, 10.7], [1, .22, .06], [2.2, 6, 14], attack=0.001)
def steel(f, dur=1.6):    return tone(f, dur, [1, 2.0, 3.0, 4.02], [1, .55, .3, .12], [2.6, 3.4, 5, 7], attack=0.003)
def epiano(f, dur=2.4):   return fm(f, dur, 1.0, 1.6, 3.0, 1.4, attack=0.003) + 0.25 * fm(f * 2, dur, 7.0, 1.0, 9, 4)
def fmbell(f, dur=3.0):   return fm(f, dur, 3.5, 2.2, 1.6, 1.3, attack=0.004)
def wood(f, dur=0.25):    return tone(f, dur, [1, 2.71, 4.4], [1, .35, .12], [28, 40, 60], attack=0.0008)
def square(f, dur=0.1):   return tone(f, dur, [1, 2, 3], [1, .18, .22], [6, 8, 10], attack=0.008)


def vibes(f, dur=3.0):
    t = np.arange(int(SR * dur)) / SR
    return tone(f, dur, [1, 4.0, 10.0], [1, .2, .05], [0.9, 3, 8], attack=0.002) * (1 - 0.35 * (0.5 + 0.5 * np.sin(2 * np.pi * 5.5 * t)))


def pad(freqs, dur, attack=1.2):
    t = np.arange(int(SR * dur)) / SR
    y = np.zeros_like(t)
    for f in freqs:
        for k, a in zip((1, 2, 3, 4), (1, .35, .15, .06)):
            for d in (-0.6, 0.6):
                y += a * np.sin(2 * np.pi * (f * k + d) * t)
    env = np.minimum(1, t / attack) * np.minimum(1, np.maximum(0, dur - t) / 1.0)
    return y * env / (len(freqs) * 2)


def chirp_phrase(base, count, step=0.11):
    out = np.zeros(int(SR * (count * step + 0.2)))
    for i in range(count):
        f0 = base * (1.0 + 0.08 * (i % 3))
        place_into = sweep(f0, f0 * (1.45 if i % 2 == 0 else 0.8), 0.075)
        j = int(i * step * SR)
        out[j:j + len(place_into)] += place_into
    return out


def sequence(events, length):
    buf = np.zeros(int(SR * length))
    for start, y in events:
        place(buf, y, start)
    return buf


def loop(build_cycle, cycle_len):
    buf = np.zeros(int(SR * LENGTH))
    k, t = 0, 0.0
    while t < LENGTH:
        place(buf, build_cycle(k), t)
        k += 1
        t += cycle_len
    return buf


def sunrise():
    chords = [("C4", "E4", "G4", "B4"), ("A3", "C4", "E4", "G4"), ("F4", "A4", "C5", "E5"), ("G3", "B3", "D4", "G4")]
    sparkle = [("E6", "G5", "C6"), ("C6", "E5", "A5"), ("A5", "C6", "F5"), ("B5", "D6", "G5")]
    def cyc(k):
        i = k % 4
        y = pad([N[n] for n in chords[i]], 7.6, attack=0.5) * 0.9
        for j, n in enumerate(sparkle[i]):
            place(y, bell(N[n], 2.5) * 0.4, j * 1.9)
        return y
    return loop(cyc, 7.0)


HARP_CHORDS = [("C4", "E4", "G4", "B4", "C5", "E5", "G5", "B5"), ("A3", "C4", "E4", "G4", "A4", "C5", "E5", "G5"),
               ("F4", "A4", "C5", "E5", "F5", "A5", "C6", "E6"), ("G3", "B3", "D4", "G4", "B4", "D5", "G5", "B5")]


def harp_alarm():
    def cyc(k):
        notes = HARP_CHORDS[k % 4]
        order = notes + notes[-2:0:-1]
        return sequence([(i * 0.16, harp(N[n]) * (0.85 if i else 1.0)) for i, n in enumerate(order)], 3.6)
    return loop(cyc, 2.4)


def music_box():
    melody = [(0, "E6"), (.4, "G6"), (.8, "C7"), (1.2, "B6"), (1.6, "G6"), (2.0, "A6"), (2.4, "E6"), (3.2, "F6"), (3.6, "A6"),
              (4.0, "D7"), (4.4, "C7"), (4.8, "B6"), (5.2, "G6"), (6.0, "C7", .9)]
    bass = [(0, "C5"), (.8, "G5"), (1.6, "E5"), (2.4, "A4"), (3.2, "F5"), (4.0, "D5"), (4.8, "G4"), (5.6, "C5")]
    return cycle(melody, musicbox, 6.8) + cycle(bass, musicbox, 6.8, .45)


def steel_drum():
    riff = [(0, "C5"), (.25, "E5"), (.5, "G5"), (.75, "E5"), (1.0, "A5"), (1.375, "G5"), (1.75, "E5"), (2.0, "F5"), (2.25, "A5"),
            (2.5, "C6"), (2.75, "A5"), (3.0, "G5"), (3.375, "E5"), (3.75, "D5"), (4.0, "C5", .9)]
    return cycle(riff, steel, 5.0, .9)


def vibes_alarm():
    seq = [(0, "D5"), (.3, "F5s"), (.6, "A5"), (.9, "C6"), (1.6, "B5"), (2.4, "G5"), (2.7, "B5"), (3.0, "D6"), (3.6, "A5"),
           (4.4, "E5"), (4.7, "G5"), (5.0, "B5"), (5.3, "D6"), (6.0, "C6", .9)]
    return cycle(seq, vibes, 7.2, .9)


def birdsong():
    rng = np.random.default_rng(11)
    events = []
    t = 0.0
    while t < LENGTH:
        base = float(rng.choice([2900, 3300, 3700, 4100]))
        count = int(rng.integers(3, 7))
        events.append((t, chirp_phrase(base, count) * float(rng.uniform(.7, 1.0))))
        if rng.random() < 0.5:
            events.append((t + count * 0.11 + 0.15, sweep(base * 1.3, base * 0.7, 0.32) * .7))
        t += count * 0.11 + float(rng.uniform(0.6, 1.4))
    return sequence(events, LENGTH) * 0.8


def classic():
    def cyc(k):
        return sequence([(i * 0.14, square(2048.0)) for i in range(4)], 1.0)
    return loop(cyc, 1.0)


def pulse():
    notes = ["E6", "B5", "E6", "G6", "E6", "B5", "D6", "B5"]
    def cyc(k):
        events = []
        for i, n in enumerate(notes):
            events.append((i * 0.125, fm(N[n], 0.11, 2.0, 1.2, 20, 6, attack=0.008)))
        return sequence(events, 1.6)
    return loop(cyc, 1.6)


NEW_ALARMS = {
    "Sunrise": (sunrise, 16000, 0.24),
    "Harp": (harp_alarm, 22050, 0.22),
    "Music Box": (music_box, 22050, 0.22),
    "Steel Drum": (steel_drum, 16000, 0.18),
    "Vibes": (vibes_alarm, 16000, 0.24),
    "Birdsong": (birdsong, 16000, 0.15),
    "Classic": (classic, 16000, 0.06),
    "Pulse": (pulse, 16000, 0.10),
}


def short(events, length):
    return sequence([(s, y) for s, y in events], length)


EVENTS = {
    "Heads Up": lambda: short([(0, fmbell(N["G5"], 2.2)), (.22, fmbell(N["D6"], 2.0))], 2.4),
    "Doorbell": lambda: short([(0, vibes(N["E5"], 1.6)), (.45, vibes(N["C5"], 1.8))], 2.4),
    "Agenda": lambda: short([(0, marimba(N["C5"])), (.13, marimba(N["E5"])), (.26, marimba(N["G5"])), (.39, marimba(N["C6"]))], 1.6),
    "Bloom": lambda: short([(i * .07, glass(N[n], 2.2) * .7) for i, n in enumerate(["C5", "E5", "G5", "B5", "E6"])], 2.6),
    "Knock": lambda: short([(0, wood(820)), (.16, wood(820)), (.42, chime(N["A5"], 1.6) * .6)], 2.0),
    "Prelude": lambda: short([(i * .06, harp(N[n], 1.8) * .8) for i, n in enumerate(["C5", "E5", "G5", "C6", "E6", "G6"])], 2.2),
    "Signal": lambda: short([(0, fm(N["A5"], .16, 2.0, 1.0, 12, 3)), (.2, fm(N["A5"], .16, 2.0, 1.0, 12, 3)),
                             (.4, fm(N["E6"], .5, 2.0, 1.0, 8, 4))], 1.2),
    "Arrival": lambda: short([(0, epiano(N["C5"], 1.8) * .6), (0, epiano(N["E5"], 1.8) * .5), (.3, epiano(N["G5"], 1.8) * .6),
                              (.3, epiano(N["C6"], 1.8) * .5)], 2.4),
}

REMINDERS = {
    "Ping": lambda: short([(0, crystal(N["E6"], 1.2))], 1.2),
    "Note": lambda: short([(0, kalimba(N["G5"], 1.0)), (.14, kalimba(N["D5"], 1.0))], 1.2),
    "Tap": lambda: short([(0, wood(1100) * .8), (.05, crystal(N["C7"], 0.6) * .5)], 0.7),
    "Pop": lambda: short([(0, sweep(500, 1500, .07))], 0.3),
    "Drop": lambda: short([(0, sweep(1800, 700, .05)), (.05, sweep(700, 1400, .09))], 0.5),
    "Glint": lambda: short([(0, crystal(N["E6"], .8) * .8), (.07, crystal(N["G6"], .8) * .7), (.14, crystal(N["B6"], .9) * .7)], 1.1),
    "Nudge": lambda: short([(0, marimba(N["G4"])), (.16, marimba(N["G4"]) * .8)], 1.0),
    "Pluck": lambda: short([(0, harp(N["A5"], 1.2))], 1.2),
}
SHORT_RATE = 32000


def finish_alarm(y, mix):
    y = reverb(y, mix=mix)
    t = np.arange(len(y)) / SR
    y *= 0.55 + 0.45 * np.minimum(1, t / 20.0)
    y *= np.minimum(1, (LENGTH - t) / 0.4) * np.minimum(1, t / 0.02)
    return level(y, -14.5, 0.8)


def finish_short(y):
    y = reverb(y, seconds=0.6, mix=0.16)
    t = np.arange(len(y)) / SR
    y *= np.minimum(1, (len(y) / SR - t) / 0.06) * np.minimum(1, t / 0.002)
    return level(y, -14.0, 0.85)


def level(y, rms_db, peak):
    rms = np.sqrt(np.mean(y ** 2))
    return y * min(peak / max(1e-9, np.abs(y).max()), 10 ** (rms_db / 20) / max(1e-9, rms))


def write(y, name, rate, out_dir):
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes((y * 32767).astype(np.int16).tobytes())
        dest = os.path.join(out_dir, name.replace(" ", "") + ".caf")
        subprocess.run(["afconvert", "-f", "caff", "-d", f"ima4@{rate}",
                        "-r", "127", "--src-complexity", "bats", "--no-filler",
                        wav, dest], check=True)
    print("wrote", dest, f"{os.path.getsize(dest) / 1e3:.0f} KB")


def builds():
    for name, build in TONES.items():
        yield name, lambda b=build: finish(b()), OUTPUT_RATES.get(name, DEFAULT_OUTPUT_RATE)
    for name, (build, rate, mix) in NEW_ALARMS.items():
        yield name, lambda b=build, m=mix: finish_alarm(b(), m), rate
    for name, build in {**EVENTS, **REMINDERS}.items():
        yield name, lambda b=build: finish_short(b()), SHORT_RATE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default=OUT)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    os.makedirs(args.output_dir, exist_ok=True)
    for name, build, rate in builds():
        if args.only and name not in args.only:
            continue
        write(build(), name, rate, args.output_dir)


if __name__ == "__main__":
    main()

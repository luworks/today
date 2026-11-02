"""Render the app icon: a calendar-style tile with the weekday and day of month.

Usage: python3 scripts/make_icon.py [WEEKDAY] [DAY] [OUT]
Defaults to FRI 17 and writes ios/One/Assets.xcassets/AppIcon.appiconset/AppIcon.png.
Needs Pillow and the Inter Display font.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

S = 1024
TOP, BOTTOM = (44, 44, 46), (22, 22, 24)   # charcoal gradient
INK = (245, 245, 242)
ACCENT = (232, 116, 59)
FONTS = "/usr/share/fonts/opentype/inter/"


def font(weight, size):
    return ImageFont.truetype(f"{FONTS}InterDisplay-{weight}.otf", size)


def render(weekday="FRI", day="17"):
    im = Image.new("RGB", (S, S))
    px = im.load()
    for y in range(S):
        t = y / (S - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
        for x in range(S):
            px[x, y] = c
    d = ImageDraw.Draw(im)

    # Weekday, accent colour, letter-spaced, near the top (where Apple puts it).
    wf = font("SemiBold", 150)
    track = 14
    widths = [d.textlength(ch, font=wf) for ch in weekday]
    total = sum(widths) + track * (len(weekday) - 1)
    x = (S - total) / 2
    for ch, w in zip(weekday, widths):
        d.text((x, 240), ch, font=wf, fill=ACCENT, anchor="ls")
        x += w + track

    # Day number, big, optically centred in the space below; a small accent dot
    # after it keeps the "1." mark of the old icon.
    nf = font("Medium", 520)
    nw = d.textlength(day, font=nf)
    dot = 64
    gap = 22
    x0 = (S - (nw + gap + dot)) / 2
    base = 812
    d.text((x0, base), day, font=nf, fill=INK, anchor="ls")
    dx = x0 + nw + gap
    d.ellipse((dx, base - dot, dx + dot, base), fill=ACCENT)
    return im


if __name__ == "__main__":
    wd = sys.argv[1] if len(sys.argv) > 1 else "FRI"
    dy = sys.argv[2] if len(sys.argv) > 2 else "17"
    out = sys.argv[3] if len(sys.argv) > 3 else "ios/One/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    render(wd, dy).save(out, optimize=True)

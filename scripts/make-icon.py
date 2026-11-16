#!/usr/bin/env python3
"""Draws Packaging/AppIcon.png (1024×1024): a glass on an emerald squircle,
filled with a play symbol — "Windows games, poured onto your Mac"."""
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import pathlib

S = 4096
EMERALD_TOP, EMERALD_BOTTOM = (24, 168, 116), (5, 74, 56)

def gradient(top, bottom):
    g = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(g)
    for y in range(S):
        t = y / S
        d.line([(0, y), (S, y)], fill=tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3)) + (255,))
    return g

def mask(draw_fn):
    m = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    return m

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = mask(lambda d: d.rounded_rectangle([210, 300, S - 210, S - 130], radius=920, fill=120))
icon.paste((0, 0, 0, 255), (0, 0), shadow.filter(ImageFilter.GaussianBlur(70)))
bg = mask(lambda d: d.rounded_rectangle([200, 200, S - 200, S - 200], radius=920, fill=255))
icon.paste(gradient(EMERALD_TOP, EMERALD_BOTTOM), (0, 0), bg)

cx = S // 2
outer = [cx - 1050, 650, cx + 1050, 2950]   # ellipse box; we use its lower half
inner = [cx - 900, 800, cx + 900, 2800]
lower = lambda box: (lambda d: d.pieslice(box, 0, 180, fill=255))
ring = ImageChops.subtract(mask(lower(outer)), mask(lower(inner)))
rim = mask(lambda d: d.rounded_rectangle([cx - 1050, 1720, cx + 1050, 1880], radius=80, fill=255))
liquid = ImageChops.multiply(mask(lower(inner)), mask(lambda d: d.rectangle([0, 2000, S, S], fill=255)))
stem = mask(lambda d: (d.rectangle([cx - 85, 2900, cx + 85, 3330], fill=255),
                       d.rounded_rectangle([cx - 640, 3280, cx + 640, 3450], radius=85, fill=255)))
glass = ImageChops.lighter(ImageChops.lighter(ring, rim), stem)

white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
icon.paste(white, (0, 0), glass)
icon.paste((255, 255, 255, 235), (0, 0), liquid)
play = mask(lambda d: d.polygon([(cx - 210, 2120), (cx - 210, 2560), (cx + 300, 2340)], fill=255))
icon.paste(gradient(EMERALD_TOP, EMERALD_BOTTOM), (0, 0), play)

# Four window panes floating above the glass.
p, gap, top = 190, 46, 820
for col in (-1, 1):
    for row in (0, 1):
        x = cx - p - gap // 2 if col < 0 else cx + gap // 2
        y = top + row * (p + gap)
        icon.paste(white, (0, 0), mask(lambda d: d.rounded_rectangle([x, y, x + p, y + p], radius=36, fill=255)))

out = pathlib.Path(__file__).resolve().parent.parent / "Packaging" / "AppIcon.png"
icon.resize((1024, 1024), Image.LANCZOS).save(out)
print(f"wrote {out}")

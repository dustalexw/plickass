#!/usr/bin/env python3
"""Generates plickass's brand assets: the app icon, the README header and the README badges.

    python3 scripts/make_brand.py [--version 1.2.0]

Outputs
    AppIcon.icns                   app icon (all macOS sizes)
    docs/AppIcon-1024.png          app icon source
    docs/readme-header.png         2560x760 README header
    docs/badge-release.svg         RELEASE  | V1.2.0
    docs/badge-download.svg        DOWNLOAD | MACOS APP
    docs/badge-platform.svg        PLATFORM | MACOS 11+ · APPLE SILICON + INTEL

Layout and badge format follow the other dustalexw apps (Cover Flow, Data Curator, Banana Split Redux);
colours are this app's own: warm charcoal, cream and Plexamp amber.
Needs Pillow and the Inter / Inter Display fonts.
"""
import argparse
import math
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_DIRS = ["/usr/share/fonts/opentype/inter", os.path.expanduser("~/Library/Fonts"), "/Library/Fonts"]

COAL_TOP = (38, 30, 23)       # #261E17
COAL_BOT = (16, 12, 9)        # #100C09
CREAM = (250, 244, 228)       # #FAF4E4 (shared with the other apps)
AMBER = (245, 176, 60)        # #F5B03C (the app's accent)
AMBER_DEEP = (214, 128, 34)   # #D68022
TAUPE = (179, 168, 150)       # #B3A896
MINT = (126, 214, 184)        # #7ED6B8
VINYL = (22, 18, 16)
LABEL = "#20222c"             # badge label background, shared with the other apps


def font(name, size):
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    raise SystemExit(f"Font not found: {name}")


def vgrad(w, h, top, bot):
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)))
    return g.resize((w, h))


def record(img, cx, cy, r):
    """A vinyl record: grooves, a warm sheen and an amber label."""
    W, H = img.size
    disc = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(disc)
    box = lambda rr: [cx - rr, cy - rr, cx + rr, cy + rr]
    d.ellipse(box(r), fill=VINYL + (255,))
    for i in range(16):
        rr = r * (0.94 - i * 0.032)
        d.ellipse(box(rr), outline=(235, 215, 190, 40 if i % 3 == 0 else 18), width=max(1, int(r * 0.008)))
    sheen = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    for base in (-70, 110):
        sd.pieslice(box(r * 0.95), base, base + 26, fill=AMBER + (60,))
    sheen = sheen.filter(ImageFilter.GaussianBlur(max(1, r * 0.04)))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse(box(r * 0.95), fill=255)
    ImageDraw.Draw(mask).ellipse(box(r * 0.40), fill=0)
    disc.alpha_composite(Image.composite(sheen, Image.new("RGBA", (W, H), (0, 0, 0, 0)), mask))
    d = ImageDraw.Draw(disc)
    d.ellipse(box(r * 0.36), fill=AMBER + (255,))
    d.ellipse(box(r * 0.36), outline=AMBER_DEEP + (255,), width=max(1, int(r * 0.02)))
    d.ellipse(box(r * 0.07), fill=VINYL + (255,))
    img.alpha_composite(disc)


def mark(img, cx, cy, s):
    """The mark: a record sliding into an amber folder, with a cream down-arrow on the folder."""
    W, H = img.size
    d = ImageDraw.Draw(img)
    fw, fh = s, s * 0.70
    x0, y0 = cx - fw / 2, cy - fh / 2 + s * 0.12
    # folder back with tab
    d.rounded_rectangle([x0, y0 - s * 0.08, x0 + fw * 0.42, y0 + s * 0.1], radius=s * 0.05, fill=AMBER_DEEP)
    d.rounded_rectangle([x0, y0, x0 + fw, y0 + fh], radius=s * 0.07, fill=AMBER_DEEP)
    # the record, half in the folder
    record(img, cx, y0 + s * 0.02, s * 0.36)
    # folder front, with a soft shadow on its top edge
    front = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    fd = ImageDraw.Draw(front)
    top = y0 + fh * 0.30
    fd.rounded_rectangle([x0, top - s * 0.02, x0 + fw, y0 + fh], radius=s * 0.07, fill=(0, 0, 0, 90))
    img.alpha_composite(front.filter(ImageFilter.GaussianBlur(s * 0.025)))
    grad = vgrad(int(fw), int(y0 + fh - top), (252, 196, 92), AMBER)
    m = Image.new("L", grad.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, grad.size[0] - 1, grad.size[1] - 1], radius=s * 0.07, fill=255)
    img.paste(grad, (int(x0), int(top)), m)
    d = ImageDraw.Draw(img)
    # down arrow
    ax, ay = cx, top + (y0 + fh - top) * 0.50
    sw = s * 0.075
    d.rounded_rectangle([ax - sw / 2, ay - s * 0.16, ax + sw / 2, ay + s * 0.06], radius=sw / 2, fill=CREAM)
    d.polygon([(ax - s * 0.13, ay + s * 0.0), (ax + s * 0.13, ay + s * 0.0), (ax, ay + s * 0.15)], fill=CREAM)


def tile_art(W, edge=True):
    tile = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, W - 1], radius=int(W * 0.225), fill=255)
    tile.paste(vgrad(W, W, COAL_TOP, COAL_BOT).convert("RGBA"), (0, 0), mask)
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W * 0.15, W * 0.05, W * 0.85, W * 0.75], fill=AMBER + (34,))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.08))
    tile.alpha_composite(Image.composite(glow, Image.new("RGBA", (W, W), (0, 0, 0, 0)), mask))
    mark(tile, W / 2, W / 2 - W * 0.02, W * 0.56)
    if edge:
        ImageDraw.Draw(tile).rounded_rectangle([0, 0, W - 1, W - 1], radius=int(W * 0.225),
                                               outline=(255, 255, 255, 34), width=max(2, W // 200))
    return tile


def icon_tile(size, ss=4):
    """The app icon artwork without the macOS margin, for placing on banners."""
    return tile_art(size * ss).resize((size, size), Image.LANCZOS)


def app_icon(S=1024, ss=4):
    W = S * ss
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    m = 100 * ss
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([m, m + 14 * ss, W - m, W - m + 14 * ss], radius=185 * ss, fill=(0, 0, 0, 110))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(18 * ss)))
    img.alpha_composite(tile_art(W - 2 * m, edge=False), (m, m))
    return img.resize((S, S), Image.LANCZOS)


def pill(draw, x, y, text, fnt, h, fill, outline, color, dot=None, pad=None):
    pad = pad or h * 0.55
    tw = draw.textlength(text, font=fnt)
    dot_w = h * 0.55 if dot else 0
    w = pad * 2 + tw + dot_w
    draw.rounded_rectangle([x, y, x + w, y + h], radius=h / 2, fill=fill, outline=outline, width=2)
    tx = x + pad
    if dot:
        r = h * 0.14
        cy = y + h / 2
        draw.ellipse([tx, cy - r, tx + 2 * r, cy + r], fill=dot)
        tx += dot_w
    asc, desc = fnt.getmetrics()
    draw.text((tx, y + (h - asc - desc) / 2 + desc * 0.15), text, font=fnt, fill=color)
    return w


def header(path, version, W=2560, H=760):
    img = vgrad(W, H, COAL_TOP, COAL_BOT).convert("RGBA")
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W * 0.18, -H * 0.5, W * 0.78, H * 0.9], fill=AMBER + (18,))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(160)))
    # right edge: a row of anonymous download files turning into named tracks, fading in from the left
    ss = 2
    deco = Image.new("RGBA", (W * ss, H * ss), (0, 0, 0, 0))
    dd = ImageDraw.Draw(deco)
    for row in range(5):
        y = (196 + row * 92) * ss
        named = row % 2 == 1
        x = 2080 * ss
        col = AMBER + (150,) if named else (255, 255, 255, 30)
        dd.rounded_rectangle([x, y, x + 400 * ss, y + 58 * ss], radius=14 * ss, fill=col if named else None,
                             outline=None if named else (255, 255, 255, 60), width=2 * ss)
        txt = ["a3f9e1c0-77b2", "01 - Venus.m4a", "5d02c8aa-19fe", "02 - Run.m4a", "e81b4f37-c6d1"][row]
        f = font("Inter-SemiBold.otf" if named else "Inter-Regular.otf", 26 * ss)
        dd.text((x + 24 * ss, y + 14 * ss), txt, font=f, fill=COAL_BOT + (255,) if named else (255, 255, 255, 90))
    fade = Image.new("L", (W * ss, 1))
    for x in range(W * ss):
        fade.putpixel((x, 0), int(255 * min(1, max(0, (x - 2060 * ss) / (260 * ss)))))
    deco.putalpha(Image.composite(deco.getchannel("A"), Image.new("L", deco.size, 0), fade.resize(deco.size)))
    img = Image.alpha_composite(img, deco.resize((W, H), Image.LANCZOS))
    # app icon tile
    tile = icon_tile(400)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([110, 200, 510, 600], radius=90, fill=(0, 0, 0, 150))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(28)))
    img.alpha_composite(tile, (110, 180))
    d = ImageDraw.Draw(img)
    x = 620
    d.text((x, 196), "PLEXAMP DOWNLOADS, UNTANGLED", font=font("Inter-Bold.otf", 30), fill=MINT)
    title = font("InterDisplay-Bold.otf", 150)
    d.text((x - 6, 240), "plick", font=title, fill=CREAM)
    d.text((x - 6 + d.textlength("plick", font=title), 240), "ass", font=title, fill=AMBER)
    d.text((x, 432), "Your offline music, with real names.", font=font("Inter-Medium.otf", 46), fill=CREAM)
    d.text((x, 496), "Artist / Album / 01 - Track — copied anywhere you like.", font=font("Inter-Regular.otf", 34), fill=TAUPE)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    chip = font("Inter-Medium.otf", 30)
    cx = x
    for label, dot in (("Finds Plexamp automatically", AMBER), ("Never overwrites", CREAM), ("Live progress", MINT)):
        cx += pill(ld, cx, 578, label, chip, 62, (255, 255, 255, 10), (255, 255, 255, 38), CREAM, dot=dot) + 22
    small = font("Inter-SemiBold.otf", 28)
    vx = W - 120 - (d.textlength(f"v{version}", font=small) + 56)
    pill(ld, vx, 70, f"v{version}", small, 58, AMBER + (40,), AMBER + (110,), AMBER)
    mw = d.textlength("Only on macOS", font=small) + 56 + 32
    pill(ld, vx - 24 - mw, 70, "Only on macOS", small, 58, (16, 12, 9, 200), (255, 255, 255, 40), CREAM, dot=CREAM)
    img = Image.alpha_composite(img, layer)
    img.convert("RGB").save(path, optimize=True)


def badge(path, label, value, fill, text):
    """Same construction as the other apps' badges: 34px, Arial bold 11, tracked uppercase."""
    label, value = label.upper(), value.upper()
    lw = round(len(label) * 8.2 + 24)
    vw = round(len(value) * 8.2 + 26)
    w = lw + vw
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="34" viewBox="0 0 {w} 34" role="img" aria-label="{label}: {value}">
  <title>{label}: {value}</title>
  <rect width="{lw}" height="34" fill="{LABEL}"/>
  <rect x="{lw}" width="{vw}" height="34" fill="{fill}"/>
  <g font-family="Arial" font-size="11" font-weight="bold" letter-spacing="1.2" text-anchor="middle">
    <text x="{lw / 2:.1f}" y="21" fill="#faf4e4">{label}</text>
    <text x="{lw + vw / 2:.1f}" y="21" fill="{text}">{value}</text>
  </g>
</svg>
'''
    with open(path, "w") as f:
        f.write(svg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=open(os.path.join(ROOT, "VERSION")).read().strip())
    v = ap.parse_args().version
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    icon = app_icon()
    icon.save(os.path.join(ROOT, "docs/AppIcon-1024.png"))
    icon.save(os.path.join(ROOT, "AppIcon.icns"), sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    header(os.path.join(ROOT, "docs/readme-header.png"), v)
    badge(os.path.join(ROOT, "docs/badge-release.svg"), "Release", f"v{v}", "#f5b03c", "#20222c")
    badge(os.path.join(ROOT, "docs/badge-download.svg"), "Download", "macOS app", "#faf4e4", "#261e17")
    badge(os.path.join(ROOT, "docs/badge-platform.svg"), "Platform", "macOS 11+ · Apple silicon + Intel", "#261e17", "#faf4e4")
    print("Wrote icon, header and badges for", v)


if __name__ == "__main__":
    main()

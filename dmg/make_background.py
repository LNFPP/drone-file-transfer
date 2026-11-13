# Regenerates background.png / background@2x.png for the .dmg window (needs Pillow).
from PIL import Image, ImageDraw, ImageFont
import glob

def font(bold, size):
    for pat in (["/Library/Fonts/Arial Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"] if bold
                else ["/Library/Fonts/Arial.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"]):
        for f in glob.glob(pat):
            return ImageFont.truetype(f, size)
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    return ImageFont.truetype(glob.glob(f"/usr/share/fonts/**/{name}", recursive=True)[0], size)

def make(s, out):
    W, H = 640 * s, 400 * s
    im = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    top, bot = (246, 242, 255), (226, 216, 250)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    c = (124, 58, 237)
    y = 165 * s  # same height as the icons in settings.py
    d.rounded_rectangle((262 * s, y - 6 * s, 362 * s, y + 6 * s), radius=6 * s, fill=c)
    d.polygon([(358 * s, y - 22 * s), (390 * s, y), (358 * s, y + 22 * s)], fill=c)
    def ctext(txt, yy, f, col):
        w = d.textlength(txt, font=f)
        d.text(((W - w) / 2, yy), txt, font=f, fill=col)
    ctext("Drag Drone File Transfer into Applications", 300 * s, font(True, 17 * s), (60, 30, 110))
    ctext("First time opening it: System Settings → Privacy & Security → Open Anyway",
          330 * s, font(False, 12 * s), (105, 90, 140))
    im.save(out)

make(1, "background.png")
make(2, "background@2x.png")

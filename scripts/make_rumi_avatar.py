#!/usr/bin/env python3
"""Generate deploy/element/assets/rumi-avatar-navy.png: the white World-of-Rumi
mark (two dots + smile curve) on a navy disc, with a thin light (paper) ring
around the disc edge.

Why the ring: the plain navy-disc-plus-white-mark avatar (commit 84b6b2e) reads
fine on Element's white/light surfaces, but Matrix/Element night mode uses a
background close to navy itself -- the disc edge disappears and the white mark
looks like it's floating with no boundary. A thin CREAM ring just inside the
edge keeps the disc visible in both themes without changing the mark itself.

Self-contained (no import from ~/.claude/skills) so a fresh install can
regenerate this asset without that path existing -- same PIL-vector approach
(navy dots + curve) as .claude/skills/rumi-logo-mark-emoji/scripts/logo_mark_pack.py,
just recolored + given a disc/ring background instead of transparent.

    python3 scripts/make_rumi_avatar.py --out deploy/element/assets/rumi-avatar-navy.png
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw

NAVY, WHITE, CREAM = "#0B2545", "#FFFFFF", "#F3F1EC"
SS, SIZE = 4, 512
M = 330                                  # mark width in a 512 canvas
OX, OY = (SIZE - M) / 2, 190             # mark origin (eye row at y = OY + EY*M)
R, EY, EXL, EXR, STROKE, BOTTOM = 0.095, 0.103, 0.10, 0.90, 0.023, 0.372   # logo-measured (logo_mark_pack.py)
RING_PX = 6                              # ring width at final 512px export


def P(x, y):
    return ((OX + x * M) * SS, (OY + y * M) * SS)


def stroke(d, pts, w, fill):
    d.line(pts, fill=fill, width=int(w), joint="curve")
    for x, y in (pts[0], pts[-1]):
        d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=fill)


def dot(d, cx, cy, r, fill):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill)


def logo_curve(d, fill):
    x0, x1, ay = 0.145, 0.855, 0.195
    k = (BOTTOM - ay) / ((x1 - x0) / 2) ** 2
    pts = [P(x0 + (x1 - x0) * i / 48, BOTTOM - k * ((x0 + (x1 - x0) * i / 48) - 0.5) ** 2) for i in range(49)]
    stroke(d, pts, STROKE * M * SS, fill)


def eyes(d, fill):
    for x in (EXL, EXR):
        cx, cy = P(x, EY)
        dot(d, cx, cy, R * M * SS, fill)


def render():
    im = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((0, 0, SIZE * SS, SIZE * SS), fill=NAVY)
    ring_w = RING_PX * SS
    d.ellipse((ring_w / 2, ring_w / 2, SIZE * SS - ring_w / 2, SIZE * SS - ring_w / 2), outline=CREAM, width=int(ring_w))
    logo_curve(d, WHITE)
    eyes(d, WHITE)
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    im = render()
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    im.save(a.out)
    print(f"-> {a.out} {im.size} {im.mode}")


if __name__ == "__main__":
    main()

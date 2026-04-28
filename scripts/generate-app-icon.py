#!/usr/bin/env -S uv run --with pillow --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""
Renders the 1024x1024 App Store icon for ProxyCat.

Concept: a stylized cat face with a third eye in the forehead. The third
eye references mihomo's namesake (the three-eyed mythological beast in
Chinese folklore the project is named after); the cat references the
"Cat" in ProxyCat. Pure shapes — no fonts, no external assets.

Run it from the repo root:

    ./scripts/generate-app-icon.py

Output: Pcat/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "Pcat" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        int(a[0] * (1 - t) + b[0] * t),
        int(a[1] * (1 - t) + b[1] * t),
        int(a[2] * (1 - t) + b[2] * t),
    )


def render() -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), "white")
    draw = ImageDraw.Draw(img)

    # Vertical gradient: deep indigo at top, vivid magenta at bottom.
    # iOS auto-rounds the corners so we paint full-bleed.
    top = (49, 46, 129)        # indigo-900
    bottom = (190, 24, 93)     # pink-700
    for y in range(SIZE):
        t = y / (SIZE - 1)
        draw.line([(0, y), (SIZE, y)], fill=lerp(top, bottom, t))

    cx = SIZE // 2
    cy = SIZE // 2 + 50

    cream = (255, 250, 240)
    inner_ear = (244, 114, 182)   # pink-400
    eye = (15, 23, 42)            # slate-900
    third = (34, 211, 238)        # cyan-400

    # Outer ears: filled triangles. Bases overlap the face top so the
    # join reads as one silhouette.
    left_ear = [(cx - 290, cy - 80), (cx - 175, cy - 380), (cx - 60, cy - 190)]
    right_ear = [(cx + 60, cy - 190), (cx + 175, cy - 380), (cx + 290, cy - 80)]
    draw.polygon(left_ear, fill=cream)
    draw.polygon(right_ear, fill=cream)

    # Inner ears: smaller pink triangles offset inward.
    left_inner = [(cx - 235, cy - 115), (cx - 175, cy - 320), (cx - 115, cy - 195)]
    right_inner = [(cx + 115, cy - 195), (cx + 175, cy - 320), (cx + 235, cy - 115)]
    draw.polygon(left_inner, fill=inner_ear)
    draw.polygon(right_inner, fill=inner_ear)

    # Face: squircle (rounded rectangle).
    face_w, face_h = 600, 480
    draw.rounded_rectangle(
        [(cx - face_w // 2, cy - face_h // 2), (cx + face_w // 2, cy + face_h // 2)],
        radius=220,
        fill=cream,
    )

    # Two regular eyes — almond shape, slight tilt suggested via aspect ratio.
    eye_dx, eye_dy = 145, -5
    eye_w, eye_h = 46, 70
    for sign in (-1, 1):
        ex = cx + sign * eye_dx
        ey = cy + eye_dy
        draw.ellipse([(ex - eye_w, ey - eye_h), (ex + eye_w, ey + eye_h)], fill=eye)

    # Third eye: cyan iris in the forehead, slightly larger than the
    # other eyes so it reads even at small sizes. Dark pupil + cream
    # highlight gives it dimension.
    third_x, third_y = cx, cy - 130
    iw, ih = 50, 72
    draw.ellipse([(third_x - iw, third_y - ih), (third_x + iw, third_y + ih)], fill=third)
    draw.ellipse([(third_x - 18, third_y - 30), (third_x + 18, third_y + 30)], fill=eye)
    draw.ellipse([(third_x - 14, third_y - 32), (third_x + 2, third_y - 14)], fill=cream)

    # Nose: small downward triangle, same pink as inner ears.
    nose = [(cx - 32, cy + 90), (cx + 32, cy + 90), (cx, cy + 130)]
    draw.polygon(nose, fill=inner_ear)

    # Soft drop shadow on the cat: render the silhouette mask, blur, and
    # composite under the face. Skipping for now — adds runtime and
    # rarely shows under iOS's icon mask.

    return img


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img = render()
    img.save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT.relative_to(Path.cwd())} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()

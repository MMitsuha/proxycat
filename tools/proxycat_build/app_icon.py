"""Render the 1024x1024 App Store icon with Pillow.

Concept: a clean, line-based cat mark with a proxy route running through
it. Pure Pillow drawing; no fonts or external assets.
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterable

from .config import ROOT, BuildError

SIZE = 1024
SCALE = 4
CANVAS = SIZE * SCALE
OUT = ROOT / "Pcat" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"

BACKGROUND = (247, 250, 252)
INK = (17, 30, 48)
BLUE = (0, 122, 255)
MIST = (216, 228, 238)
WHITE = (255, 255, 255)

Point = tuple[float, float]
Color = tuple[int, int, int]


def _pillow():
    try:
        from PIL import Image, ImageDraw
    except ImportError as error:  # pragma: no cover - exercised on demand
        raise BuildError(
            "Pillow is required for app-icon\n"
            "  run: uv run --with pillow build.py app-icon\n"
            "  or:  python3 -m pip install pillow"
        ) from error
    return Image, ImageDraw


def scale(value: float) -> int:
    return round(value * SCALE)


def scaled_point(point: Point) -> tuple[int, int]:
    return (scale(point[0]), scale(point[1]))


def scaled_box(cx: float, cy: float, radius: float) -> tuple[int, int, int, int]:
    return (
        scale(cx - radius),
        scale(cy - radius),
        scale(cx + radius),
        scale(cy + radius),
    )


def cubic(p0: Point, p1: Point, p2: Point, p3: Point, steps: int = 32) -> list[Point]:
    points: list[Point] = []
    for index in range(steps + 1):
        t = index / steps
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        points.append((x, y))
    return points


def merge_segments(segments: Iterable[list[Point]]) -> list[Point]:
    points: list[Point] = []
    for segment in segments:
        if not segment:
            continue
        if points and points[-1] == segment[0]:
            points.extend(segment[1:])
        else:
            points.extend(segment)
    return points


def stroke(draw, points: list[Point], color: Color, width: int, *, caps: bool = True) -> None:
    scaled = [scaled_point(point) for point in points]
    draw.line(scaled, fill=color, width=scale(width), joint="curve")
    if caps and scaled:
        radius = width / 2
        for x, y in (points[0], points[-1]):
            draw.ellipse(scaled_box(x, y, radius), fill=color)


def dot(
    draw,
    center: Point,
    radius: int,
    fill: Color,
    *,
    outline: Color | None = None,
    outline_width: int = 0,
) -> None:
    cx, cy = center
    draw.ellipse(scaled_box(cx, cy, radius), fill=fill)
    if outline and outline_width:
        draw.ellipse(
            scaled_box(cx, cy, radius), outline=outline, width=scale(outline_width)
        )


def render():
    Image, ImageDraw = _pillow()
    img = Image.new("RGB", (CANVAS, CANVAS), BACKGROUND)
    draw = ImageDraw.Draw(img)

    # A faint route line gives the proxy motif room to breathe behind the mark.
    guide = merge_segments(
        [
            cubic((176, 676), (292, 618), (356, 608), (456, 646), 28),
            cubic((456, 646), (506, 665), (564, 665), (618, 646), 24),
            cubic((618, 646), (720, 608), (782, 618), (848, 676), 28),
        ]
    )
    stroke(draw, guide, MIST, 18)

    # The cat outline is intentionally open and geometric: ears, cheeks, and chin
    # stay readable at small iOS home-screen sizes without a filled mascot shape.
    cat_outline = merge_segments(
        [
            cubic((272, 575), (250, 480), (296, 397), (386, 357), 30),
            [(386, 357), (430, 235), (493, 350)],
            cubic((493, 350), (506, 346), (518, 346), (531, 350), 10),
            [(531, 350), (594, 235), (638, 357)],
            cubic((638, 357), (728, 397), (774, 480), (752, 575), 30),
            cubic((752, 575), (732, 711), (628, 787), (512, 787), 36),
            cubic((512, 787), (396, 787), (292, 711), (272, 575), 36),
        ]
    )
    stroke(draw, cat_outline, INK, 38, caps=False)

    # Proxy route: a single clean path entering and leaving the cat mark.
    route = merge_segments(
        [
            cubic((248, 602), (350, 558), (426, 560), (512, 596), 30),
            cubic((512, 596), (598, 560), (674, 558), (776, 602), 30),
        ]
    )
    stroke(draw, route, BLUE, 24)

    # Minimal face details: short line eyes and a route node doubling as the nose.
    stroke(draw, [(420, 492), (420, 545)], INK, 30)
    stroke(draw, [(604, 492), (604, 545)], INK, 30)

    for endpoint in ((248, 602), (776, 602)):
        dot(draw, endpoint, 35, WHITE, outline=BLUE, outline_width=18)
    dot(draw, (512, 596), 37, BLUE)
    dot(draw, (512, 596), 14, WHITE)

    # Two small status nodes suggest selectable proxy hops without crowding the icon.
    stroke(draw, [(512, 596), (512, 708)], BLUE, 18)
    dot(draw, (512, 708), 29, WHITE, outline=BLUE, outline_width=14)

    return img.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def write(output: Path = OUT) -> Path:
    img = render()
    output.parent.mkdir(parents=True, exist_ok=True)
    img.save(output, "PNG", optimize=True)
    try:
        display: Path | str = output.relative_to(ROOT)
    except ValueError:
        display = output
    print(f"wrote {display} ({SIZE}x{SIZE})", flush=True)
    return output

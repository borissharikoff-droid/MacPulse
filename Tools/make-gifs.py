#!/usr/bin/env python3
"""Turn --film-probe frames into the README's animations.

The probe emits one PNG per real state of the real view tree. This adds the
only three things a still cannot carry, all of them cosmetic:

  * a backdrop, because the renders are transparent and GIF's one-bit alpha
    would fringe every rounded corner;
  * a common crop, taken from the union of every frame's alpha box, so the
    island does not jump between states;
  * a cross-fade between consecutive states, so a cut reads as a transition
    rather than a glitch.

Nothing here invents a state. Each held frame is exactly what the app draws.

    python3 Tools/make-gifs.py FRAMES_DIR OUT_DIR
"""
import subprocess, sys, shutil
from pathlib import Path
from PIL import Image

BACKDROP = (14, 14, 17)      # matches docs/banner.svg
FPS      = 10
PAD      = 26                # px, around the union box
WIDTH    = 760               # final width; height follows

FILMS = {
    # name:     (glob,        seconds to hold each state, fade seconds)
    "open":     ("open-*.png",  1.4, 0.35),
    "sections": ("tab-*.png",   1.15, 0.3),
    "windows":  ("win-*.png",   1.6, 0.35),
}

# NEVER PUBLISHED, and this is not a style choice.
#
# The Tunnel section draws the machine's real public IP address, the city it
# exits in, and which VPN clients are installed and which one is carrying
# traffic. That frame was rendered, looked at, and thrown away: a public IP
# plus an exit node plus a provider, committed to a public repository, is
# permanent and is nobody else's business. A README animation is not worth it.
#
# If the section ever needs to be shown, render it on a machine with no
# tunnel, or give the probe a synthetic reading the way it already does for
# the window list.
EXCLUDE = ("tunnel",)


def load(paths):
    return [Image.open(p).convert("RGBA") for p in paths]


def union_box(images):
    box = None
    for im in images:
        b = im.getbbox()            # alpha bounding box
        if b is None:
            continue
        box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]),
                                     max(box[2], b[2]), max(box[3], b[3]))
    return box


def flatten(im, box):
    im = im.crop(box)
    bg = Image.new("RGBA", im.size, BACKDROP + (255,))
    bg.alpha_composite(im)
    return bg.convert("RGB")


def build(name, frames_dir: Path, out_dir: Path, pattern, hold_s, fade_s):
    paths = [p for p in sorted(frames_dir.glob(pattern))
             if not any(bad in p.stem for bad in EXCLUDE)]
    dropped = [p.stem for p in sorted(frames_dir.glob(pattern))
               if any(bad in p.stem for bad in EXCLUDE)]
    for d in dropped:
        print(f"  {name}: dropped {d} — see EXCLUDE")
    if not paths:
        print(f"  {name}: no frames matching {pattern} — skipped")
        return
    images = load(paths)
    box = union_box(images)
    if box is None:
        print(f"  {name}: every frame is empty — skipped")
        return
    box = (max(box[0] - PAD, 0), max(box[1] - PAD, 0),
           min(box[2] + PAD, images[0].width), min(box[3] + PAD, images[0].height))
    states = [flatten(im, box) for im in images]

    scale = WIDTH / states[0].width
    size = (WIDTH, int(round(states[0].height * scale)))
    states = [s.resize(size, Image.LANCZOS) for s in states]

    hold = max(int(round(hold_s * FPS)), 1)
    fade = max(int(round(fade_s * FPS)), 1)

    work = out_dir / f".{name}-frames"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    n = 0
    def put(img):
        nonlocal n
        img.save(work / f"{n:04d}.png")
        n += 1

    for i, cur in enumerate(states):
        for _ in range(hold):
            put(cur)
        nxt = states[(i + 1) % len(states)]     # loops back to the first
        for k in range(1, fade + 1):
            put(Image.blend(cur, nxt, k / (fade + 1)))

    gif = out_dir / f"{name}.gif"
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-framerate", str(FPS), "-i", str(work / "%04d.png"),
        "-vf", "split[a][b];[a]palettegen=stats_mode=diff[p];"
               "[b][p]paletteuse=dither=bayer:bayer_scale=4",
        "-loop", "0", str(gif),
    ], check=True)
    shutil.rmtree(work)
    kb = gif.stat().st_size / 1024
    print(f"  {name}.gif  {len(states)} states, {n} frames, {size[0]}x{size[1]}, {kb:.0f} KB")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    frames_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, (pattern, hold_s, fade_s) in FILMS.items():
        build(name, frames_dir, out_dir, pattern, hold_s, fade_s)


if __name__ == "__main__":
    main()

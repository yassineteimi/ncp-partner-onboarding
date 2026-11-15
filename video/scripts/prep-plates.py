#!/usr/bin/env python3
"""Turn the Higgsfield clips (assets/shots/hNN.mp4) into one plate per scene.

Each plate is exactly its scene's slot long (slots come from scripts/cuts.py), at
1920x1080 and 30 fps. A clip shorter than its slot is slowed and its motion
interpolated (ffmpeg minterpolate), so a 0.5x stretch stays smooth instead of
holding every frame twice. Writes assets/plates/pNN.mp4; index.html plays those.

    python3 scripts/prep-plates.py          all plates
    python3 scripts/prep-plates.py p03 p09  only these
"""
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from cuts import MASTER  # noqa: E402  (the square cut's slots are never longer)

root = pathlib.Path(__file__).resolve().parent.parent
SLOTS = dict(MASTER)

# scene -> (clip, keep seconds from the start or None for all, reversed)
PLATES = {
    "p01": ("h01", None, False, "s01"),
    "p02": ("h02", None, False, "s02"),
    "p03": ("h03", None, False, "s03"),
    "p04": ("h04", None, False, "s04"),
    "p05": ("h05", None, False, "s05"),
    "p06": ("h06", None, False, "s06"),
    "p07": ("h07", None, False, "s07"),
    "p08": ("h08", None, False, "s08"),
    "p09": ("h09", 4.45, False, "s09"),  # h09 warps into a data hall at 4.5 s: keep the dive, drop the hall
    "p10": ("h02", None, False, "s10"),  # under the full scrim, behind the stack
    "p11": ("h02", None, True, "s11"),   # the pull-back played in reverse into the end card
}


def length(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True, check=True)
    return float(out.stdout.strip())


wanted = set(sys.argv[1:])
(root / "assets/plates").mkdir(parents=True, exist_ok=True)
for pid, (clip, keep, rev, scene) in PLATES.items():
    if wanted and pid not in wanted:
        continue
    srcf = root / f"assets/shots/{clip}.mp4"
    used = min(keep or 1e9, length(srcf))
    slot = SLOTS[scene] + 0.1  # a frame of margin past the scene's end
    factor = (slot + 0.3) / used  # overshoot: minterpolate drops the last few frames
    chain = [f"trim=0:{used}", "setpts=PTS-STARTPTS"]
    if rev:
        chain.append("reverse")
    if factor > 1.02:
        chain += [f"setpts={factor:.4f}*PTS", "minterpolate=fps=30:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1"]
    else:
        chain.append("fps=30")
    chain += ["tpad=stop_mode=clone:stop_duration=1", f"trim=0:{slot}", "setpts=PTS-STARTPTS", "scale=1920:1080:flags=lanczos", "format=yuv420p"]
    out = root / f"assets/plates/{pid}.mp4"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(srcf), "-vf", ",".join(chain), "-an",
                    "-c:v", "libx264", "-preset", "slow", "-crf", "16", str(out)], check=True)
    print(f"{pid}: {clip}{' reversed' if rev else ''} {used:.2f} s -> {length(out):.2f} s (x{factor:.2f})")

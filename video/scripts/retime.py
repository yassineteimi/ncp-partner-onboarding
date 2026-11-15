#!/usr/bin/env python3
"""Write every timing into both root compositions from scripts/cuts.py.

For each cut it sets the root length, each plate's and scene host's start and slot,
the narration, whoosh and music clips, and the AT/SLOT table the camera moves read.
Run after changing a slot: `python3 scripts/retime.py`, then `python3 scripts/prep-plates.py`
if a master slot grew.
"""
import json
import pathlib
import re
import subprocess

from cuts import MASTER, SQUARE, VO, starts

# Whooshes peak 2.5 s into the file; each one peaks on the cut into these scenes.
WHOOSH = ["s02", "s03", "s11"]
WHOOSH_PEAK = 2.5
# Loudness: voice files come at about -21 LUFS, lifted 6 dB; the bed (-9.5 LUFS) sits
# about 16 LU under the lifted voice.
VO_GAIN = 2.0
BED_GAIN = 0.08

root = pathlib.Path(__file__).resolve().parent.parent


def length(rel):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(root / rel)],
                         capture_output=True, text=True, check=True)
    return round(float(out.stdout.strip()), 2)


def retime(name, slots):
    path = root / name
    s = path.read_text()
    at, total = starts(slots)
    slot = dict(slots)

    s = re.sub(r'(id="root"[\s\S]*?data-duration=")[\d.]+(")', lambda m: f"{m.group(1)}{total}{m.group(2)}", s, count=1)
    for sid, d in slots:
        n, st = sid[1:], at[sid]
        for pat in (rf'(<video id="v{n}"[^>]*?data-start=")[\d.]+(" data-duration=")[\d.]+(")',
                    rf'(<div id="el-{sid}"[^>]*?data-start=")[\d.]+(" data-duration=")[\d.]+(")'):
            s = re.sub(pat, lambda m: f"{m.group(1)}{st}{m.group(2)}{d}{m.group(3)}", s)
    s = re.sub(r'(<div id="el-captions"[^>]*?data-duration=")[\d.]+(")', lambda m: f"{m.group(1)}{total}{m.group(2)}", s)

    clips = [f'      <audio id="vo-{sid}" class="clip" src="assets/voice/{sid}.mp3" data-start="{round(at[sid] + VO, 2)}" '
             f'data-duration="{length(f"assets/voice/{sid}.mp3")}" data-volume="{VO_GAIN}" data-track-index="2"></audio>'
             for sid, _ in slots]
    clips += [f'      <audio id="sfx-{sid}" class="clip" src="assets/sfx/whoosh.mp3" data-start="{round(at[sid] - WHOOSH_PEAK, 2)}" '
              f'data-duration="{length("assets/sfx/whoosh.mp3")}" data-volume="0.35" data-track-index="3"></audio>'
              for sid in WHOOSH if sid in at]
    clips.append(f'      <audio id="bed" class="clip" src="assets/music/bed.mp3" data-start="0" data-duration="{total}" '
                 f'data-volume="{BED_GAIN}" data-fade-out="2.5" data-track-index="4"></audio>')
    block = "      <!-- narration:start (scripts/retime.py) -->\n" + "\n".join(clips) + "\n      <!-- narration:end -->"
    s = re.sub(r"      <!-- narration:start[\s\S]*?<!-- narration:end -->", block, s)

    table = f"      const AT = {json.dumps(at)};\n      const SLOT = {json.dumps(slot)};"
    s = re.sub(r"      // timing:start[\s\S]*?// timing:end", "      // timing:start (scripts/retime.py)\n" + table + "\n      // timing:end", s)
    path.write_text(s)
    print(f"{name}: {total} s")


retime("index.html", MASTER)
retime("index-square.html", SQUARE)

#!/usr/bin/env python3
"""Generate the 1:1 scenes (compositions/sq/sNN.html) from the master scenes.

Content, ids and motion stay the master's: each copy only changes the canvas to
1080 x 1080 and appends a square layout below the scene's own styles. The bottom
230 px stay free for the burned-in captions. Edit a master scene, then run:

    python3 scripts/make-square.py
"""
import pathlib
import re

from cuts import SQUARE

root = pathlib.Path(__file__).resolve().parent.parent

LAYOUT = {
    "s01": """
        #s01-a { bottom: 430px; font-size: 60px; }
        #s01-b { width: 952px; }
    """,
    "s02": """
        #s02-name { left: 64px; bottom: 580px; font-size: 130px; }
        #s02-sub { left: 68px; bottom: 520px; }
        #s02-sites { right: auto; left: 64px; top: auto; bottom: 236px; width: 952px; flex-direction: row; gap: 20px; }
        .s02-site { flex: 1 1 0; padding: 22px 24px; }
        .s02-site .city { font-size: 42px; }
        .s02-site .role { font-size: 28px; }
    """,
    "s03": """
        #s03-flow { left: 64px; top: 150px; transform: scale(0.95); transform-origin: 0 0; }
        #s03-flow .gpu { font-size: 30px; }
        #s03-st { bottom: auto; top: 360px; font-size: 72px; width: 952px; }
        #s03-card { right: auto; left: 64px; bottom: 240px; width: 952px; padding: 28px 32px; }
        #s03-card .v { font-size: 120px; margin-top: 16px; }
    """,
    "s04": """
        #s04-st { bottom: auto; top: 130px; font-size: 64px; width: 952px; }
        #s04-card { right: auto; left: 64px; top: 290px; width: 952px; padding: 22px 30px; }
        #s04-path { margin-top: 16px; height: 440px; }
        .s04-box { width: 892px; }
        #s04-router { top: 95px; }
        #s04-pre { top: 190px; width: 430px; }
        #s04-dec { top: 190px; left: 462px; width: 430px; }
        #s04-kv { top: 330px; width: 892px; }
        #s04-tag { top: 380px; }
    """,
    "s06": """
        .s06-block { left: 64px; width: 952px; }
        .s06-block .name { font-size: 72px; }
        #s06-aicr { top: 150px; }
        #s06-pins { flex-wrap: wrap; gap: 12px; }
        #s06-nvcre { top: 470px; }
        #s06-gate { flex-wrap: wrap; gap: 12px; }
    """,
    "s07": """
        #s07-xid { left: 64px; top: 140px; }
        #s07-race { left: 64px; top: 230px; width: 952px; gap: 36px; }
        #s07-f1 { width: 762px; }
        #s07-f2 { width: 952px; }
        .s07-row .who { font-size: 30px; }
        .s07-row .v { font-size: 80px; }
        #s07-foot { left: 64px; bottom: 240px; flex-wrap: wrap; gap: 20px; }
    """,
    "s08": """
        #s08-list { left: 64px; top: 150px; width: 952px; gap: 34px; }
        .s08-item .name { font-size: 56px; }
        .s08-item .what { font-size: 30px; }
        #s08-tag { left: 104px; bottom: 240px; }
    """,
    "s09": """
        #s09-big { left: 64px; top: 140px; font-size: 220px; }
        #s09-l1 { left: 70px; top: 400px; width: 940px; }
        #s09-l2 { left: 70px; top: 540px; width: 940px; }
        #s09-tag { left: 70px; bottom: 240px; }
    """,
    "s11": """
        #s11-line { left: 64px; top: 120px; width: 952px; font-size: 76px; }
        #s11-offer { left: 68px; top: 470px; }
        #s11-card { left: 64px; bottom: 240px; }
    """,
}

out_dir = root / "compositions/sq"
out_dir.mkdir(exist_ok=True)
for sid, _ in SQUARE:
    src = next((root / "compositions").glob(f"{sid}-*.html"))
    s = src.read_text()
    s = re.sub(rf'(id="{sid}-root" data-composition-id="{sid}") data-width="1920" data-height="1080"',
               r'\1 data-width="1080" data-height="1080"', s, count=1)
    assert 'data-width="1080"' in s, sid
    css = "\n".join(f"        #{sid}-root {line.strip()}" for line in LAYOUT[sid].strip().splitlines())
    s = s.replace("      </style>", f"        /* square layout (scripts/make-square.py) */\n{css}\n      </style>", 1)
    header = f"<!-- Generated from compositions/{src.name} by scripts/make-square.py. Edit the master, not this file. -->\n"
    (out_dir / f"{sid}.html").write_text(s.replace("<!doctype html>\n", "<!doctype html>\n" + header, 1))
    print(f"{sid}: {src.name} -> compositions/sq/{sid}.html")

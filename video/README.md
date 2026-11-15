# The two-minute video

Nordhaven's story as a narrated motion-design film: zoom into a partner's data centre,
east-west traffic for training, north-south for inference, then what ran on two sites.
Built with [HyperFrames](https://hyperframes.heygen.com) (HTML and GSAP, rendered to MP4)
over AI-generated data-centre footage, narrated in my HeyGen voice clone.

| Cut | Size | Length | Where |
|---|---|---|---|
| Master | 1920 x 1080 | 1:51.6 | `docs/assets/video/nordhaven.mp4`, the docs site and the README |
| LinkedIn | 1080 x 1080, burned-in captions | 1:32.4 | rendered locally, posted natively |

Every number on screen comes from [`facts.json`](facts.json), which names the committed
file each one was copied from. The footage is illustration and is listed on the
[simulated](../docs/simulated.md) page; the Dynamo layer is tagged "designed, running next".

| File | What it holds |
|---|---|
| `BRIEF.md`, `SPEC.md` | What the film is for, and its look and motion as numbers |
| `voice/script.md`, `voice/lines.tsv` | The narration, one line per scene |
| `shots.md` | The nine footage prompts and the shared style block |
| `index.html`, `index-square.html` | The two root compositions: plates, narration, scene slots |
| `compositions/sNN-*.html` | One scene each; `compositions/sq/` holds the generated square copies and captions |
| `scripts/cuts.py` | Every scene slot of both cuts |

## Rebuilding it

The footage, music and whoosh aren't committed (third-party or regenerable). With the
clips in `assets/shots/`, the bed in `assets/music/bed.mp3` and the whoosh in
`assets/sfx/whoosh.mp3`:

```sh
VOICE_ID=<voice id> node scripts/make-voice-api.mjs   # narration, needs a HeyGen API key
cd scripts && python3 prep-plates.py && python3 make-square.py \
  && python3 make-captions.py && python3 retime.py && cd ..
npx hyperframes check
npx hyperframes render -q delivery -o renders/nordhaven-16x9-master.mp4
npx hyperframes render -c index-square.html -q delivery -o renders/nordhaven-1x1-master.mp4
```

The web file is the master re-encoded at CRF 27 with `-movflags +faststart`.

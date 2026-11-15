# Data-centre shots

Nine shots, no text in frame: HyperFrames adds every label and number. Generated with
Higgsfield's Seedance 2.5, 16:9, audio off, one generation per shot with the shot text
followed by the style block. Delivered at 1280 x 720, 24 fps, 5 to 8 s each, saved as
`assets/shots/hNN.mp4` (not committed); `scripts/prep-plates.py` stretches each to its
scene with motion interpolation and upscales it to 1080p.

## Style block (append to every prompt)

> Dark modern GPU data hall at night, near-black environment, server racks with thin
> emissive lime-green (#76b900) edge lights, faint volumetric haze, cool reflections on a
> polished floor, anamorphic lens, shallow depth of field, smooth stabilised camera,
> photoreal, cinematic. No text, no letters, no logos, no people.

## Shots

| Id | Length | Prompt (before the style block) | Start / end |
|---|---|---|---|
| h01 | 6 s | Extreme macro of a GPU accelerator board in a server tray, heat sinks and copper, a pulse of green light runs across the board; the camera slowly pulls back to reveal the full server and the rack around it. | ends on a full rack, centred |
| h02 | 10 s | Continuous aerial pull-back: from one rack out over rows of racks in a vast data hall, rising through the roof to the exterior of a modern data-centre building at night, cool blue landscape. | extend h01 forward (`video_extension`) if offered |
| h03 | 14 s | The camera glides low down the aisle between two rows of racks; streams of green light pulses travel sideways from rack to rack across the aisle on overhead cable trays, dense and fast, like data exchanged between servers. | straight dolly, horizon level |
| h04 | 13 s | From outside, streams of white and green light flow from a distant city skyline into the front entrance of the data centre, travel to the racks, and return outward as thinner streams; the camera follows the incoming stream inside. | wide exterior to interior |
| h05 | 9 s | Static wide shot of a quiet data hall; the lights dim, and one rack's edge lights turn red and pulse slowly. | locked-off camera |
| h06 | 11 s | Slow push-in on a single server node in a rack; its status light changes from amber to steady green. | ends close on the node |
| h07 | 14 s | Close shot of a row of GPUs inside a server; one GPU's light flickers red, goes dark, then comes back steady green while the others keep glowing. | locked-off camera |
| h08 | 10 s | Slow crane up over the data hall; three zones of racks light up in different colours, blue, orange and purple, while green light keeps flowing between them. | top-down at the end |
| h09 | 8 s | Satellite view of Europe at night, slowly zooming; a thin beam of green light travels from southern Finland to Paris and stays lit, glowing city lights below. | ends framed on the beam |

Reuse: s10 uses h02 blurred behind the stack diagram; s11 uses h02 reversed.

h09 warps into a data hall at 4.5 s; its plate keeps only the dive into the beam.

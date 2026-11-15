# Spec

```text
GOAL:    An NCP architect ends knowing I can take a partner from hardware handover to
         first tenants on NVIDIA's open stack, and that every number shown ran.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps (master). 1080 x 1080 cut after approval.
TIME:    ~93.5 s x 30 = 2805 frames; scene lengths trued to the voice recording.
LOOK:    Footage plates (Higgsfield, dark data hall, #76b900 light) under type.
         Ground #0b0e0c; ink #f2f5ee; muted #a3ab9f; faint #6c7468.
         Accent #76b900 only on proof (measured numbers, "ran it" tags) and east-west flow.
         North-south flow #6fa8dc. Red #ff6f61 only for the fault. Tenant colours
         blue #6fa8dc, orange #f6b26b, purple #b4a7d6 (Part 1's session colours).
         Display: Inter 900, 84-140 px, tracking -0.035em, line height 1.0.
         Secondary: Inter 700, 40-56 px, tracking -0.02em.
         Data: JetBrains Mono 400/700, 24-30 px, +0.04em on tags.
         Proof cards: Part 1's glass (rgba(255,255,255,0.055), blur 28 px, 2 px edge,
         28 px radius); the only cards in the film, one per proof scene.
         Legibility: left scrim 0.88 -> 0 over 62% width, bottom scrim 0.8 -> 0 over 45%.
OBJECTS: racks and GPUs come from the footage; the Dynamo flow and the stack are
         drawn as labelled boxes with arrows, each appearing when the voice names it.
MOTION:  Enter: critically damped spring (HF.smooth, damping 1.0), 0.55 s, blur 10 -> 0.
         Exit: 0.4 s power2.in, scale 0.97, blur. Plates: one slow push per scene,
         scale 1.00 -> 1.06 (zoom in) or 1.08 -> 1.00 (zoom out), sine.inOut.
         Count-ups 1.2-1.6 s then hold. Flow dashes: linear, constant speed.
SHOTS:   see STORYBOARD.md (11 scenes, one plate each).
BANNED:  glowing orbs and particles as decoration, three cards in a row, KPI grids,
         everything centred, text moving while read, logos, em dashes, any number
         not in facts.json, "EU1" in prose.
QA:      the frame where each proof number lands (s03 351, s07 288.8/360.9, s09 4),
         the Dynamo tag in s04, the stack fully built in s10, the end card in s11.
```

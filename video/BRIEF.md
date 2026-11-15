---
workflow: general-video
flow: companion
storyboard: yes
message: "From hardware handover to first tenants on NVIDIA's open stack: I showed it on two sites, and I can do it for a partner"
destination: linkedin-feed, github-readme, github-pages
aspect: 1920x1080 (master), 1080x1080 (LinkedIn cut)
language: en
audience: NVIDIA Cloud Partner solutions architects and hiring managers, and a LinkedIn feed
length: 90s master, 60-75s square cut
angle: proof
---

## Intent

Part 2's launch video. Motion design explains an NVIDIA Cloud Partner data centre by
zooming in and out: east-west traffic for training and post-training, north-south traffic
for inference. Then it shows how the PoC's NVIDIA stack (AICR, NVCRE, NVSentinel, KAI, MIG,
Slinky, KubeVirt, Thanos, Dynamo) runs that fleet on upstream Kubernetes from one Git
repository across two providers, and ends on what I can do for a partner.

## Assets

- facts.json: every number the video may show, with its source. The only source of numbers.
- voice/script.md, voice/lines.tsv: the approved narration, one line per scene.
- shots.md: the nine data-centre shots (h01 to h09), generated with Higgsfield Seedance 2.5,
  saved as assets/shots/hNN.mp4.
- Part 1's design spec (its video-v2/frame.md), reused for continuity.

## Customizations

- Context vs proof: zoomed-out shots are context; measured numbers sit only on "ran it"
  cards with their label (injected, simulated where it applies).
- Dynamo scene is tagged "designed, running next" until it has run; then one real number
  replaces the tag.
- Stills of every scene are reviewed before the full render.

## Notes

- Narration in Yassine's HeyGen voice clone (scripts/make-voice-api.mjs, HeyGen API key). No subtitles on the
  16:9 master; burned-in captions on the 1:1 LinkedIn cut (muted autoplay).
- Low ambient music bed ducked under the voice, soft whooshes on zooms.
- No em dashes, no logos of NVIDIA or providers in frame (names in text are fine).
- Prose follows the docs rules: the partner is Nordhaven, the sites are Paris and Finland.
- Nothing loaded from the network at render time: GSAP vendored, fonts cached.

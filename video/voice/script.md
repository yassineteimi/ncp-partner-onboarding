# Narration (draft for review)

Spoken in Yassine's HeyGen voice clone, one line per scene. `lines.tsv` will hold the
same text once approved. Numbers match `../facts.json`. 16:9 master, about 90 s.

| Scene | On screen | Spoken |
|---|---|---|
| s01 | Hardware arrives months before the first tenant. | A GPU cloud gets its hardware months before its first customer. |
| s02 | Nordhaven, a fictional NVIDIA Cloud Partner · Paris + Finland | Nordhaven is a fictional NVIDIA Cloud Partner: inference in Paris, training in Finland. |
| s03 | East-west: training and post-training · NVLink proven: 351 GB/s, 2× H200 | Inside, training and post-training run east-west, GPU to GPU. On the Finland node, I measured 351 gigabytes per second over NVLink. |
| s04 | North-south: inference · Dynamo, designed, running next | Inference runs north-south. Requests come in, tokens go out. I designed that layer with NVIDIA Dynamo, and it runs next. |
| s05 | Which versions? Is it ready? What if it fails? Who gets the GPUs? | Between handover and the first tenant, every partner asks the same four questions. |
| s06 | AICR pins the stack · NVCRE certifies, then promotes | AICR pins the versions that go together. NVCRE certifies each node before any tenant lands on it. |
| s07 | XID 79, injected · 288.8 s, no human · Part 1: 360.9 s | When a GPU fails, NVSentinel had training back in 288.8 seconds, with nobody involved. My own controller from Part 1 took 360.9. |
| s08 | KAI gangs · MIG slices · Slurm and VMs on the same platform | KAI and MIG share scarce GPUs between teams. Slurm users and VM customers run on the same platform. |
| s09 | Finland's metrics in Paris in 4 s, kept after the site was deleted | Thanos gives one view of both sites, even after one of them is gone. |
| s10 | One Git repository · upstream Kubernetes 1.36 · two providers | All of it runs on upstream Kubernetes, from one Git repository, across two providers. |
| s11 | From hardware handover to first tenants, on NVIDIA's open stack. | From hardware handover to first tenants, on NVIDIA's open stack. That's the work I can do for a partner. |

About 190 words: roughly 80 s of speech at Part 1's pace, which leaves room for the zooms.
The 1:1 cut drops s05 and shortens s08 and s10.

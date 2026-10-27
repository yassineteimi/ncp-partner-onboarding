# Inference with NVIDIA Dynamo (work in progress)

!!! warning "Work in progress"
    Designed and checked without a GPU; not run yet. Nothing on this page has served a
    request. The deployment is prepared for Dynamo v1.5.1 and waits for a run on the
    Paris L4.

=== "In short"

    ### Why inference matters to a partner

    Training fills GPUs in large blocks for weeks. Inference is the steady business:
    every chat, search or agent call is a request that must answer fast. A partner that
    only rents GPU hours competes on price; a partner that serves **tokens** competes on
    latency, throughput and cost per token, and those depend on how the serving layer
    uses the GPUs.

    ### The problems Dynamo addresses

    | Problem | What goes wrong without it | What Dynamo does |
    |---|---|---|
    | **Prefill and decode fight on the same GPU** | Reading a long prompt (prefill) is compute-heavy; generating tokens one by one (decode) is memory-bandwidth-heavy. On one GPU, a long prompt stalls everyone's token stream | Runs them as separate worker pools (*disaggregated serving*), each sized and scaled on its own |
    | **The same prompt prefix is recomputed** | System prompts and multi-turn chats repeat the same opening; each worker rebuilds the same KV cache | A **KV-cache-aware router** sends a request to the worker that already holds its prefix |
    | **KV cache outgrows GPU memory** | Fewer concurrent sessions fit in HBM; old context is thrown away and recomputed | The **KV Block Manager** moves cache blocks down to CPU memory or storage and back |
    | **Moving KV cache between GPUs is slow** | Disaggregation only pays if prefill can hand its cache to decode quickly | **NIXL** transfers it over the fastest path: NVLink inside a server, RDMA between servers |
    | **Traffic changes all day** | Fixed pools either waste GPUs or miss latency targets | The **Planner** scales prefill and decode workers against latency targets |

    ### Architecture

    ```mermaid
    flowchart LR
      client["Client<br/>OpenAI-compatible API"] --> fe["Frontend<br/>HTTP, tokenisation"]
      fe --> router["Router<br/>KV-cache-aware"]
      router --> prefill["Prefill workers<br/>vLLM, SGLang or TRT-LLM"]
      router --> decode["Decode workers"]
      prefill -- "KV cache via NIXL<br/>NVLink or RDMA" --> decode
      decode --- kvbm["KV Block Manager<br/>GPU, CPU memory, storage"]
      planner["Planner<br/>scales the pools"] -.-> prefill
      planner -.-> decode
      subgraph k8s["On Kubernetes"]
        op["Dynamo operator<br/>DynamoGraphDeployment"]
        sched["KAI Scheduler, Grove<br/>gangs and topology"]
      end
      op -.-> fe
      op -.-> prefill
      op -.-> decode
      sched -.-> prefill
    ```

    - **One object describes the service.** A `DynamoGraphDeployment` lists the components
      (frontend, workers, prefill, decode, planner) and the operator creates the pods.
    - **Backend-agnostic.** The worker runs vLLM, SGLang or TensorRT-LLM; clients only see
      an OpenAI-compatible API, so existing applications work unchanged.
    - **Fits the platform already built.** Pods can be scheduled by KAI in a tenant's
      queue, and a component can carry a topology constraint, so prefill and decode land
      where NVLink or the fabric connects them.

    ### What it gives a partner like Nordhaven

    - **Sell inference, not only GPU hours:** a managed, OpenAI-compatible endpoint per
      tenant, on the same fleet, quotas and monitoring as training.
    - **More tokens per GPU, so a lower cost per token:** prefix reuse and disaggregation
      remove repeated and interfering work.
    - **Latency tiers:** separate prefill and decode pools, scaled against latency targets,
      let a partner sell different service levels.
    - **Use of the fabric it paid for:** KV cache moves over NVLink and RDMA, so the
      Spectrum-X or InfiniBand investment serves inference too.
    - **Mapped onto Nordhaven's pools:** aggregated serving of small models on the Paris
      L4s; disaggregated prefill and decode across the two NVLink-connected H200s in Finland.

    ### In one sentence

    Dynamo turns GPUs into an inference service: it splits prompt reading from token
    generation, reuses and moves KV cache over NVLink and RDMA, and scales each part to
    latency targets, which lets a partner sell tokens at a lower cost per token instead
    of raw GPU hours.

=== "Run evidence"

    ### Status

    Prepared and checked without a GPU; not run. The files are in
    [pull request #40](https://github.com/yassineteimi/ncp-partner-onboarding/pull/40),
    not merged yet.

    ### Design decisions, from the v1.5.1 source

    | Decision | Why |
    |---|---|
    | Dynamo v1.5.1 | Latest stable patch release when prepared; v1.6.0 was 3 days old |
    | Operator only | At v1.5.1 the chart's etcd, NATS, Grove, snapshot and its own KAI are off by default; workers are discovered through the Kubernetes API. Nothing duplicates the KAI v0.18.6 already running |
    | Operator scoped to namespace `team-a` | Cluster-wide, its webhook on every Pod creation would call an operator that sits on the often-powered-off CPU worker; namespace scope confines all 8 webhooks to `team-a`. The chart refuses a custom selector, so this is its supported way |
    | CRDs in Git | A namespace-scoped operator can't install its CRDs; the six CRDs of v1.5.1 are committed unchanged and applied one sync wave earlier, server-side (the largest is 1.6 MB) |
    | Model as a workload, not in Argo CD | Its GPU pod would sit Pending whenever no L4 exists; `make dynamo-deploy` applies it during a GPU run |
    | Qwen3-0.6B, one vLLM worker, aggregated | Fits the L4's 24 GB; the first step before disaggregation |
    | Worker scheduled by KAI in `team-a` | Same quotas as every GPU tenant; the operator's own KAI integration needs Grove |
    | Frontend and worker on the GPU node | The 9.2 GB runtime image is pulled once |

    ### Checks without a GPU

    | Check | Result |
    |---|---|
    | Chart render with the Paris values | One operator Deployment, all 8 webhooks scoped to `team-a`, no CRD installer |
    | Images | Both pinned by digest (operator, vLLM runtime) |
    | Model deployment vs the v1beta1 CRD schema | Valid; a deliberately wrong field is rejected |
    | Server-side dry run on the Paris API | All six CRDs accepted |

    ### Next

    Run on the Paris L4: deploy, time to Ready, then time to first token and tokens per
    second at one and four concurrent requests. Then disaggregated serving across the two
    H200s, where NIXL can move KV cache over NVLink.

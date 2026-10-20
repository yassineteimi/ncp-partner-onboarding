# ADR 0009: Metrics across sites, Thanos Receive for fin and a sidecar for par

Status: proposed
Date: 2026-10-20. Owner: ws-platform. Use case: 6.

## Context

EU1 has a permanent site, par, and a site that only exists while a GPU window is paid for, fin. `make fin-down` deletes fin with its disks, so whatever its Prometheus holds goes with it unless it has already left. EU1 wants one view of the L4 on par and the H200s on fin, and that view has to keep showing fin after fin is gone.

Two facts narrow the choice before any product comparison: fin opens no port to par (its firewall allows SSH and the Kubernetes API from admin ranges only), and par can't query a site that no longer exists. Whatever carries fin's metrics has to push them out of fin, while the window is still running.

I started from Thanos because an NVIDIA architect named it as how they think about observability at thousands of GPUs. Mimir and VictoriaMetrics answer the same question, so they're in the table too.

## Options considered

| Option | What it is | For EU1 | Against, for EU1 |
|---|---|---|---|
| A. Thanos sidecar | Prometheus stays where it is; a sidecar uploads its 2 hour blocks to object storage and serves recent data over gRPC to a central Thanos Query | Nothing extra in the write path. A WAN outage loses nothing, because the data waits at the site. Each site keeps alerting locally | Prometheus only turns its head into a block once the head spans 1.5 times the block range, 3 hours (`compactable()` in `tsdb/head.go` at v3.14.0). A 2 hour window ends before the first upload. And Query has to dial into fin for recent data, which means an inbound port on a site that gets deleted |
| B. Thanos Receive | Prometheus remote-writes to Receive, which builds the blocks and uploads them | fin only needs to reach out. Samples are on par within seconds. Receive flushes its head and uploads the last block when it stops (`cmd/thanos/receive.go` L725-736 and L818-832 at v0.42.4). It can take the tenant from the client certificate, so one credential authenticates and names the site | One more component in the write path. At scale it needs a hashring and a replication factor of 3, which triples the ingest work. The sender keeps a remote write queue in memory |
| C. Grafana Mimir 3.2.2 | Remote write into a horizontally scaled, multi-tenant store on object storage | Made for many tenants, with per-tenant limits. Same object storage model as Thanos | AGPL-3.0, which a partner's lawyers have to clear before it runs inside a service they sell. Mimir authenticates nobody: it trusts the `X-Scope-OrgID` header and its docs require an authenticating proxy in front. A lot of moving parts for two sites, even in monolithic mode |
| D. VictoriaMetrics v1.154.1 | Remote write into VictoriaMetrics, single node or cluster | Apache-2.0, small, fast, easy to run | Keeps its data on local disks; object storage only holds backups (vmbackup). Long-term storage would live on par's disks. Downsampling is an Enterprise feature (docs at v1.154.1, "Downsampling") |

## Decision

Both sites use Thanos, in different ways: **Receive for fin, a sidecar for par**, with one Query over both and the bucket.

fin gets Receive because it's the only option where the data leaves fin as it's produced and nothing on par has to reach into fin. The sidecar fails on both counts here. A 2 hour window never cuts a block, and a querier on par would need a door into fin that disappears with fin anyway.

par gets a sidecar, not remote write, because par is the permanent site and its Prometheus should keep working when Receive is down. Receive runs on par's CPU worker, which is powered off most of the time to save money. Remote write from par would leave par's own Prometheus retrying into nothing for days.

Receive authenticates fin with mutual TLS and takes the tenant from the certificate's common name (`--receive.tenant-certificate-field=commonName`). fin can only write as `fin`, and each site gets its own TSDB and its own blocks in the bucket. Mimir would need a separate proxy to do what this flag does.

What would change the answer:

- **A partner whose sites are all permanent, with a reliable WAN:** a sidecar on every site, store gateways reading the bucket, and one Query fanning out. Nothing extra sits in the write path, and an outage between sites delays queries without losing data. That is how par runs here.
- **Thousands of GPUs across many clusters writing to one place:** Receive needs a hashring, a replication factor of 3 and per-tenant limits. At that size Mimir's tenant limits and query sharding deserve a fresh look, if the AGPL is acceptable.
- **No object storage at all:** VictoriaMetrics on local disks is simpler than any of these, if the partner can do without downsampling or buys Enterprise.

## Consequences

- One PromQL endpoint for every GPU of both sites, and fin's metrics stay queryable after fin is deleted: from Receive for 3 days, then from the bucket through the store gateway.
- A CA lives in the par cluster. A Job generates it and the certificates once, and they never go into Git. Adding a site means a new client certificate, and its common name becomes the tenant.
- One Receive, no hashring: a single point of failure in the write path. If it's down during a window, fin's Prometheus keeps its WAL and retries. If the outage outlasts the WAL, those samples are lost.
- The compactor must be the only one writing to the bucket. One replica here, and it stays that way.
- **Rebuild order.** kube-prometheus-stack 91.4.1 only accepts the sidecar's bucket secret as `existingSecret`, and drops `optional` (`templates/prometheus/prometheus.yaml`). So par's Prometheus can't start without that Secret. Today Garage creates it at wave 5, after this chart's wave 0. A running par is fine; a par rebuilt from nothing would hold wave 0. The fix, raised with cos, is to generate the credentials before wave 0 and import them into Garage later.
- **What this PoC can't show:**
  - replication or a hashring, with one Receive and one site writing to it
  - cardinality beyond three GPUs: the 1,000 and 10,000 GPU figures are an extrapolation from measured per-GPU counts, not a load test
  - downsampling on real data before about two days of par uploads have built up
  - fin's write path over the internet, which only exists during rehearsal R and W2

## Evidence

- [Local end to end of fin's write path](../artifacts/platform/mtls-local-20261020T084352Z.txt), using Thanos v0.42.4 and Prometheus 3.14.0. The certificate Job's sign step runs as written, and samples arrive as `tenant_id="fin"` with `site="fin"`. A client without a certificate is refused at the TLS handshake, and so is a `CN=fin` certificate from another CA.
- [Free checks of the manifests](../artifacts/platform/thanos-free-checks-20261020T084528Z.txt):
  - all 37 Thanos flags exist in v0.42.4
  - kube-prometheus-stack renders for both sites with the overlays
  - every object passes a server-side dry run on par
  - promtool tests pass, and a deliberately broken rule fails them
- Source, at the pinned versions: `cmd/thanos/receive.go`, `pkg/tenancy/tenancy.go` and `pkg/compact/downsample/downsample.go` at Thanos v0.42.4; `tsdb/head.go` at Prometheus v3.14.0; `pkg/prometheus/server/statefulset.go` at prometheus-operator v0.94.0; Mimir's "Authentication and authorization" page at mimir-3.2.2; VictoriaMetrics' README at v1.154.1.
- Planned, not run yet:
  - the hub after merge (`make thanos-capture MODE=hub`)
  - rehearsal R on fin CPU instances
  - W2 steps 6a to 6c, with the H200 series per GPU and the panel before and after teardown

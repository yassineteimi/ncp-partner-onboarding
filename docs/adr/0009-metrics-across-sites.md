# ADR 0009: Metrics across sites, Thanos Receive for Finland and a sidecar for Paris

Status: accepted
Scope: observability, both sites (use case 6). Decided after the H200 run, 22 October 2026.

## Context

Nordhaven has a permanent site in Paris, and a site in Finland that only exists while its GPUs are rented. `make fin-down` deletes the Finland site with its disks, so whatever its Prometheus holds goes with it unless it has already left. Nordhaven wants one view of the L4 in Paris and the H200s in Finland, and that view has to keep showing the Finland GPUs after the site is gone.

Two facts narrow the choice before any product comparison: the Finland site opens no port to Paris (its firewall allows SSH and the Kubernetes API from admin ranges only), and Paris can't query a site that no longer exists. Whatever carries the Finland metrics has to push them out of Finland while the site is still running.

Thanos was the starting point. Mimir and VictoriaMetrics answer the same question, so they're in the table too.

## Options considered

| Option | What it is | For Nordhaven | Against, for Nordhaven |
|---|---|---|---|
| A. Thanos sidecar | Prometheus stays where it is; a sidecar uploads its 2 hour blocks to object storage and serves recent data over gRPC to a central Thanos Query | Nothing extra in the write path. A WAN outage loses nothing, because the data waits at the site. Each site keeps alerting locally | Prometheus only turns its head into a block once the head spans 1.5 times the block range, 3 hours (`compactable()` in `tsdb/head.go` at v3.14.0). A site rented for 2 hours is deleted before the first upload. And Query has to dial into Finland for recent data, which means an inbound port on a site that gets deleted |
| B. Thanos Receive | Prometheus remote-writes to Receive, which builds the blocks and uploads them | The Finland site only needs to reach out. Samples are in Paris within seconds. Receive flushes its head and uploads the last block when it stops (`cmd/thanos/receive.go` L725-736 and L818-832 at v0.42.4). It can take the tenant from the client certificate, so one credential authenticates and names the site | One more component in the write path. At scale it needs a hashring and a replication factor of 3, which triples the ingest work. The sender keeps a remote write queue in memory |
| C. Grafana Mimir 3.2.2 | Remote write into a horizontally scaled, multi-tenant store on object storage | Made for many tenants, with per-tenant limits. Same object storage model as Thanos | AGPL-3.0, which a partner's lawyers have to clear before it runs inside a service they sell. Mimir authenticates nobody: it trusts the `X-Scope-OrgID` header and its docs require an authenticating proxy in front. A lot of moving parts for two sites, even in monolithic mode |
| D. VictoriaMetrics v1.154.1 | Remote write into VictoriaMetrics, single node or cluster | Apache-2.0, small, fast, easy to run | Keeps its data on local disks; object storage only holds backups (vmbackup). Long-term storage would live on the Paris disks. Downsampling is an Enterprise feature (docs at v1.154.1, "Downsampling") |

## Decision

Both sites use Thanos, in different ways: **Receive for Finland, a sidecar for Paris**, with one Query over both and the bucket.

Finland gets Receive because it's the only option where the data leaves the site as it's produced and nothing in Paris has to reach into Finland. The sidecar fails on both counts here. A site that lives for two hours never cuts a block, and a querier in Paris would need a door into Finland that disappears with the site anyway.

Paris gets a sidecar, not remote write, because Paris is the permanent site and its Prometheus should keep working when Receive is down. Receive runs on the Paris CPU worker, which is powered off most of the time to save money. Remote write from Paris would leave its own Prometheus retrying into nothing for days.

Receive authenticates the Finland site with mutual TLS and takes the tenant from the certificate's common name (`--receive.tenant-certificate-field=commonName`). The Finland site can only write as `fin`, and each site gets its own TSDB and its own blocks in the bucket. Mimir would need a separate proxy to do what this flag does.

The H200 run on 22 October confirmed it. The Finland series were in the Paris Query about 4 seconds after the Finland Prometheus was Ready. In about half an hour the site sent 4,676,183 samples, none failed or retried. The series were still served from Paris after the site was deleted.

What would change the answer:

- **A partner whose sites are all permanent, with a reliable WAN:** a sidecar on every site, store gateways reading the bucket, and one Query fanning out. Nothing extra sits in the write path, and an outage between sites delays queries without losing data. That is how Paris runs here.
- **Thousands of GPUs across many clusters writing to one place:** Receive needs a hashring, a replication factor of 3 and per-tenant limits. At 40 to 51 DCGM series per GPU, measured on the L4 and the H200s, 10,000 GPUs make about half a million DCGM series before pod-label churn. At that size Mimir's tenant limits and query sharding deserve a fresh look, if the AGPL is acceptable.
- **No object storage at all:** VictoriaMetrics on local disks is simpler than any of these, if the partner can do without downsampling or buys Enterprise.

## Consequences

- One PromQL endpoint for every GPU of both sites, and the Finland metrics stay queryable after the site is deleted: from Receive for 3 days, then from the bucket through the store gateway.
- A CA lives in the Paris cluster. A Job generates it and the certificates once, and they never go into Git. Adding a site means a new client certificate, and its common name becomes the tenant.
- One Receive, no hashring: a single point of failure in the write path. If it's down while the Finland site runs, the Finland Prometheus keeps its WAL and retries. If the outage outlasts the WAL, those samples are lost.
- The compactor must be the only one writing to the bucket. One replica here, and it stays that way.
- **Rebuild order.** kube-prometheus-stack 91.4.1 only accepts the sidecar's bucket secret as `existingSecret`, and drops `optional` (`templates/prometheus/prometheus.yaml`). So the Paris Prometheus can't start without that Secret. Garage used to create it at wave 5, after this chart's wave 0, so a Paris site rebuilt from nothing would have held at wave 0. Now the base Application `objstore-credentials` writes it at wave -1, and Garage's wave 5 Job imports that key ([findings](../findings.md)).
- **MIG changes what the GPU rules count.** Each MIG instance gets its own DCGM series, labelled `GPU_I_ID`, and `DCGM_FI_DEV_GPU_UTIL` isn't reported for MIG instances. The recording rule and the dashboard don't handle that yet: after the split they count GPUs wrong, as the [use case 6 page](../30-metrics-across-sites.md) shows. Grouping by `GPU_I_ID` and counting GPUs from a field every instance reports is the next change.
- **What this PoC can't show:**
  - replication or a hashring, with one Receive and one site writing to it
  - cardinality beyond three GPUs: the 1,000 and 10,000 GPU figures are an extrapolation from measured per-GPU counts, not a load test
  - downsampling on real data before about two days of Paris uploads have built up (shown on SIMULATED blocks instead)
  - the Finland site's last block in the bucket after the H200 run, which I haven't listed yet

## Evidence

- [Local end to end of the Finland write path](../artifacts/platform/mtls-local-20261020T084352Z.txt), using Thanos v0.42.4 and Prometheus 3.14.0. The certificate Job's sign step runs as written, and samples arrive as `tenant_id="fin"` with `site="fin"`. A client without a certificate is refused at the TLS handshake, and so is a `CN=fin` certificate from another CA.
- [Checks of the manifests without a GPU](../artifacts/platform/thanos-free-checks-20261020T084528Z.txt):
  - all 37 Thanos flags exist in v0.42.4
  - kube-prometheus-stack renders for both sites with the overlays
  - every object passes a server-side dry run in Paris
  - promtool tests pass, and a deliberately broken rule fails them
- Source, at the pinned versions: `cmd/thanos/receive.go`, `pkg/tenancy/tenancy.go` and `pkg/compact/downsample/downsample.go` at Thanos v0.42.4; `tsdb/head.go` at Prometheus v3.14.0; `pkg/prometheus/server/statefulset.go` at prometheus-operator v0.94.0; Mimir's "Authentication and authorization" page at mimir-3.2.2; VictoriaMetrics' README at v1.154.1.
- [The hub in Paris](../artifacts/platform/thanos-hub-20261021T114455Z.txt), 21 October:
  - deduplication merges fin-sim's two replicas
  - Receive accepts fin-sim's writes
  - the Paris sidecar has uploaded 14 blocks with no failures
  - port 30291 doesn't answer from my laptop
- [The bucket](../artifacts/platform/thanos-bucket-20261021T114314Z.txt), 21 October:
  - the compactor's 5 minute blocks from SIMULATED backfill
  - Receive's 12 s fin-sim block flushed at a power-off
- A CPU-only test of the Finland site, 21 October:
  - [while it ran](../artifacts/platform/thanos-fin-20261021T153930Z.txt): the Finland series in the Paris Query as `tenant_id="fin"`, 0 failed samples
  - [after deletion](../artifacts/platform/thanos-after-20261021T155641Z.txt): still there 16 minutes after the site was deleted
- The H200 run, 22 October:
  - [whole GPUs](../artifacts/platform/thanos-fin-20261022T095840Z.txt): 2x H200 in the Paris Query, 40 DCGM series each
  - [after the MIG split](../artifacts/platform/thanos-fin-20261022T102230Z.txt) and [its labels](../artifacts/platform/thanos-fin-mig-labels-20261022T102301Z.txt): 20 series per MIG instance, 11 for the split device
  - [after deletion](../artifacts/platform/thanos-after-20261022T102814Z.txt): last sample 26 s before the deletion, 4,676,183 samples sent, 0 failed

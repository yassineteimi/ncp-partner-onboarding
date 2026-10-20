# Targets of the platform lane: use cases 6 and 7, Thanos and KubeVirt.
#
# Included by the top-level Makefile. Give each target a "## " comment on its
# line so make help lists it, and prefix target names with the use case or
# component, to stay clear of the other lanes.

.PHONY: thanos-test-rules thanos-check thanos-fin-secret

thanos-test-rules: ## UC6: promtool tests for the GPU recording rules and dashboard queries (BREAK=1: must fail)
	./scripts/platform/test-rules.sh

thanos-check:  ## UC6: free checks: thanos flags, endpoint config, kustomize, kube-prometheus-stack renders (DRY_RUN=server: also on par)
	./scripts/platform/check-thanos.sh

thanos-fin-secret: ## UC6: copy fin's remote write client certificate from par to fin (run by fin-cp-up)
	./scripts/platform/fin-remote-write-secret.sh

.PHONY: thanos-check-mtls
thanos-check-mtls: ## UC6: local end to end of fin's write path: certificates, mutual TLS, tenant from the certificate (ARTIFACT=1 saves it)
	./scripts/platform/check-mtls.sh

.PHONY: thanos-capture
thanos-capture: ## UC6: evidence through par's API, MODE=hub|fin|after|bucket, into docs/artifacts/platform/
	./scripts/platform/capture-thanos.sh $(or $(MODE),hub)

.PHONY: thanos-backfill-sim
thanos-backfill-sim: ## UC6, SIMULATED: upload 5 days of synthetic blocks (site=sim-backfill) so the compactor's downsampling can be seen
	./scripts/platform/backfill-downsampling.sh

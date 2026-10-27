# Targets for inference serving: NVIDIA Dynamo on par's L4.
#
# Included by the top-level Makefile. Give each target a "## " comment on its
# line so make help lists it.

.PHONY: dynamo-check dynamo-deploy dynamo-test dynamo-delete

dynamo-check:  ## Dynamo: free checks: chart render, digests, webhook scope, model deployment against its CRD (DRY_RUN=server: CRDs on par)
	./scripts/inference/dynamo.sh check

dynamo-deploy: ## Dynamo: apply team-a's Qwen3-0.6B service on the L4 and time it to Ready (L4 up, dynamo synced)
	./scripts/inference/dynamo.sh deploy

dynamo-test:   ## Dynamo: models, one answer, time to first token and tokens per second at concurrency 1 and 4
	./scripts/inference/dynamo.sh test

dynamo-delete: ## Dynamo: remove the model deployment, before par-gpu-down
	./scripts/inference/dynamo.sh delete

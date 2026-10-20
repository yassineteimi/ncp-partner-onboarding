# Targets of the scheduling lane: use cases 4 and 5, KAI, MIG and Slinky.
#
# Included by the top-level Makefile. Give each target a "## " comment on its
# line so make help lists it, and prefix target names with the use case or
# component, to stay clear of the other lanes.

.PHONY: sched-check sched-render-sim sched-sim-demo sched-gang sched-mig sched-mig-check sched-prepull sched-prepull-status sched-prepull-down

sched-check: ## UC4: free checks: KAI and GPU Operator renders, vendored manifests, workloads (DRY_RUN=server: also on par)
	./scripts/scheduling/check.sh

sched-render-sim: ## UC4: regenerate the vendored KWOK and fake GPU operator manifests for par's simulated GPUs
	./scripts/scheduling/render-sim-gpu.sh

sched-sim-demo: ## UC4: par, simulated GPUs: burst, reclaim, gang all-or-nothing, into docs/artifacts/scheduling/ (CPU worker on)
	./scripts/scheduling/sim-demo.sh

sched-gang: ## UC4: two-pod KAI gang with an all-reduce, SITE=par (gloo, CPU worker) or SITE=fin (NCCL, W2 step 4)
	./scripts/scheduling/gang.sh $(or $(SITE),par)

sched-mig: ## UC4: fin, W2 step 5: MIG h200-split, then a tenant per slice (aborts after 10 min, never reboots)
	./scripts/scheduling/mig.sh

sched-mig-check: ## UC4: parse fin's MIG config with mig-parted's own loader, on par's CPU worker
	./scripts/scheduling/check-mig-config.sh

sched-prepull: ## UC4: fin, W2 step S0: pull the gang image onto the H200 node during NVCRE
	./scripts/scheduling/prepull.sh up

sched-prepull-status: ## UC4: fin: is the gang image on the H200 node yet
	./scripts/scheduling/prepull.sh status

sched-prepull-down: ## UC4: fin: remove the pre-pull DaemonSet, before step 4
	./scripts/scheduling/prepull.sh down

# Targets of the readiness lane: use cases 1 to 3, AICR, NVCRE and NVSentinel.
#
# Included by the top-level Makefile. Give each target a "## " comment on its
# line so make help lists it, and prefix target names with the use case or
# component, to stay clear of the other lanes.

READINESS_VENV := .venv

$(READINESS_VENV)/bin/pytest: scripts/readiness/requirements-dev.txt
	python3 -m venv $(READINESS_VENV) && $(READINESS_VENV)/bin/pip install -q -r scripts/readiness/requirements-dev.txt

readiness-venv: $(READINESS_VENV)/bin/pytest ## readiness: Python for the lane's tests and checks (pytest, PyYAML)

readiness-test: $(READINESS_VENV)/bin/pytest ## readiness: unit tests and shellcheck for scripts/readiness
	$(READINESS_VENV)/bin/python -m pytest -q scripts/readiness/tests
	shellcheck --severity=warning --external-sources scripts/readiness/*.sh

readiness-render: $(READINESS_VENV)/bin/pytest ## readiness: helm template every lane chart as Argo CD will, then check pods, images, webhooks
	./scripts/readiness/render.sh

readiness-dryrun: readiness-render ## readiness: server-side dry run on par of everything rendered (SAVE=1 keeps the evidence)
	./scripts/readiness/dryrun.sh $(if $(SAVE),--save)

.PHONY: readiness-venv readiness-test readiness-render readiness-dryrun

########################################
# Use case 2: NVCRE certification as the promotion gate
########################################

READINESS_BIN := .cache/readiness/bin
NVCRE_ENV := PATH="$(CURDIR)/$(READINESS_BIN):$$PATH" SITE=$(or $(SITE),par)

$(READINESS_BIN)/nvcrectl:
	./scripts/readiness/tools.sh

readiness-tools: $(READINESS_BIN)/nvcrectl ## readiness: nvcrectl v0.8.0 and aicr v1.1.0, checksum-verified, in .cache/readiness/bin

readiness-prepull: ## readiness: pull the window's workload images onto the GPU node (SITE=par|fin)
	$(NVCRE_ENV) ./scripts/readiness/nvcre.sh prepull

nvcre-stage:   ## readiness: add the staging taint to the GPU node (SITE=par; fin's node joins with it)
	$(NVCRE_ENV) ./scripts/readiness/nvcre.sh stage

nvcre-certify: $(READINESS_BIN)/nvcrectl $(READINESS_VENV)/bin/pytest ## readiness: NVCRE certification of the staged node (SITE=, WORKLOAD_IMAGE= to override)
	$(NVCRE_ENV) ./scripts/readiness/nvcre.sh certify

readiness-diag: $(READINESS_BIN)/nvcrectl ## readiness: dcgmi diag -r 2 on the GPU node (SITE=, DIAG_VIA=workloadrun|exec)
	$(NVCRE_ENV) ./scripts/readiness/nvcre.sh diag

nvcre-promote: $(READINESS_VENV)/bin/pytest ## readiness: remove the staging taint only if certification and diag passed (SITE=)
	$(NVCRE_ENV) ./scripts/readiness/nvcre.sh promote

.PHONY: readiness-tools readiness-prepull nvcre-stage nvcre-certify readiness-diag nvcre-promote

########################################
# Use case 3: NVSentinel against Part 1's goodput run, on par's L4
########################################

uc3-check:     ## readiness: NVSentinel ready on the L4 before any injection (labels, pods, breaker, journal)
	./scripts/readiness/uc3.sh check

uc3-watch: $(READINESS_VENV)/bin/pytest ## readiness: clock offsets, then record the outage timeline until Ctrl-C
	./scripts/readiness/uc3.sh watch

uc3-goodput:   ## readiness: start Part 1's goodput Job in tenant-a
	./scripts/readiness/goodput.sh start

uc3-inject:    ## readiness: SIMULATED XID as a kernel log line on the L4 (XID=79 by default)
	./scripts/readiness/uc3.sh inject $(or $(XID),79)

uc3-inject-dcgm: ## readiness: SIMULATED XID 79 into DCGM's cache on the L4
	./scripts/readiness/uc3.sh inject-dcgm

uc3-capture: $(READINESS_VENV)/bin/pytest ## readiness: after the Job completes, goodput, phases and NVSentinel's state
	./scripts/readiness/uc3.sh capture

.PHONY: uc3-check uc3-watch uc3-goodput uc3-inject uc3-inject-dcgm uc3-capture

########################################
# Use case 1: AICR as the known-good reference for the H200 pool
########################################

aicr-recipe: $(READINESS_BIN)/aicr ## readiness: AICR v1.1.0 recipes for the H200 pool, and its refusals for what we run
	./scripts/readiness/aicr.sh recipes

aicr-bundle: $(READINESS_BIN)/aicr ## readiness: render the reference recipe for Argo CD (kept as evidence, never synced)
	./scripts/readiness/aicr.sh bundle

.PHONY: aicr-recipe aicr-bundle

$(READINESS_BIN)/aicr:
	./scripts/readiness/tools.sh

nvsentinel-kind: ## readiness: FC4, par's NVSentinel values in NVSentinel's KIND demo cluster, stage by stage (NVSENTINEL_SRC=checkout at v1.28.0)
	./scripts/readiness/kind-rehearsal.sh $(NVSENTINEL_SRC)

.PHONY: nvsentinel-kind

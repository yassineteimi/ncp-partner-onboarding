SHELL := /bin/bash
VENV  := .venv

.PHONY: help par-cluster par-argocd par-cpu-up par-cpu-down par-cpu-destroy par-gpu-up par-acceptance par-gpu-down par-images par-sweep fin-preflight fin-availability fin-cp-up fin-gpu-up fin-acceptance fin-up fin-down fin-sweep argocd-ui grafana-ui cost lint shellcheck fmt docs docs-serve test-goodput

help:
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

########################################
# Site par, Scaleway fr-par
########################################

par-cluster:   ## par: create the private network and the persistent control plane
	./scripts/par/cluster-up.sh

par-argocd:    ## par: install ArgoCD and hand it gitops/sites/par/root.yaml
	./scripts/par/argocd.sh

par-cpu-up:    ## par: create or power on the CPU worker, wait Ready, uncordon (starts a meter)
	./scripts/par/cpu-up.sh

par-cpu-down:  ## par: drain the CPU worker and power it off; its disk stays
	./scripts/par/cpu-down.sh

par-cpu-destroy: ## par: remove the CPU worker and its disk, at the end of the project
	./scripts/par/cpu-destroy.sh

par-gpu-up:    ## par: create the L4 node, join it, wait for nvidia.com/gpu (starts a meter)
	./scripts/par/gpu-up.sh

par-acceptance: ## par: W1 step 2, cuda-vectoradd and nvidia-smi on the L4, versions on the node (free once the L4 is up)
	SITE=par ./scripts/par/acceptance.sh

par-gpu-down:  ## par: drain the L4 node, remove it, destroy it, sweep for leftovers
	./scripts/par/gpu-down.sh

par-images:    ## par: list the images Scaleway will boot on the L4 type
	./scripts/par/gpu-images.sh

par-sweep:     ## par: list every eu1-par server and unattached volume in fr-par, delete nothing
	@bash -c 'source scripts/lib.sh && use_site par && load_env && require_scaleway_env && scaleway_sweep eu1-par'

########################################
# Site fin, Verda Finland
########################################

fin-preflight: ## fin: free go or no-go for a window: H200 orderable, balance, leftovers (HOURS=2)
	./scripts/fin/preflight.sh

fin-availability: ## fin: log once where the H200 node can be ordered, on demand and spot
	./scripts/fin/availability.sh

fin-cp-up:     ## fin: preflight, then the control plane, kubeadm and ArgoCD (cents an hour)
	./scripts/fin/cp-up.sh

fin-gpu-up:    ## fin: preflight, then the H200 node, join, wait for its GPUs (REHEARSAL=1: CPU stand-in)
	./scripts/fin/gpu-up.sh

fin-acceptance: ## fin: W2 at node Ready, the same acceptance on the 2x H200, still in staging (free once the node is up)
	SITE=fin ./scripts/par/acceptance.sh

fin-up: fin-cp-up fin-gpu-up ## fin: the whole site from zero, timed

fin-down:      ## fin: delete every instance with its OS volume, then sweep Verda
	./scripts/fin/down.sh

fin-sweep:     ## fin: list every instance, volume and trashed volume at Verda, delete nothing
	@bash -c 'source scripts/lib.sh && use_site fin && load_env_optional && require_verda_env && verda_sweep eu1-fin'

########################################
# Both sites
########################################

argocd-ui:     ## ArgoCD credentials and port-forward (SITE=par|fin, default par)
	SITE=$(or $(SITE),par) ./scripts/par/argocd-ui.sh

grafana-ui:    ## Grafana credentials and port-forward (SITE=par|fin, default par)
	SITE=$(or $(SITE),par) ./scripts/par/grafana-ui.sh

cost:          ## What every billed node session has cost so far, on both sites
	./scripts/par/cost-report.sh

########################################
# Free checks
########################################

lint:          ## Fail if an em dash has crept into a tracked file (vendored upstream CRDs excepted)
	@dash=$$(printf '\xe2\x80\x94'); \
	if git ls-files -z -- . ':!gitops/manifests/inference/dynamo-crds' | xargs -0 grep -n -I "$$dash" --; then \
	  echo "em dash found, see above"; exit 1; \
	fi
	@echo "no em dashes"

shellcheck:    ## Static check every shell script under scripts/
	@shellcheck --severity=warning --external-sources scripts/*.sh scripts/*/*.sh
	@echo "shellcheck clean"

fmt:           ## Check the Terraform formatting of every site
	@terraform fmt -check -diff -recursive terraform

test-goodput:  ## Unit tests for the goodput trainer loop, store and analysis
	cd workloads/goodput && python3 -m pytest -q

$(VENV)/bin/mkdocs: requirements.txt
	python3 -m venv $(VENV) && $(VENV)/bin/pip install -q -r requirements.txt

docs: $(VENV)/bin/mkdocs  ## Build the documentation site strictly
	$(VENV)/bin/mkdocs build --strict

docs-serve: $(VENV)/bin/mkdocs  ## Serve the documentation site locally
	$(VENV)/bin/mkdocs serve

# Each use case lane adds its targets in its own file, so nobody edits a shared list.
-include mk/*.mk

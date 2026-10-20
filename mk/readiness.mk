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

# Usage:
#   make smoke PANEL=gameap-3
#   make smoke PANEL=gameap-3 SCENARIO=api-read
#   make load PANEL=gameap-4 SCENARIO=api-read
#   make compare SCENARIO=api-read PROFILE=load

PANEL ?= gameap-3
PROFILE ?= baseline
SCENARIO ?= hello
PROMETHEUS_URL ?= http://10.10.10.40:9090/api/v1/write
RESULTS_DIR ?= ./results
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)

.PHONY: smoke baseline load stress soak run compare compare-gameap clean

smoke:
	$(MAKE) run PROFILE=smoke

baseline:
	$(MAKE) run PROFILE=baseline

load:
	$(MAKE) run PROFILE=load

stress:
	$(MAKE) run PROFILE=stress

soak:
	$(MAKE) run PROFILE=soak

run:
	@mkdir -p $(RESULTS_DIR)
	K6_PROMETHEUS_RW_SERVER_URL=$(PROMETHEUS_URL) \
	PANEL=$(PANEL) \
	PROFILE=$(PROFILE) \
	k6 run \
		--tag run_id=$(TIMESTAMP) \
		--summary-export=$(RESULTS_DIR)/$(PANEL)_$(SCENARIO)_$(PROFILE)_$(TIMESTAMP).json \
		-o experimental-prometheus-rw \
		scenarios/$(SCENARIO).js

# Compare GameAP 3.x vs 4.x (sequential)
compare-gameap:
	@echo "=== GameAP 3.x ==="
	$(MAKE) run PANEL=gameap-3 PROFILE=$(PROFILE) SCENARIO=$(SCENARIO)
	@echo "Cooling down 60s..."
	@sleep 60
	@echo "=== GameAP 4.x ==="
	$(MAKE) run PANEL=gameap-4 PROFILE=$(PROFILE) SCENARIO=$(SCENARIO)

# Compare all 4 panels (sequential)
compare:
	@echo "=== GameAP 3.x ==="
	$(MAKE) run PANEL=gameap-3 PROFILE=$(PROFILE) SCENARIO=$(SCENARIO)
	@echo "Cooling down 60s..."
	@sleep 60
	@echo "=== GameAP 4.x ==="
	$(MAKE) run PANEL=gameap-4 PROFILE=$(PROFILE) SCENARIO=$(SCENARIO)
	@echo "Cooling down 60s..."
	@sleep 60
	@echo "=== Pterodactyl ==="
	$(MAKE) run PANEL=pterodactyl PROFILE=$(PROFILE) SCENARIO=$(SCENARIO)
	@echo "Cooling down 60s..."
	@sleep 60
	@echo "=== Pelican ==="
	$(MAKE) run PANEL=pelican PROFILE=$(PROFILE) SCENARIO=$(SCENARIO)

clean:
	rm -rf $(RESULTS_DIR)/*

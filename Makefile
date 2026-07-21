.PHONY: setup deploy teardown destroy dry-run stop start status credentials check check-quota request-quotas

# Interactive onboarding wizard (config, secrets, validation, quotas)
setup:
	@echo "Running project onboarding wizard..."
	./bootstrap.sh

# Provision hub + student clusters. Non-interactive: make deploy ARGS=--yes
# or YES=true make deploy
deploy:
	./agnosticd/deploy.sh $(ARGS)

# Full cleanup from agnosticd/config.yml (students + hub + AWS orphans).
# DESTROY_HUB=false make teardown       — students + orphans only
# DRY_RUN=true make teardown            — inventory / planned actions
# make dry-run                          — same as DRY_RUN=true
# make destroy                          — scaffold alias for teardown
# YES=true make teardown                — non-interactive destroy
# make teardown ARGS=--yes              — same
teardown:
	./agnosticd/teardown.sh $(ARGS)

# Scaffold-compatible aliases
destroy: teardown

dry-run:
	DRY_RUN=true ./agnosticd/teardown.sh --dry-run

stop:
	./agnosticd/stop.sh

start:
	./agnosticd/start.sh

status:
	./agnosticd/status.sh

# Show consolidated cluster access info (API URLs, kubeconfigs, passwords).
# Use --save to write output to deployment_info.txt: make credentials ARGS=--save
credentials:
	./agnosticd/credentials.sh $(ARGS)

check:
	./bootstrap.sh --check-only

check-quota: request-quotas

request-quotas:
	./agnosticd/request-quotas.sh

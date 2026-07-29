.PHONY: setup deploy teardown destroy dry-run stop start status credentials check check-quota request-quotas deploy-student teardown-student build-ee

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

# ── Ansible Role (TNA student clusters) ──────────────────────────
# Deploy a single TNA student cluster via Ansible.
# GUID= and BASE_DOMAIN= are required.  TAGS= limits to specific phases.
#   make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
#   make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com TAGS=phase6,phase7,phase8
deploy-student:
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
	  ansible/playbooks/deploy-tna-student.yml \
	  -e tna_guid=$(GUID) \
	  -e tna_base_domain=$(BASE_DOMAIN) \
	  $(if $(TAGS),--tags $(TAGS),) \
	  $(ARGS)

# Tear down a single TNA student cluster.
#   make teardown-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
teardown-student:
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
	  ansible/playbooks/teardown-tna-student.yml \
	  -e tna_guid=$(GUID) \
	  -e tna_base_domain=$(BASE_DOMAIN) \
	  $(ARGS)

# Build the Execution Environment image for containerised runs.
build-ee:
	ansible-builder build -f ansible/execution-environment.yml -t tna-student-ee:latest

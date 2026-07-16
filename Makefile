.PHONY: setup deploy teardown stop start status check

setup:
	@echo "Running project onboarding..."
	./bootstrap.sh

deploy:
	./agnosticd/deploy.sh

teardown:
	./agnosticd/teardown.sh

stop:
	./agnosticd/stop.sh

start:
	./agnosticd/start.sh

status:
	./agnosticd/status.sh

check:
	./bootstrap.sh --check-only

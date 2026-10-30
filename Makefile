.PHONY: lint test sync-rules check-rules

lint:
	shellcheck init.sh scripts/*.sh tests/*.sh

test:
	tests/run.sh

sync-rules:
	scripts/sync-rules.sh .

check-rules:
	scripts/sync-rules.sh --check .

.PHONY: lint test

lint:
	shellcheck init.sh scripts/*.sh tests/*.sh

test:
	tests/run.sh

.PHONY: lint test

lint:
	shellcheck init.sh scripts/*.sh tests/*.sh templates/.claude/hooks/*.sh
	scripts/check-rules-size.sh

test:
	tests/run.sh

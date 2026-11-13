.PHONY: lint test

lint:
	shellcheck init.sh scripts/*.sh tests/*.sh templates/.claude/hooks/*.sh templates/.githooks/*
	scripts/check-rules-size.sh

test:
	tests/run.sh
	tests/agent-guard.sh
	tests/check-project.sh
	tests/merged-pr-ci.sh

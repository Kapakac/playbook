PLAYBOOK ?= ../playbook

.PHONY: sync-rules check-rules hooks

sync-rules:
	$(PLAYBOOK)/scripts/sync-rules.sh .

check-rules:
	$(PLAYBOOK)/scripts/sync-rules.sh --check .

hooks:
	git config core.hooksPath .githooks

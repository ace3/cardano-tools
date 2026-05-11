SHELL := /bin/bash
SCRIPT := scripts/cardano-pool-decommission.sh
RUN := ENV_FILE="$(ENV_FILE)" CARDANO_CLI="$(CARDANO_CLI)" RETIRE_EPOCH="$(RETIRE_EPOCH)" TX_IN="$(TX_IN)" REWARD_BALANCE="$(REWARD_BALANCE)" SUBMIT="$(SUBMIT)" CONFIRM="$(CONFIRM)" ALLOW_STAKE_DEREG="$(ALLOW_STAKE_DEREG)" $(SCRIPT)

.PHONY: help check status retirement-cert retirement-build retirement-sign retirement-submit withdraw-build withdraw-sign withdraw-submit stake-dereg-cert stake-dereg-build stake-dereg-sign stake-dereg-submit test

help:
	@echo "Cardano pool decommission commands"
	@echo
	@echo "Setup:"
	@echo "  make check"
	@echo "  make status"
	@echo
	@echo "Pool retirement:"
	@echo "  make retirement-cert RETIRE_EPOCH=..."
	@echo "  make retirement-build RETIRE_EPOCH=... TX_IN=..."
	@echo "  make retirement-sign"
	@echo "  make retirement-submit SUBMIT=1 CONFIRM=RETIRE_POOL"
	@echo
	@echo "Reward/deposit withdrawal:"
	@echo "  make withdraw-build REWARD_BALANCE=... TX_IN=..."
	@echo "  make withdraw-sign"
	@echo "  make withdraw-submit SUBMIT=1 CONFIRM=WITHDRAW_REWARDS"
	@echo
	@echo "Stake key deregistration:"
	@echo "  make stake-dereg-cert"
	@echo "  make stake-dereg-build TX_IN=... [REWARD_BALANCE=...]"
	@echo "  make stake-dereg-sign"
	@echo "  make stake-dereg-submit SUBMIT=1 CONFIRM=DEREGISTER_STAKE ALLOW_STAKE_DEREG=1"
	@echo
	@echo "Validation:"
	@echo "  make test"

check:
	@$(RUN) check-env

status:
	@$(RUN) status

retirement-cert:
	@$(RUN) make-retirement-cert

retirement-build:
	@$(RUN) build-retirement

retirement-sign:
	@$(RUN) sign-retirement

retirement-submit:
	@$(RUN) submit-retirement

withdraw-build:
	@$(RUN) build-withdraw

withdraw-sign:
	@$(RUN) sign-withdraw

withdraw-submit:
	@$(RUN) submit-withdraw

stake-dereg-cert:
	@$(RUN) make-stake-dereg-cert

stake-dereg-build:
	@$(RUN) build-stake-dereg

stake-dereg-sign:
	@$(RUN) sign-stake-dereg

stake-dereg-submit:
	@$(RUN) submit-stake-dereg

test:
	@bash -n $(SCRIPT)
	@bash tests/run-tests.sh
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck $(SCRIPT) tests/run-tests.sh; else echo "shellcheck not installed; skipped"; fi

.PHONY: help setup up down \
        initial validate-initial \
        import-fixed fixed validate-fixed \
        scan test-firewall destroy clean

VENV        := $(shell pwd)/.venv
TFLOCAL     := $(VENV)/bin/tflocal
AWSLOCAL    := $(VENV)/bin/awslocal

# ============================================================
# PCI-DSS POC — Local Workflow (MiniStack + tflocal)
# ============================================================

help:
	@echo ""
	@echo "First time setup:"
	@echo "  make setup              Check and install all required tools"
	@echo "  source .venv/bin/activate"
	@echo ""
	@echo "Initial state workflow (violations):"
	@echo "  make up                 Start MiniStack"
	@echo "  make initial            Deploy broken state"
	@echo "  make validate-initial   Confirm all resources exist"
	@echo "  make scan               Expect PCI failures"
	@echo ""
	@echo "Fixed state workflow (compliant, no destroy needed):"
	@echo "  make import-fixed       Hand off SGs to fixed_state TF management"
	@echo "  make fixed              Apply PCI fixes in-place"
	@echo "  make validate-fixed     Confirm all fixed resources exist"
	@echo "  make scan               Expect all ✅"
	@echo ""
	@echo "Other:"
	@echo "  make test-firewall      FQDN tests — REAL AWS ONLY"
	@echo "  make destroy            Destroy fixed_state resources"
	@echo "  make clean              Full teardown: TF state + Docker container"
	@echo ""

setup:
	bash setup.sh

up:
	docker-compose up -d
	@echo "Waiting for MiniStack to be healthy..."
	@sleep 5

down:
	docker-compose down

# ── Initial state ─────────────────────────────────────────────────────────────

initial:
	cd initial_state && $(TFLOCAL) init -input=false && \
	  $(TFLOCAL) apply -auto-approve

validate-initial:
	@bash smoke_tests/validate_initial_state.sh

# ── Fixed state ───────────────────────────────────────────────────────────────

import-fixed:
	@bash scripts/import_fixed.sh

fixed:
	cd fixed_state && $(TFLOCAL) init -input=false && \
	  $(TFLOCAL) apply -auto-approve

validate-fixed:
	@bash smoke_tests/validate_fixed_state.sh

# ── Validation ────────────────────────────────────────────────────────────────

scan:
	@bash smoke_tests/scan.sh

test-firewall:
	@echo "=== Tier 3: Network Firewall FQDN tests ==="
	@echo "!! REQUIRES REAL AWS ENVIRONMENT !!"
	@test -n "$(INSTANCE_ID)" || (echo "ERROR: INSTANCE_ID not set" && exit 1)
	@test -n "$(AWS_REGION)"  || (echo "ERROR: AWS_REGION not set"  && exit 1)
	bash smoke_tests/tier3_firewall.sh

# ── Teardown ──────────────────────────────────────────────────────────────────

destroy:
	-cd fixed_state   && $(TFLOCAL) destroy -auto-approve 2>/dev/null || true
	-cd initial_state && $(TFLOCAL) destroy -auto-approve 2>/dev/null || true

clean:
	@echo "Removing Terraform state..."
	rm -rf initial_state/.terraform initial_state/.terraform.lock.hcl \
	       initial_state/terraform.tfstate initial_state/terraform.tfstate.backup
	rm -rf fixed_state/.terraform fixed_state/.terraform.lock.hcl \
	       fixed_state/terraform.tfstate fixed_state/terraform.tfstate.backup
	rm -f  fixed_state/terraform.tfvars
	@echo "Stopping MiniStack..."
	docker-compose down
	@echo "Clean complete."

# PCI-DSS POC — DevOps Task 00000010

Simulated Payment Provider startup. An internal audit identified two PCI-DSS gaps in
the current infrastructure. This repository delivers a **5-day interim remediation** — a
minimum viable in-place fix on existing infrastructure that satisfies PCI-DSS 1.3.1 and
1.3.2 without requiring data migration or a new VPC.

---

## PCI-DSS Scope

| Requirement | Description | Violation in current state |
|---|---|---|
| **1.3.1** | Inbound traffic to the CDE is restricted to only necessary traffic; all other traffic is denied | SGs allow port 80/443/3306 from `0.0.0.0/0` |
| **1.3.2** | Outbound traffic from the CDE is restricted to only necessary traffic; all other traffic is denied | All SGs have default allow-all egress |

All three CDE components are in scope: **ALB**, **EC2 app**, **EC2 MySQL**.

---

## Tech Stack

| Tool | Version | Purpose |
|---|---|---|
| Terraform | 1.15.7 | Infrastructure as Code |
| tflocal | 0.25.0 | Terraform wrapper → MiniStack (pinned — 0.26.0+ breaks on Python 3.13) |
| MiniStack | 1.3.68 light | Local AWS emulator via Docker |
| awslocal | latest | AWS CLI → MiniStack |
| Python | 3.x | Scan script helpers + API-side filtering |
| Docker Desktop | 29.5.3+ | Runs MiniStack container |

> **MiniStack limitations:** does not enforce SG rules at the packet level; does not
> support `aws_networkfirewall_*` resources; ignores `instance.group-id` API filter.
> The scan validates configuration state, not actual traffic.

---

## Repository Structure

```
altium_poc/
├── README.md                        ← this file
├── FUTURE_STATE.md                  ← long-term target architecture
├── Makefile                         ← all workflow targets
├── docker-compose.yml               ← MiniStack container
├── setup.sh                         ← install toolchain into .venv
├── .terraform-version               ← pins Terraform 1.15.7 (tfenv)
│
├── initial_state/                   ← pre-remediation baseline (violations)
│   ├── README.md
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
│
├── fixed_state/                     ← PCI-compliant interim fix
│   ├── README.md
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/                     ← VPC import + NAT GW + route tables
│       ├── security_groups/         ← core PCI 1.3.1 + 1.3.2 fix
│       ├── compute/                 ← EC2 app + MySQL, no public IPs
│       ├── alb/                     ← ALB + listeners + redirect
│       └── firewall/                ← stub — real AWS only
│
├── scripts/
│   └── import_fixed.sh              ← resolves IDs, writes tfvars, imports state
│
├── smoke_tests/
│   ├── validate_initial_state.sh    ← resource existence checks (initial)
│   ├── validate_fixed_state.sh      ← resource existence checks (fixed)
│   ├── scan.sh                      ← compliance scan (connection path + PCI checks)
│   └── tier3_firewall.sh            ← FQDN tests (real AWS only)
```

---

## Setup

```bash
# 1. Install toolchain
bash setup.sh

# 2. Activate virtual environment
source .venv/bin/activate

# 3. Verify Docker is available
docker --version
```

---

## Make Targets

| Target | Description |
|---|---|
| `make up` | Start MiniStack container |
| `make down` | Stop MiniStack container |
| `make initial` | Deploy initial (broken) state to MiniStack |
| `make validate-initial` | Check all initial_state resources exist correctly |
| `make import-fixed` | Resolve IDs, write terraform.tfvars, import resources into fixed_state |
| `make fixed` | Apply PCI fixes in-place on imported resources |
| `make validate-fixed` | Check all fixed_state resources exist correctly |
| `make scan` | Full compliance scan — connection path + PCI 1.3.1 + 1.3.2 |
| `make clean` | Wipe TF state + terraform.tfvars + stop MiniStack |

---

## Happy Chains

### Initial state — confirm violations baseline

```bash
make up              # start MiniStack
make initial         # deploy broken state
make validate-initial # ✅ all resources exist
make scan            # ❌ PCI 1.3.1 + 1.3.2 failures expected
```

Expected scan result for initial state:

```
── PCI 1.3.1 — Inbound Restricted ─────────
  ❌  alb-sg port 80 from 0.0.0.0/0 — action=forward (exposes data path)
  ❌  app-sg inbound port 80 — open to 0.0.0.0/0
  ❌  mysql-sg inbound port 3306 — open to 0.0.0.0/0

── PCI 1.3.2 — Outbound Restricted ────────
  ❌  alb-sg egress port 80 — rule missing
  ❌  app-sg egress: MISSING: egress port 443 to known CIDRs
  ❌  mysql-sg egress — loopback placeholder missing
```

### Fixed state — apply remediation and validate compliance

```bash
# (continuing from above — MiniStack still running with initial state deployed)
make import-fixed    # import resources into fixed_state TF state
make fixed           # apply PCI fixes
make validate-fixed  # ✅ all resources exist
make scan            # ✅ PCI 1.3.1 + 1.3.2 pass (⚠️ MiniStack egress gaps expected)
```

Expected scan result for fixed state:

```
── PCI 1.3.1 — Inbound Restricted ─────────
  ✅  alb-sg port 80 from 0.0.0.0/0 — redirect to HTTPS ✓
  ✅  app-sg inbound port 80 — ONLY from alb-sg ref ✓
  ✅  mysql-sg inbound port 3306 — ONLY from app-sg ref ✓

── PCI 1.3.2 — Outbound Restricted ────────
  ✅  alb-sg egress port 80 — ONLY to app-sg ref ✓
  ✅  app-sg egress — tcp:443 to whitelist + tcp:3306 to mysql-sg only ✓
  ✅  mysql-sg egress — loopback placeholder present ✓
  ⚠️  mysql-sg egress — allow-all present (MiniStack default; config is correct)
```

### Full chain (clean start to compliance)

```bash
make clean           # wipe everything
make up
make initial
make validate-initial
make scan            # confirm violations
make import-fixed
make fixed
make validate-fixed
make scan            # confirm compliance
```

---

## Scan Output Sections

| Section | Checks |
|---|---|
| Traffic Path | ALB active, listener 443, TG registration, EC2 running, ALB→app + app→MySQL SG path |
| EC2 SG Attachment | Correct SG attached (not just default) for ALB, app EC2, mysql EC2 |
| PCI 1.3.1 | alb-sg port 80 redirect/forward; app-sg inbound ONLY from alb-sg; mysql-sg inbound ONLY from app-sg |
| PCI 1.3.2 | alb-sg egress port 80 to app-sg only; app-sg egress 443+3306 restricted; mysql-sg egress loopback |
| App Server Egress Whitelist | app-sg egress CIDRs exactly match `app_egress_cidrs` from terraform.tfvars |

---

## Further Reading

- [Initial State](initial_state/README.md) — violations, architecture, resources
- [Fixed State](fixed_state/README.md) — remediation, design decisions, compliance mapping
- [Future State](FUTURE_STATE.md) — long-term target with Network Firewall, NACLs, WAF, new VPC

#!/usr/bin/env bash
# scripts/import_fixed.sh
# Resolves IDs + descriptions from initial_state, writes terraform.tfvars,
# imports SGs + EC2 instances + ALB resources into fixed_state TF management.
#
# Run once before: make fixed
# Usage: bash scripts/import_fixed.sh  |  make import-fixed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TFLOCAL="$ROOT_DIR/.venv/bin/tflocal"
AWSLOCAL="$ROOT_DIR/.venv/bin/awslocal"

INITIAL_DIR="$ROOT_DIR/initial_state"
FIXED_DIR="$ROOT_DIR/fixed_state"

ok()   { echo "  ✅  $*"; }
info() { echo "  →   $*"; }
fail() { echo "  ❌  $*"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  import_fixed.sh — Resolve IDs + import to fixed_state      ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Preflight ─────────────────────────────────────────────────────────────────

if ! curl -sf http://localhost:4566/health >/dev/null 2>&1; then
  fail "MiniStack not reachable — run: make up && make initial"
fi

# ── Read IDs from initial_state outputs ───────────────────────────────────────

echo ""
echo "── Reading initial_state outputs ───────────────────────────────"

pushd "$INITIAL_DIR" > /dev/null
VPC_ID=$(            "$TFLOCAL" output -raw vpc_id           2>/dev/null) || fail "vpc_id not found — run: make initial"
APP_INSTANCE_ID=$(   "$TFLOCAL" output -raw app_instance_id   2>/dev/null) || fail "app_instance_id not found"
MYSQL_INSTANCE_ID=$( "$TFLOCAL" output -raw mysql_instance_id 2>/dev/null) || fail "mysql_instance_id not found"
ALB_ARN=$(           "$TFLOCAL" output -raw alb_arn           2>/dev/null) || fail "alb_arn not found"
popd > /dev/null

ok "VPC:       $VPC_ID"
ok "app EC2:   $APP_INSTANCE_ID"
ok "MySQL EC2: $MYSQL_INSTANCE_ID"
ok "ALB ARN:   $ALB_ARN"

# ── Resolve subnet IDs ────────────────────────────────────────────────────────
# All 3 subnets are flat (AZ spread only — no public/private segregation).
# Routing distinction is route-table-only (handled in modules/vpc/).

echo ""
echo "── Resolving subnet IDs ────────────────────────────────────────"

SUBNET_JSON=$("$AWSLOCAL" ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].SubnetId' \
  --output json 2>/dev/null || echo "[]")

SUBNET_COUNT=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$SUBNET_JSON")
[ "$SUBNET_COUNT" -ge 3 ] || fail "Expected ≥3 subnets, got $SUBNET_COUNT"

SUBNET_0=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[0])" "$SUBNET_JSON")
SUBNET_1=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[1])" "$SUBNET_JSON")
SUBNET_2=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[2])" "$SUBNET_JSON")
ok "subnet[0] ALB + NAT GW: $SUBNET_0"
ok "subnet[1] app EC2:      $SUBNET_1"
ok "subnet[2] MySQL EC2:    $SUBNET_2"

# ── Resolve SG IDs + descriptions ────────────────────────────────────────────

echo ""
echo "── Resolving SG IDs + descriptions ────────────────────────────"

get_sg_field() {
  "$AWSLOCAL" ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].$2" --output text 2>/dev/null || echo ""
}

ALB_SG_ID=$(    get_sg_field "alb-sg"   "GroupId")
ALB_SG_DESC=$(  get_sg_field "alb-sg"   "Description")
APP_SG_ID=$(    get_sg_field "app-sg"   "GroupId")
APP_SG_DESC=$(  get_sg_field "app-sg"   "Description")
MYSQL_SG_ID=$(  get_sg_field "mysql-sg" "GroupId")
MYSQL_SG_DESC=$(get_sg_field "mysql-sg" "Description")

[ -n "$ALB_SG_ID"   ] && [ "$ALB_SG_ID"   != "None" ] || fail "alb-sg not found"
[ -n "$APP_SG_ID"   ] && [ "$APP_SG_ID"   != "None" ] || fail "app-sg not found"
[ -n "$MYSQL_SG_ID" ] && [ "$MYSQL_SG_ID" != "None" ] || fail "mysql-sg not found"

ok "alb-sg:   $ALB_SG_ID  (desc: $ALB_SG_DESC)"
ok "app-sg:   $APP_SG_ID  (desc: $APP_SG_DESC)"
ok "mysql-sg: $MYSQL_SG_ID  (desc: $MYSQL_SG_DESC)"

# ── Resolve ALB resources ─────────────────────────────────────────────────────

echo ""
echo "── Resolving ALB resources ─────────────────────────────────────"

TG_ARN=$("$AWSLOCAL" elbv2 describe-target-groups \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
[ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ] || fail "Target group not found"
ok "TG ARN: $TG_ARN"

L80_ARN=$("$AWSLOCAL" elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn' --output text 2>/dev/null || echo "")
[ -n "$L80_ARN" ] && [ "$L80_ARN" != "None" ] || fail "Port 80 listener not found"
ok "Listener 80:  $L80_ARN"

L443_ARN=$("$AWSLOCAL" elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`443`].ListenerArn' --output text 2>/dev/null || echo "")
[ -n "$L443_ARN" ] && [ "$L443_ARN" != "None" ] || fail "Port 443 listener not found"
ok "Listener 443: $L443_ARN"

# MiniStack does not expose Certificates in describe-listeners — query ACM directly.
CERT_ARN=$("$AWSLOCAL" acm list-certificates \
  --query 'CertificateSummaryList[0].CertificateArn' \
  --output text 2>/dev/null || echo "")
[ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ] || fail "ACM certificate not found — run: make initial"
ok "ACM cert:     $CERT_ARN"

# ── Delete port 80 forward listener ──────────────────────────────────────────
# initial_state creates port 80 listener with forward action.
# fixed_state needs redirect action — forward→redirect transition fails provider
# validation on imported listener. Delete it so Terraform creates fresh redirect.

echo ""
echo "── Preparing port 80 listener for redirect ─────────────────────"

if "$AWSLOCAL" elbv2 delete-listener --listener-arn "$L80_ARN" 2>/dev/null; then
  ok "Deleted forward listener — Terraform will create redirect listener"
else
  ok "Port 80 listener already absent or already redirect (skipping delete)"
fi

# ── Write terraform.tfvars ────────────────────────────────────────────────────

echo ""
echo "── Writing terraform.tfvars ────────────────────────────────────"

cat > "$FIXED_DIR/terraform.tfvars" <<TFVARS
# Auto-generated by scripts/import_fixed.sh — do not edit auto-populated fields.

vpc_id     = "$VPC_ID"
subnet_ids = ["$SUBNET_0", "$SUBNET_1", "$SUBNET_2"]

alb_sg_description   = "$ALB_SG_DESC"
app_sg_description   = "$APP_SG_DESC"
mysql_sg_description = "$MYSQL_SG_DESC"

acm_certificate_arn = "$CERT_ARN"

# Edit before applying:
allowed_ingress_ips = ["10.0.0.0/8"]  # reserved — see fixed_state/README.md §Extras
# app_egress_cidrs: app EC2 outbound CIDRs (port 443 only) — defaults set in variables.tf
TFVARS

ok "terraform.tfvars written"

# ── Initialise fixed_state ────────────────────────────────────────────────────

echo ""
echo "── Initialising fixed_state ────────────────────────────────────"

cd "$FIXED_DIR"
"$TFLOCAL" init -upgrade -input=false >/dev/null 2>&1
ok "fixed_state initialised"

# ── Import resources ──────────────────────────────────────────────────────────

echo ""
echo "── Importing resources into fixed_state ────────────────────────"

import_if_needed() {
  local addr="$1"
  local id="$2"
  if "$TFLOCAL" state list 2>/dev/null | grep -qF "$addr"; then
    ok "$addr already imported (skipping)"
  else
    if "$TFLOCAL" import "$addr" "$id" 2>/dev/null; then
      ok "Imported $addr ← $id"
    else
      fail "Import failed: $addr ← $id"
    fi
  fi
}

import_if_needed "module.security_groups.aws_security_group.alb"   "$ALB_SG_ID"
import_if_needed "module.security_groups.aws_security_group.app"   "$APP_SG_ID"
import_if_needed "module.security_groups.aws_security_group.mysql" "$MYSQL_SG_ID"
import_if_needed "module.compute.aws_instance.app"                 "$APP_INSTANCE_ID"
import_if_needed "module.compute.aws_instance.mysql"               "$MYSQL_INSTANCE_ID"
import_if_needed "module.alb.aws_lb.main"                          "$ALB_ARN"
import_if_needed "module.alb.aws_lb_target_group.app"              "$TG_ARN"
import_if_needed "module.alb.aws_lb_listener.https"                "$L443_ARN"
# http listener deleted above — Terraform creates fresh redirect listener
# aws_lb_target_group_attachment does not support import — Terraform creates fresh

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Done. Next steps:                                           ║"
echo "║  1. Review fixed_state/terraform.tfvars                     ║"
echo "║  2. make fixed   — apply PCI fixes in-place                  ║"
echo "║  3. make scan    — validate compliance                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

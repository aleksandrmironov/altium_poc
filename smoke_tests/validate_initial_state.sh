#!/usr/bin/env bash
# smoke_tests/validate_initial_state.sh
# Confirms initial_state resources were created correctly via AWS API.
# Existence checks only — compliance + connection path checks are in: make scan
#
# Usage: bash smoke_tests/validate_initial_state.sh
# Or:    make validate-initial

set -euo pipefail

PASS=0; FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AW="${ROOT_DIR}/.venv/bin/awslocal"

ok()   { echo "  ✅  $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  $*"; FAIL=$((FAIL + 1)); }
aw()   { "$AW" "$@" 2>/dev/null; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  initial_state — Resource Existence Validation               ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Preflight ─────────────────────────────────────────────────────────────────

if ! curl -sf http://localhost:4566/health >/dev/null 2>&1; then
  echo "  ❌  MiniStack not reachable — run: make up && make initial"
  exit 1
fi

# ── VPC ───────────────────────────────────────────────────────────────────────

echo ""
echo "── VPC + Networking ────────────────────────────────────────────"

VPC_ID=$(aw ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=default-vpc-simulated" \
  --query 'Vpcs[0].VpcId' --output text || echo "")

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "  ❌  VPC not found — run: make initial"
  exit 1
fi
ok "VPC: $VPC_ID"

# ── Subnets ───────────────────────────────────────────────────────────────────

SUBNET_COUNT=$(aw ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'length(Subnets)' --output text || echo "0")
[ "${SUBNET_COUNT:-0}" -ge 3 ] \
  && ok "Subnets: $SUBNET_COUNT found" \
  || fail "Subnets: expected ≥3, got ${SUBNET_COUNT:-0}"

# ── Internet Gateway ──────────────────────────────────────────────────────────

IGW_ID=$(aw ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' --output text || echo "")
[ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ] \
  && ok "Internet Gateway: $IGW_ID" \
  || fail "Internet Gateway: not attached to VPC"

# ── Security Groups ───────────────────────────────────────────────────────────

echo ""
echo "── Security Groups ─────────────────────────────────────────────"

for SG_NAME in alb-sg app-sg mysql-sg; do
  SG_ID=$(aw ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text || echo "")
  [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ] \
    && ok "$SG_NAME: $SG_ID" \
    || fail "$SG_NAME: not found"
done

# ── EC2 Instances ─────────────────────────────────────────────────────────────

echo ""
echo "── EC2 Instances ───────────────────────────────────────────────"

for INST_NAME in app-instance-initial mysql-instance-initial; do
  STATE=$(aw ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INST_NAME" \
    --query 'Reservations[0].Instances[0].State.Name' --output text || echo "")
  [ "$STATE" = "running" ] \
    && ok "$INST_NAME: running" \
    || fail "$INST_NAME: expected running, got ${STATE:-not found}"
done

# ── EC2 SG Attachment ─────────────────────────────────────────────────────────
# Checks correct SG is attached at ENI level.
# Finds each instance by tag:Name, reads SecurityGroups[*].GroupName.

echo ""
echo "── EC2 SG Attachment ───────────────────────────────────────────"

check_sg_attached_by_tag() {
  local inst_tag="$1"
  local expected_sg="$2"

  local inst_json
  inst_json=$(aw ec2 describe-instances \
    --filters "Name=tag:Name,Values=$inst_tag" \
    --output json || echo '{"Reservations":[]}')

  local attached
  attached=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
r = data.get('Reservations', [])
if not r: print(''); sys.exit(0)
sgs = r[0]['Instances'][0].get('SecurityGroups', [])
print(','.join(s['GroupName'] for s in sgs))
" <<< "$inst_json")

  if [ -z "$attached" ]; then
    fail "$inst_tag → instance not found"
    return
  fi

  if echo "$attached" | tr ',' '\n' | grep -qx "$expected_sg"; then
    ok "$inst_tag → $expected_sg attached (got: $attached)"
  else
    fail "$inst_tag → $expected_sg NOT attached (got: ${attached:-none})"
  fi
}

check_sg_attached_by_tag "app-instance-initial"   "app-sg"
check_sg_attached_by_tag "mysql-instance-initial" "mysql-sg"

# ── ALB ───────────────────────────────────────────────────────────────────────

echo ""
echo "── ALB ─────────────────────────────────────────────────────────"

ALB_STATE=$(aw elbv2 describe-load-balancers \
  --names "alb-initial" \
  --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "")
ALB_ARN=$(aw elbv2 describe-load-balancers \
  --names "alb-initial" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
[ "$ALB_STATE" = "active" ] \
  && ok "ALB alb-initial: active" \
  || fail "ALB alb-initial: expected active, got ${ALB_STATE:-not found}"

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  LISTENER_COUNT=$(aw elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'length(Listeners)' --output text || echo "0")
  [ "${LISTENER_COUNT:-0}" -eq 2 ] \
    && ok "ALB listeners: 2 (port 80 + 443)" \
    || fail "ALB listeners: expected 2, got ${LISTENER_COUNT:-0}"

  TG_COUNT=$(aw elbv2 describe-target-groups \
    --query 'length(TargetGroups)' --output text || echo "0")
  [ "${TG_COUNT:-0}" -ge 1 ] \
    && ok "Target group: found" \
    || fail "Target group: not found"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
printf "║  Results: %2d passed, %2d failed%-28s║\n" "$PASS" "$FAIL" ""
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "  Some resources missing — re-run: make initial"
  exit 1
else
  echo "  All resources confirmed. Run: make scan"
  exit 0
fi

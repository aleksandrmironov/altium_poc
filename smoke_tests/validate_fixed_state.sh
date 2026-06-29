#!/usr/bin/env bash
# smoke_tests/validate_fixed_state.sh
# Confirms fixed_state resources were created correctly via AWS API.
# Existence checks only — compliance + connection path checks are in: make scan
#
# Usage: bash smoke_tests/validate_fixed_state.sh
# Or:    make validate-fixed

set -euo pipefail

PASS=0; FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AW="${ROOT_DIR}/.venv/bin/awslocal"

ok()   { echo "  ✅  $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️   $*"; }
aw()   { "$AW" "$@" 2>/dev/null; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  fixed_state — Resource Existence Validation                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Preflight ─────────────────────────────────────────────────────────────────

if ! curl -sf http://localhost:4566/health >/dev/null 2>&1; then
  echo "  ❌  MiniStack not reachable — run: make up && make initial"
  exit 1
fi

# Fetch all instances once — MiniStack ignores instance.group-id API filter,
# so Python-side filtering on the full list is used throughout.
ALL_INSTANCES_JSON=$(aw ec2 describe-instances --output json \
  || echo '{"Reservations":[]}')

# ── VPC ───────────────────────────────────────────────────────────────────────

echo ""
echo "── VPC + Networking ────────────────────────────────────────────"

VPC_ID=$(aw ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=default-vpc-simulated" \
  --query 'Vpcs[0].VpcId' --output text || echo "")

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "  ❌  VPC not found — run: make initial && make import-fixed && make fixed"
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

# ── NAT Gateway ───────────────────────────────────────────────────────────────

NAT_ID=$(aw ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=nat-gw-fixed" \
  --query 'NatGateways[0].NatGatewayId' --output text || echo "")
[ -n "$NAT_ID" ] && [ "$NAT_ID" != "None" ] \
  && ok "NAT Gateway nat-gw-fixed: $NAT_ID" \
  || fail "NAT Gateway nat-gw-fixed: not found — check vpc module applied"

# ── Route Table ───────────────────────────────────────────────────────────────

RT_ID=$(aw ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=rt-app-fixed" \
  --query 'RouteTables[0].RouteTableId' --output text || echo "")
[ -n "$RT_ID" ] && [ "$RT_ID" != "None" ] \
  && ok "Route table rt-app-fixed: $RT_ID" \
  || fail "Route table rt-app-fixed: not found"

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

# Find instances by SG ID using Python-side filtering on ALL_INSTANCES_JSON.
# MiniStack's instance.group-id API filter is unreliable — ignored in practice.

instance_state_for_sg_id() {
  python3 -c "
import json, sys
data  = json.loads(sys.argv[1])
sg_id = sys.argv[2]
for r in data.get('Reservations', []):
    for inst in r.get('Instances', []):
        ids = [sg['GroupId'] for sg in inst.get('SecurityGroups', [])]
        if sg_id in ids:
            print(inst.get('State', {}).get('Name', 'none')); sys.exit(0)
print('none')
" "$ALL_INSTANCES_JSON" "$1"
}

instance_sg_names_for_sg_id() {
  python3 -c "
import json, sys
data  = json.loads(sys.argv[1])
sg_id = sys.argv[2]
for r in data.get('Reservations', []):
    for inst in r.get('Instances', []):
        ids = [sg['GroupId'] for sg in inst.get('SecurityGroups', [])]
        if sg_id in ids:
            names = [sg['GroupName'] for sg in inst.get('SecurityGroups', [])]
            print(','.join(names)); sys.exit(0)
print('')
" "$ALL_INSTANCES_JSON" "$1"
}

for SG_NAME in app-sg mysql-sg; do
  SG_ID=$(aw ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text || echo "")
  if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    fail "$SG_NAME instance: SG not found"
    continue
  fi
  STATE=$(instance_state_for_sg_id "$SG_ID")
  [ "$STATE" = "running" ] \
    && ok "$SG_NAME instance: running" \
    || fail "$SG_NAME instance: expected running, got ${STATE:-not found}"
done

# ── EC2 SG Attachment ─────────────────────────────────────────────────────────

echo ""
echo "── EC2 SG Attachment ───────────────────────────────────────────"

for SG_NAME in app-sg mysql-sg; do
  SG_ID=$(aw ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text || echo "")

  if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    fail "$SG_NAME → SG not found"
    continue
  fi

  ATTACHED=$(instance_sg_names_for_sg_id "$SG_ID")

  if [ -z "$ATTACHED" ]; then
    fail "$SG_NAME instance → not found"
    continue
  fi

  if echo "$ATTACHED" | tr ',' '\n' | grep -qx "$SG_NAME"; then
    ok "$SG_NAME instance → $SG_NAME attached (got: $ATTACHED)"
  else
    fail "$SG_NAME instance → $SG_NAME NOT attached (got: ${ATTACHED:-none})"
  fi

  if echo "$ATTACHED" | tr ',' '\n' | grep -q "^default$"; then
    warn "$SG_NAME instance → default SG present (rules cleared — deny-all, MiniStack limitation)"
  fi
done

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
  [ "${LISTENER_COUNT:-0}" -ge 1 ] \
    && ok "ALB listeners: ${LISTENER_COUNT} found" \
    || fail "ALB listeners: none found"

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
  echo "  Some resources missing — re-run: make import-fixed && make fixed"
  exit 1
else
  echo "  All resources confirmed. Run: make scan"
  exit 0
fi

#!/usr/bin/env bash
# smoke_tests/scan.sh
# Connection path + compliance scan — PCI 1.3.1 + 1.3.2 + app server egress whitelist.
# Prerequisite: run make validate-initial / make validate-fixed first.
#
# Usage: bash smoke_tests/scan.sh
# Or:    make scan

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AWSLOCAL="$ROOT_DIR/.venv/bin/awslocal"

# ── Counters ──────────────────────────────────────────────────────────────────

PASS=0; FAIL=0; WARN=0

ok()   { echo "  ✅  $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️   $*"; WARN=$((WARN + 1)); }

aw() { "$AWSLOCAL" "$@" 2>/dev/null; }

# ── Python helpers ────────────────────────────────────────────────────────────

sg_id_by_name() {
  python3 -c "
import json, sys
sgs = json.loads(sys.argv[1]).get('SecurityGroups', [])
ids = [s['GroupId'] for s in sgs if s['GroupName'] == sys.argv[2]]
print(ids[0] if ids else '')
" "$1" "$2"
}

# Uses ALL_INSTANCES_JSON (fetched once at preflight) and filters in Python —
# MiniStack ignores the instance.group-id API filter.
instance_state_by_sg_id() {
  local sg_id="$1"
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
" "$ALL_INSTANCES_JSON" "$sg_id"
}

instance_sg_names_by_sg_id() {
  local sg_id="$1"
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
" "$ALL_INSTANCES_JSON" "$sg_id"
}

# Check if SG inbound on port comes ONLY from a specific source SG (no CIDR).
# Returns: "exact" | "missing" | "has_cidr:{cidrs}" | "wrong_sg:{names}" | "open_all"
inbound_source_check() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
sg_json    = json.loads(sys.argv[1])
sg_name    = sys.argv[2]
port       = int(sys.argv[3])
source_id  = sys.argv[4]

sgs = sg_json.get("SecurityGroups", [])
sg_map = {s["GroupId"]: s["GroupName"] for s in sgs}

found_rules = []
for sg in sgs:
    if sg["GroupName"] != sg_name:
        continue
    for p in sg.get("IpPermissions", []):
        lo    = p.get("FromPort", -1)
        hi    = p.get("ToPort",   -1)
        proto = p.get("IpProtocol", "")
        if proto != "-1" and not (lo <= port <= hi):
            continue
        for r in p.get("IpRanges", []):
            cidr = r.get("CidrIp", "")
            if cidr == "0.0.0.0/0":
                print("open_all"); sys.exit(0)
            found_rules.append(f"cidr:{cidr}")
        for g in p.get("UserIdGroupPairs", []):
            gid = g.get("GroupId", "")
            found_rules.append("exact_sg" if gid == source_id else f"sg:{sg_map.get(gid, gid)}")

if not found_rules:
    print("missing"); sys.exit(0)

cidr_sources = [r for r in found_rules if r.startswith("cidr:")]
wrong_sg     = [r for r in found_rules if r.startswith("sg:")]
has_exact    = "exact_sg" in found_rules

if cidr_sources:
    print("has_cidr:" + ",".join(cidr_sources)); sys.exit(0)
if wrong_sg:
    print("wrong_sg:" + ",".join(wrong_sg)); sys.exit(0)
if has_exact:
    print("exact"); sys.exit(0)
print("missing")
PY
}

# Check if SG egress on port goes ONLY to a specific dest SG (no CIDR).
# Returns: "exact" | "missing" | "has_cidr:{cidrs}" | "wrong_sg:{names}" | "allow_all"
egress_dest_check() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
sg_json  = json.loads(sys.argv[1])
sg_name  = sys.argv[2]
port     = int(sys.argv[3])
dest_id  = sys.argv[4]

sgs = sg_json.get("SecurityGroups", [])
sg_map = {s["GroupId"]: s["GroupName"] for s in sgs}

found = []
for sg in sgs:
    if sg["GroupName"] != sg_name:
        continue
    for p in sg.get("IpPermissionsEgress", []):
        lo    = p.get("FromPort", -1)
        hi    = p.get("ToPort",   -1)
        proto = p.get("IpProtocol", "")
        if proto == "-1":
            for r in p.get("IpRanges", []):
                if r.get("CidrIp") == "0.0.0.0/0":
                    print("allow_all"); sys.exit(0)
            continue
        if not (lo <= port <= hi):
            continue
        for r in p.get("IpRanges", []):
            found.append(f"cidr:{r.get('CidrIp','')}")
        for g in p.get("UserIdGroupPairs", []):
            gid = g.get("GroupId", "")
            found.append("exact_sg" if gid == dest_id else f"sg:{sg_map.get(gid, gid)}")

if not found:
    print("missing"); sys.exit(0)

cidr_f    = [f for f in found if f.startswith("cidr:")]
wrong_sg  = [f for f in found if f.startswith("sg:")]
has_exact = "exact_sg" in found

if cidr_f:
    print("has_cidr:" + ",".join(cidr_f)); sys.exit(0)
if wrong_sg:
    print("wrong_sg:" + ",".join(wrong_sg)); sys.exit(0)
if has_exact:
    print("exact"); sys.exit(0)
print("missing")
PY
}

# Check app-sg egress: expects tcp:443 to cidrs + tcp:3306 to mysql-sg + nothing else.
app_egress_full_check() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
sg_json        = json.loads(sys.argv[1])
mysql_sg_id    = sys.argv[2]
expected_raw   = sys.argv[3]
expected_cidrs = set(c.strip() for c in expected_raw.split(",") if c.strip())

sgs    = sg_json.get("SecurityGroups", [])
sg_map = {s["GroupId"]: s["GroupName"] for s in sgs}
issues = []

has_443_cidr     = False
actual_443_cidrs = set()
has_3306_mysql   = False
extra_rules      = []

for sg in sgs:
    if sg["GroupName"] != "app-sg":
        continue
    for p in sg.get("IpPermissionsEgress", []):
        lo    = p.get("FromPort", -1)
        hi    = p.get("ToPort",   -1)
        proto = p.get("IpProtocol", "")
        if proto == "-1":
            continue  # skip MiniStack default allow-all
        covers_443  = (lo <= 443  <= hi)
        covers_3306 = (lo <= 3306 <= hi)
        for r in p.get("IpRanges", []):
            cidr = r.get("CidrIp", "")
            if covers_443 and cidr and cidr != "0.0.0.0/0":
                has_443_cidr = True
                actual_443_cidrs.add(cidr)
            elif cidr == "0.0.0.0/0":
                extra_rules.append(f"egress 0.0.0.0/0 port {lo}-{hi}")
            elif not covers_443:
                extra_rules.append(f"egress cidr:{cidr} port {lo}-{hi}")
        for g in p.get("UserIdGroupPairs", []):
            gid  = g.get("GroupId", "")
            name = sg_map.get(gid, gid)
            if covers_3306 and gid == mysql_sg_id:
                has_3306_mysql = True
            else:
                extra_rules.append(f"egress sg:{name} port {lo}-{hi}")

if not has_443_cidr:
    issues.append("MISSING: egress port 443 to known CIDRs")
else:
    missing_cidrs = expected_cidrs - actual_443_cidrs
    extra_cidrs   = actual_443_cidrs - expected_cidrs
    if missing_cidrs:
        issues.append(f"MISSING_CIDRS: {','.join(sorted(missing_cidrs))}")
    if extra_cidrs:
        issues.append(f"EXTRA_CIDRS: {','.join(sorted(extra_cidrs))}")

if not has_3306_mysql:
    issues.append("MISSING: egress port 3306 to mysql-sg")

for r in extra_rules:
    issues.append(f"EXTRA: {r}")

print("ok" if not issues else "\n".join(issues))
PY
}

has_default_sg_id() {
  python3 - "$1" "$2" <<'PY'
import json, sys
sg_json    = json.loads(sys.argv[1])
sg_id_list = sys.argv[2].split()
default_id = ""
for sg in sg_json.get("SecurityGroups", []):
    if sg["GroupName"] == "default":
        default_id = sg["GroupId"]; break
if not default_id:
    print("no"); sys.exit(0)
print("yes" if default_id in sg_id_list else "no")
PY
}

# ── Read expected egress whitelist ────────────────────────────────────────────

EXPECTED_EGRESS_CIDRS=$(python3 - "$ROOT_DIR/fixed_state/terraform.tfvars" <<'PY'
import sys, re
defaults = "93.184.216.34/32,203.0.113.10/32"
try:
    with open(sys.argv[1]) as f:
        content = f.read()
    match = re.search(r'app_egress_cidrs\s*=\s*\[(.*?)\]', content, re.DOTALL)
    if match:
        cidrs = re.findall(r'"([^"]+)"', match.group(1))
        print(",".join(cidrs) if cidrs else defaults)
    else:
        print(defaults)
except Exception:
    print(defaults)
PY
)

# ── Header ────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Compliance Scan — Connection Path + PCI 1.3.1 / 1.3.2      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  ℹ️   Application server egress whitelist: $EXPECTED_EGRESS_CIDRS"

# ── Preflight ─────────────────────────────────────────────────────────────────

if ! curl -sf http://localhost:4566/health >/dev/null 2>&1; then
  echo "  ❌  MiniStack not reachable — run: make up && make initial"
  exit 1
fi

SG_JSON=$(aw ec2 describe-security-groups --output json \
  || echo '{"SecurityGroups":[]}')

# Fetch ALL instances once — MiniStack ignores instance.group-id API filter.
ALL_INSTANCES_JSON=$(aw ec2 describe-instances --output json \
  || echo '{"Reservations":[]}')

ALB_ARN=$(aw elbv2 describe-load-balancers \
  --names "alb-initial" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text || echo "")
ALB_STATE=$(aw elbv2 describe-load-balancers \
  --names "alb-initial" \
  --query 'LoadBalancers[0].State.Code' --output text || echo "")
ALB_SG_IDS=$(aw elbv2 describe-load-balancers \
  --names "alb-initial" \
  --query 'LoadBalancers[0].SecurityGroups' \
  --output text || echo "")

ALB_SG_ID=$(sg_id_by_name "$SG_JSON" "alb-sg")
APP_SG_ID=$(sg_id_by_name "$SG_JSON" "app-sg")
MYSQL_SG_ID=$(sg_id_by_name "$SG_JSON" "mysql-sg")

# ── Traffic Path ──────────────────────────────────────────────────────────────

echo ""
echo "── Traffic Path ────────────────────────────────────────────────"

[ "$ALB_STATE" = "active" ] \
  && ok   "ALB alb-initial active" \
  || fail "ALB alb-initial not active (state: ${ALB_STATE:-not found})"

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  L443=$(aw elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[?Port==`443`].ListenerArn' --output text || echo "")
  [ -n "$L443" ] && [ "$L443" != "None" ] \
    && ok   "ALB listener 443 (HTTPS) configured" \
    || fail "ALB listener 443 not configured"

  TG_ARN=$(aw elbv2 describe-target-groups \
    --query 'TargetGroups[0].TargetGroupArn' --output text || echo "")
  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    TG_COUNT=$(aw elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'length(TargetHealthDescriptions)' --output text || echo "0")
    [ "${TG_COUNT:-0}" -gt 0 ] 2>/dev/null \
      && ok   "EC2 app registered in target group ($TG_COUNT target)" \
      || fail "EC2 app not registered in target group"
  else
    fail "Target group not found"
  fi
else
  fail "ALB not found — skipping target group checks"
fi

if [ -n "$APP_SG_ID" ]; then
  STATE=$(instance_state_by_sg_id "$APP_SG_ID")
  [ "$STATE" = "running" ] \
    && ok   "EC2 app running" \
    || fail "EC2 app not running (state: ${STATE:-not found})"
else
  fail "app-sg not found — cannot check EC2 app state"
fi

if [ -n "$MYSQL_SG_ID" ]; then
  STATE=$(instance_state_by_sg_id "$MYSQL_SG_ID")
  [ "$STATE" = "running" ] \
    && ok   "EC2 MySQL running" \
    || fail "EC2 MySQL not running (state: ${STATE:-not found})"
else
  fail "mysql-sg not found — cannot check EC2 MySQL state"
fi

# ALB → app connectivity: both SG sides must allow port 80
if [ -n "$ALB_SG_ID" ] && [ -n "$APP_SG_ID" ]; then
  ALB_EGR=$(egress_dest_check   "$SG_JSON" "alb-sg" "80" "$APP_SG_ID")
  APP_IN=$(inbound_source_check  "$SG_JSON" "app-sg" "80" "$ALB_SG_ID")
  if [ "$ALB_EGR" = "exact" ] && [ "$APP_IN" = "exact" ]; then
    ok "ALB → app   connectivity: port 80 path open — alb-sg egress ✓ app-sg ingress ✓"
  elif [ "$ALB_EGR" = "allow_all" ] || [ "$APP_IN" = "open_all" ]; then
    ok "ALB → app   connectivity: port 80 path open (unrestricted)"
  else
    fail "ALB → app   connectivity: SG path blocked (alb egress=$ALB_EGR, app ingress=$APP_IN)"
  fi
fi

# app → MySQL connectivity: both SG sides must allow port 3306
if [ -n "$APP_SG_ID" ] && [ -n "$MYSQL_SG_ID" ]; then
  APP_EGR=$(egress_dest_check    "$SG_JSON" "app-sg"   "3306" "$MYSQL_SG_ID")
  MYSQL_IN=$(inbound_source_check "$SG_JSON" "mysql-sg" "3306" "$APP_SG_ID")
  if [ "$APP_EGR" = "exact" ] && [ "$MYSQL_IN" = "exact" ]; then
    ok "app → MySQL connectivity: port 3306 path open — app-sg egress ✓ mysql-sg ingress ✓"
  elif [ "$APP_EGR" = "allow_all" ] || [ "$MYSQL_IN" = "open_all" ]; then
    ok "app → MySQL connectivity: port 3306 path open (unrestricted)"
  else
    fail "app → MySQL connectivity: SG path blocked (app egress=$APP_EGR, mysql ingress=$MYSQL_IN)"
  fi
fi

# ── EC2 SG Attachment ─────────────────────────────────────────────────────────

echo ""
echo "── EC2 SG Attachment ───────────────────────────────────────────"

if [ -n "$ALB_SG_IDS" ] && [ "$ALB_SG_IDS" != "None" ]; then
  ALB_HAS_DEFAULT=$(has_default_sg_id "$SG_JSON" "$ALB_SG_IDS")
  [ "$ALB_HAS_DEFAULT" = "no" ] \
    && ok   "ALB → default SG not attached" \
    || fail "ALB → default SG attached — potential allow-all risk"
else
  warn "ALB SG list not available — cannot check default SG"
fi

if [ -n "$APP_SG_ID" ]; then
  ATTACHED=$(instance_sg_names_by_sg_id "$APP_SG_ID")
  if echo "$ATTACHED" | tr ',' '\n' | grep -qx "app-sg"; then
    ok "app EC2 → app-sg attached"
  else
    fail "app EC2 → app-sg NOT attached (got: ${ATTACHED:-none})"
  fi
  if echo "$ATTACHED" | tr ',' '\n' | grep -q "^default$"; then
    fail "app EC2 → default SG attached — combined effect risk"
  else
    ok   "app EC2 → default SG not attached"
  fi
fi

if [ -n "$MYSQL_SG_ID" ]; then
  ATTACHED=$(instance_sg_names_by_sg_id "$MYSQL_SG_ID")
  if echo "$ATTACHED" | tr ',' '\n' | grep -qx "mysql-sg"; then
    ok "mysql EC2 → mysql-sg attached"
  else
    fail "mysql EC2 → mysql-sg NOT attached (got: ${ATTACHED:-none})"
  fi
  if echo "$ATTACHED" | tr ',' '\n' | grep -q "^default$"; then
    fail "mysql EC2 → default SG attached — combined effect risk"
  else
    ok   "mysql EC2 → default SG not attached"
  fi
fi

# ── PCI 1.3.1 — Inbound Restricted ───────────────────────────────────────────

echo ""
echo "── PCI 1.3.1 — Inbound Restricted ─────────────────────────────"

# alb-sg port 80: open + redirect = ✅ (redirect fires before data access)
#                 open + forward  = ❌ (unprotected — data path exposed)
#                 closed          = ✅ (not accepting port 80 at all)
ALB_PORT80_RULE=$(python3 -c "
import json, sys
sgs = json.loads(sys.argv[1]).get('SecurityGroups', [])
for sg in sgs:
    if sg['GroupName'] != 'alb-sg': continue
    for p in sg.get('IpPermissions', []):
        lo = p.get('FromPort', -1); hi = p.get('ToPort', -1)
        if p.get('IpProtocol') != '-1' and not (lo <= 80 <= hi): continue
        for r in p.get('IpRanges', []):
            if r.get('CidrIp') == '0.0.0.0/0': print('open'); sys.exit(0)
print('closed')
" "$SG_JSON")

if [ "$ALB_PORT80_RULE" = "open" ]; then
  if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    L80_ACTION=$(aw elbv2 describe-listeners \
      --load-balancer-arn "$ALB_ARN" \
      --query 'Listeners[?Port==`80`].DefaultActions[0].Type' \
      --output text || echo "")
    if [ "$L80_ACTION" = "redirect" ]; then
      ok "alb-sg port 80 from 0.0.0.0/0 — redirect to HTTPS ✓ (redirect fires before data access)"
    else
      fail "alb-sg port 80 from 0.0.0.0/0 — action=${L80_ACTION:-unknown} (forward exposes data path)"
    fi
  else
    warn "alb-sg port 80 from 0.0.0.0/0 — listener action unknown (ALB not found)"
  fi
else
  ok "alb-sg port 80 not open from 0.0.0.0/0"
fi

if [ -n "$ALB_SG_ID" ]; then
  RESULT=$(inbound_source_check "$SG_JSON" "app-sg" "80" "$ALB_SG_ID")
  case "$RESULT" in
    exact)        ok   "app-sg inbound port 80 — ONLY from alb-sg ref ✓" ;;
    missing)      fail "app-sg inbound port 80 — no rule found" ;;
    open_all)     fail "app-sg inbound port 80 — open to 0.0.0.0/0" ;;
    has_cidr:*)   fail "app-sg inbound port 80 — CIDR source: ${RESULT#has_cidr:}" ;;
    wrong_sg:*)   fail "app-sg inbound port 80 — wrong SG source: ${RESULT#wrong_sg:}" ;;
  esac
else
  fail "app-sg inbound: alb-sg not found — cannot verify source"
fi

if [ -n "$APP_SG_ID" ]; then
  RESULT=$(inbound_source_check "$SG_JSON" "mysql-sg" "3306" "$APP_SG_ID")
  case "$RESULT" in
    exact)        ok   "mysql-sg inbound port 3306 — ONLY from app-sg ref ✓" ;;
    missing)      fail "mysql-sg inbound port 3306 — no rule found" ;;
    open_all)     fail "mysql-sg inbound port 3306 — open to 0.0.0.0/0" ;;
    has_cidr:*)   fail "mysql-sg inbound port 3306 — CIDR source: ${RESULT#has_cidr:}" ;;
    wrong_sg:*)   fail "mysql-sg inbound port 3306 — wrong SG source: ${RESULT#wrong_sg:}" ;;
  esac
else
  fail "mysql-sg inbound: app-sg not found — cannot verify source"
fi

# ── PCI 1.3.2 — Outbound Restricted ──────────────────────────────────────────

echo ""
echo "── PCI 1.3.2 — Outbound Restricted ────────────────────────────"
echo "  ℹ️   MiniStack injects default allow-all egress regardless of config."
echo "       allow_all results are MiniStack fidelity gaps. Validate on real AWS."

if [ -n "$APP_SG_ID" ]; then
  RESULT=$(egress_dest_check "$SG_JSON" "alb-sg" "80" "$APP_SG_ID")
  case "$RESULT" in
    exact)        ok   "alb-sg egress port 80 — ONLY to app-sg ref ✓" ;;
    missing)      fail "alb-sg egress port 80 — rule missing" ;;
    allow_all)    warn "alb-sg egress — allow-all present (MiniStack default; config correct)" ;;
    has_cidr:*)   fail "alb-sg egress port 80 — CIDR destination: ${RESULT#has_cidr:}" ;;
    wrong_sg:*)   fail "alb-sg egress port 80 — wrong SG dest: ${RESULT#wrong_sg:}" ;;
  esac
else
  fail "alb-sg egress: app-sg not found — cannot verify"
fi

if [ -n "$MYSQL_SG_ID" ]; then
  RESULT=$(app_egress_full_check "$SG_JSON" "$MYSQL_SG_ID" "$EXPECTED_EGRESS_CIDRS")
  if [ "$RESULT" = "ok" ]; then
    ok "app-sg egress — tcp:443 to whitelist + tcp:3306 to mysql-sg only ✓"
  else
    while IFS= read -r line; do
      case "$line" in
        MISSING:*)       fail "app-sg egress: ${line#MISSING: }" ;;
        MISSING_CIDRS:*) fail "app-sg application server egress whitelist missing: ${line#MISSING_CIDRS: }" ;;
        EXTRA_CIDRS:*)   fail "app-sg application server egress whitelist unauthorized CIDRs: ${line#EXTRA_CIDRS: }" ;;
        EXTRA:*)         warn "app-sg egress extra rule (MiniStack?): ${line#EXTRA: }" ;;
        *)               warn "app-sg egress: $line" ;;
      esac
    done <<< "$RESULT"
  fi
else
  fail "app-sg egress: mysql-sg not found — cannot verify port 3306 rule"
fi

# mysql-sg: egress must be loopback 127.0.0.1/32 only.
#
# Why 127.0.0.1/32 instead of simply removing all egress rules?
#   AWS automatically adds a default allow-all egress rule (0.0.0.0/0) to every
#   new security group. The Terraform AWS provider only removes this default when
#   it manages at least one explicit egress block — with zero egress blocks the
#   provider treats egress as unmanaged and leaves the AWS default allow-all in
#   place. The loopback placeholder (127.0.0.1/32) forces Terraform to declare
#   ownership of the egress rule set, which causes the AWS default to be evicted.
#   127.0.0.1/32 (loopback) is unreachable from EC2 network interfaces — no real
#   traffic can egress. On real AWS this produces effective deny-all egress.
#   On MiniStack the default allow-all is re-injected regardless; this appears
#   as a warning below and is a known MiniStack fidelity gap.
MYSQL_LOOP=$(python3 -c "
import json, sys
sgs = json.loads(sys.argv[1]).get('SecurityGroups', [])
for sg in sgs:
    if sg['GroupName'] != 'mysql-sg': continue
    for p in sg.get('IpPermissionsEgress', []):
        for r in p.get('IpRanges', []):
            if r.get('CidrIp') == '127.0.0.1/32': print('yes'); sys.exit(0)
print('no')
" "$SG_JSON")

[ "$MYSQL_LOOP" = "yes" ] \
  && ok   "mysql-sg egress — 127.0.0.1/32 loopback placeholder present ✓ (deny-all effective on real AWS)" \
  || fail "mysql-sg egress — loopback placeholder missing (Terraform cannot evict AWS default allow-all)"

MYSQL_ALLOW_ALL=$(python3 -c "
import json, sys
sgs = json.loads(sys.argv[1]).get('SecurityGroups', [])
for sg in sgs:
    if sg['GroupName'] != 'mysql-sg': continue
    for p in sg.get('IpPermissionsEgress', []):
        if p.get('IpProtocol') == '-1':
            for r in p.get('IpRanges', []):
                if r.get('CidrIp') == '0.0.0.0/0': print('yes'); sys.exit(0)
print('no')
" "$SG_JSON")

[ "$MYSQL_ALLOW_ALL" = "no" ] \
  && ok   "mysql-sg egress — no allow-all 0.0.0.0/0 ✓" \
  || warn "mysql-sg egress — allow-all present (MiniStack injects default regardless of config)"

# ── Application Server Egress Whitelist ───────────────────────────────────────

echo ""
echo "── Application Server Egress Whitelist ─────────────────────────"
echo "  ℹ️   Checks that app-sg egress CIDRs exactly match declared app_egress_cidrs."
echo "       Source: fixed_state/terraform.tfvars (fallback: variables.tf defaults)."

CIDR_RESULT=$(app_egress_full_check "$SG_JSON" "${MYSQL_SG_ID:-none}" "$EXPECTED_EGRESS_CIDRS")
if [ "$CIDR_RESULT" = "ok" ]; then
  ok "app-sg egress CIDRs exactly match whitelist: $EXPECTED_EGRESS_CIDRS"
else
  while IFS= read -r line; do
    case "$line" in
      MISSING_CIDRS:*) fail "whitelist CIDRs missing from egress: ${line#MISSING_CIDRS: }" ;;
      EXTRA_CIDRS:*)   fail "unauthorized CIDRs in egress beyond whitelist: ${line#EXTRA_CIDRS: }" ;;
      MISSING:*)       warn "app-sg egress: ${line#MISSING: }" ;;
      EXTRA:*)         warn "extra egress rule (MiniStack default?): ${line#EXTRA: }" ;;
      *)               warn "$line" ;;
    esac
  done <<< "$CIDR_RESULT"
fi
warn "FQDN destination enforcement not verified — requires Network Firewall (real AWS only)"
echo "       run: make test-firewall  INSTANCE_ID=i-xxx  AWS_REGION=us-east-1"

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL + WARN))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  RESULTS                                                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ✅  Passed : %2d%-39s║\n" "$PASS" ""
printf "║  ❌  Failed : %2d%-39s║\n" "$FAIL" ""
printf "║  ⚠️   Warned : %2d  (incl. MiniStack fidelity gaps)%-5s║\n" "$WARN" ""
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Total  : %2d checks%-34s║\n" "$TOTAL" ""
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

[ "$FAIL" -gt 0 ] && exit 1 || exit 0

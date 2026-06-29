#!/usr/bin/env bash
# setup.sh — Check and install all required tools for altium_poc
# Creates an isolated .venv for Python tools.
# Uses tfenv to install and pin Terraform.
#
# Run from project root: bash setup.sh
# Activate venv after:   source .venv/bin/activate

set -euo pipefail

PASS=0
FAIL=0
WARN=0

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/.venv"
TF_VERSION="1.15.7"

# ── Helpers ───────────────────────────────────────────────────────────────────

ok()   { echo "✅ $*"; PASS=$((PASS + 1)); }
fail() { echo "❌ $*"; FAIL=$((FAIL + 1)); }
warn() { echo "⚠️  $*"; WARN=$((WARN + 1)); }
info() { echo "   $*"; }
step() { echo ""; echo "── $* ──────────────────────────────────────"; }

# ── Header ────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  altium_poc — Setup & Tooling Validation ║"
echo "╚══════════════════════════════════════════╝"

# ── Docker ────────────────────────────────────────────────────────────────────

step "Docker"
if command -v docker &>/dev/null; then
  ok "Docker installed: $(docker --version | head -1)"
  if docker info &>/dev/null 2>&1; then
    ok "Docker daemon running"
  else
    fail "Docker daemon not running — start Docker Desktop"
  fi
else
  fail "Docker not installed — https://docs.docker.com/desktop/install/mac-install/"
fi

# ── Homebrew ──────────────────────────────────────────────────────────────────

step "Homebrew"
if command -v brew &>/dev/null; then
  ok "Homebrew: $(brew --version | head -1)"
else
  fail "Homebrew not found — required for tfenv"
  info "Install: https://brew.sh"
  echo ""
  echo "Cannot continue without Homebrew. Install it and re-run."
  exit 1
fi

# ── tfenv + Terraform ─────────────────────────────────────────────────────────

step "tfenv"
if command -v tfenv &>/dev/null; then
  ok "tfenv: $(tfenv --version 2>/dev/null | head -1)"
else
  info "tfenv not found — installing via brew..."
  brew install tfenv
  ok "tfenv installed: $(tfenv --version 2>/dev/null | head -1)"
fi

step "Terraform $TF_VERSION (via tfenv)"
if tfenv list 2>/dev/null | grep -qF "$TF_VERSION"; then
  ok "Terraform $TF_VERSION already installed"
else
  info "Installing Terraform $TF_VERSION..."
  tfenv install "$TF_VERSION"
  ok "Terraform $TF_VERSION installed"
fi

# Pin version for this project
echo "$TF_VERSION" > "$PROJECT_DIR/.terraform-version"
ok ".terraform-version pinned to $TF_VERSION"

tfenv use "$TF_VERSION"
ACTIVE_TF=$(terraform --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ "$ACTIVE_TF" = "$TF_VERSION" ]; then
  ok "Terraform active: v$ACTIVE_TF"
else
  warn "Active Terraform is v$ACTIVE_TF, expected $TF_VERSION"
  info "Try: tfenv use $TF_VERSION"
fi

# ── Python ────────────────────────────────────────────────────────────────────

step "Python3 (system)"
if command -v python3 &>/dev/null; then
  ok "Python3: $(python3 --version)"
else
  fail "Python3 not installed — required for virtualenv"
  echo ""
  echo "Cannot continue without Python3. Install it and re-run."
  exit 1
fi

# ── Virtualenv ────────────────────────────────────────────────────────────────

step "Virtualenv (.venv)"
if [ -d "$VENV_DIR" ]; then
  ok "Virtualenv already exists: $VENV_DIR"
else
  info "Creating virtualenv at $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
  ok "Virtualenv created: $VENV_DIR"
fi

VENV_PIP="$VENV_DIR/bin/pip"
VENV_PYTHON="$VENV_DIR/bin/python"

info "Upgrading pip inside venv..."
"$VENV_PYTHON" -m pip install --upgrade pip --quiet
ok "pip: $("$VENV_PIP" --version | head -1)"

# ── Python tools (inside venv) ────────────────────────────────────────────────

install_tool() {
  local name="$1"
  local package="$2"
  local binary="$VENV_DIR/bin/$3"

  if [ -f "$binary" ]; then
    ok "$name already installed: $($binary --version 2>/dev/null | head -1)"
  else
    info "Installing $name..."
    "$VENV_PIP" install "$package" --quiet
    if [ -f "$binary" ]; then
      ok "$name installed: $($binary --version 2>/dev/null | head -1)"
    else
      fail "$name installed but binary not found at $binary"
    fi
  fi
}

step "Python tools (into .venv)"
# terraform-local pinned to 0.25.0 — 0.26.0+ requires SerializationOptions
# from python-hcl2 which is not yet available for Python 3.13
install_tool "tflocal"  "terraform-local==0.25.0" "tflocal"
install_tool "awslocal" "awscli-local"             "awslocal"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
printf  "║  Results: %2d passed  %2d warned  %2d failed  ║\n" "$PASS" "$WARN" "$FAIL"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Fix the ❌ items above before proceeding."
  exit 1
fi

if [ "$WARN" -gt 0 ]; then
  echo "⚠️  Warnings present — review items above."
  echo ""
fi

echo "Next step — activate the virtualenv:"
echo ""
echo "  source .venv/bin/activate"
echo ""
echo "Then confirm tools are on PATH:"
echo ""
echo "  terraform --version   # should show $TF_VERSION"
echo "  tflocal --version"
echo "  awslocal --version"
echo ""
echo "Proceed to: make up && make initial"

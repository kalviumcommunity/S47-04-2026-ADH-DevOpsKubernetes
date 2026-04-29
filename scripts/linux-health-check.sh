#!/bin/bash
# ============================================================================
# Linux Health Check Script for DevOps
# ============================================================================
# Purpose: Verify system state before deployments or CI/CD pipeline runs.
# Demonstrates practical use of filesystem, permissions, process, and
# network inspection commands in a DevOps context.
#
# Usage:
#   chmod +x linux-health-check.sh
#   ./linux-health-check.sh
#
# Intended to run on CI runners, build agents, or deployment targets
# to confirm the environment is ready before critical operations.
# ============================================================================

set -euo pipefail

# ── Colors for output readability ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PASS=0
WARN=0
FAIL=0

pass()  { echo -e "  ${GREEN}✔ PASS${NC}  $1"; ((PASS++)); }
warn()  { echo -e "  ${YELLOW}⚠ WARN${NC}  $1"; ((WARN++)); }
fail()  { echo -e "  ${RED}✖ FAIL${NC}  $1"; ((FAIL++)); }
header(){ echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ══════════════════════════════════════════════════════════════════════════════
# 1. SYSTEM INFORMATION
# ══════════════════════════════════════════════════════════════════════════════
header "System Information"

echo "  Hostname : $(hostname)"
echo "  Kernel   : $(uname -r)"
echo "  OS       : $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo 'Unknown')"
echo "  User     : $(whoami) (uid=$(id -u), gid=$(id -g))"
echo "  Date     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Uptime   : $(uptime -p 2>/dev/null || uptime)"

# ══════════════════════════════════════════════════════════════════════════════
# 2. FILESYSTEM CHECKS
# ══════════════════════════════════════════════════════════════════════════════
header "Filesystem Health"

# Check disk usage on critical mount points
check_disk() {
    local mount_point=$1
    local threshold=${2:-85}

    if df "$mount_point" &>/dev/null; then
        local usage
        usage=$(df "$mount_point" --output=pcent | tail -1 | tr -d ' %')
        if [ "$usage" -ge "$threshold" ]; then
            fail "$mount_point is ${usage}% full (threshold: ${threshold}%)"
        elif [ "$usage" -ge $((threshold - 10)) ]; then
            warn "$mount_point is ${usage}% full — approaching threshold"
        else
            pass "$mount_point is ${usage}% full"
        fi
    else
        warn "$mount_point — mount point not found"
    fi
}

check_disk "/" 85
check_disk "/tmp" 80
check_disk "/var" 85

# Check /tmp is writable (CI runners need this)
if [ -w /tmp ]; then
    pass "/tmp is writable"
else
    fail "/tmp is NOT writable — builds will fail"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. PERMISSION & OWNERSHIP CHECKS
# ══════════════════════════════════════════════════════════════════════════════
header "Permission & Ownership Checks"

# Check if common secret files have safe permissions
check_secret_perms() {
    local file=$1
    if [ -f "$file" ]; then
        local perms
        perms=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)
        if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
            pass "$file has secure permissions ($perms)"
        else
            warn "$file has permissions $perms — should be 600 or 400"
        fi
    fi
}

# Check common secret file locations
check_secret_perms "$HOME/.ssh/id_rsa"
check_secret_perms "$HOME/.ssh/id_ed25519"

# Check if current user can access Docker socket
if [ -S /var/run/docker.sock ]; then
    if [ -r /var/run/docker.sock ] && [ -w /var/run/docker.sock ]; then
        pass "Docker socket is accessible"
    else
        fail "Docker socket exists but is not accessible — check group membership"
    fi
else
    warn "Docker socket not found at /var/run/docker.sock"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. REQUIRED TOOLS CHECK
# ══════════════════════════════════════════════════════════════════════════════
header "Required Tools"

check_tool() {
    local tool=$1
    local required=${2:-false}

    if command -v "$tool" &>/dev/null; then
        local version
        version=$("$tool" --version 2>&1 | head -1)
        pass "$tool → $version"
    else
        if [ "$required" = "true" ]; then
            fail "$tool is NOT installed (required)"
        else
            warn "$tool is not installed (optional)"
        fi
    fi
}

check_tool "git" "true"
check_tool "docker" "true"
check_tool "node" "false"
check_tool "npm" "false"
check_tool "kubectl" "false"
check_tool "curl" "true"

# ══════════════════════════════════════════════════════════════════════════════
# 5. PROCESS INSPECTION
# ══════════════════════════════════════════════════════════════════════════════
header "Process Inspection"

# Total running processes
proc_count=$(ps aux --no-heading 2>/dev/null | wc -l || ps aux | tail -n +2 | wc -l)
echo "  Running processes: $proc_count"

# Check for zombie processes (processes that are done but not reaped)
zombie_count=$(ps aux 2>/dev/null | awk '$8 ~ /^Z/ {count++} END {print count+0}')
if [ "$zombie_count" -gt 0 ]; then
    warn "$zombie_count zombie process(es) detected"
else
    pass "No zombie processes"
fi

# Check if Docker daemon is running
if pgrep -x "dockerd" &>/dev/null || systemctl is-active docker &>/dev/null 2>&1; then
    pass "Docker daemon is running"
else
    warn "Docker daemon is not running"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. NETWORK INSPECTION
# ══════════════════════════════════════════════════════════════════════════════
header "Network Inspection"

# Check for internet connectivity
if curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
    pass "Internet connectivity (github.com reachable)"
else
    fail "No internet connectivity — cannot reach github.com"
fi

# Check DNS resolution
if nslookup registry.hub.docker.com &>/dev/null 2>&1 || host registry.hub.docker.com &>/dev/null 2>&1; then
    pass "DNS resolution working (Docker Hub resolved)"
else
    warn "DNS resolution may have issues"
fi

# Show listening ports (top 10)
echo ""
echo "  Active listeners (top 10):"
if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | head -11 | while IFS= read -r line; do
        echo "    $line"
    done
elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | head -11 | while IFS= read -r line; do
        echo "    $line"
    done
else
    echo "    (ss/netstat not available)"
fi

# Check for common port conflicts
check_port_free() {
    local port=$1
    local service=$2
    if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        warn "Port $port ($service) is already in use"
    else
        pass "Port $port ($service) is available"
    fi
}

check_port_free 3001 "backend API"
check_port_free 5173 "frontend dev server"
check_port_free 5432 "PostgreSQL"
check_port_free 27017 "MongoDB"

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
header "Summary"

echo -e "  ${GREEN}Passed: $PASS${NC}"
echo -e "  ${YELLOW}Warnings: $WARN${NC}"
echo -e "  ${RED}Failed: $FAIL${NC}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}⚠ Environment has $FAIL issue(s) that should be resolved before proceeding.${NC}"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "  ${YELLOW}Environment is ready with $WARN warning(s).${NC}"
    exit 0
else
    echo -e "  ${GREEN}Environment is fully ready. All checks passed!${NC}"
    exit 0
fi

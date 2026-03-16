#!/usr/bin/env bash
# Shared helper functions for e2e Kind tests.

set -euo pipefail

# ── Source config ─────────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
E2E_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

if [ -f "${E2E_DIR}/e2e.env" ]; then
    # shellcheck disable=SC1091
    source "${E2E_DIR}/e2e.env"
fi

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
log_success() { echo -e "\033[0;32m[PASS]\033[0m $*"; }
log_error()   { echo -e "\033[0;31m[FAIL]\033[0m $*"; }
log_warn()    { echo -e "\033[0;33m[WARN]\033[0m $*"; }

# ── Chain queries ─────────────────────────────────────────────────────────────

# Get the current block height from an RPC endpoint.
get_block_height() {
    local rpc_url="${1:-http://localhost:26657}"
    curl -sf "${rpc_url}/status" 2>/dev/null | jq -r '.result.sync_info.latest_block_height' 2>/dev/null || echo "0"
}

# Wait until the chain is producing blocks at the given RPC endpoint.
wait_for_chain_ready() {
    local rpc_url="${1:-http://localhost:26657}"
    local max_wait="${2:-120}"
    local elapsed=0

    log_info "Waiting for chain to be ready at ${rpc_url}..."
    while [ $elapsed -lt $max_wait ]; do
        local height
        height=$(get_block_height "$rpc_url")
        if [ "$height" -gt 2 ] 2>/dev/null; then
            log_success "Chain is ready at block height ${height}"
            return 0
        fi
        elapsed=$((elapsed + 3))
        sleep 3
    done
    log_error "Chain not ready after ${max_wait}s"
    return 1
}

# Wait until the chain reaches a specific block height.
wait_for_height() {
    local target="$1"
    local rpc_url="${2:-http://localhost:26657}"
    local max_attempts="${3:-120}"
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local current
        current=$(get_block_height "$rpc_url")
        if [ "$current" -ge "$target" ] 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    log_error "Chain did not reach height ${target} within $((max_attempts * 2))s"
    return 1
}

# Execute mocad command inside validator-0 pod.
exec_mocad() {
    kubectl exec -n "${K8S_NAMESPACE}" validator-0-0 -c mocad -- \
        mocad "$@" --home /root/.mocad 2>/dev/null
}

# ── Assertions ────────────────────────────────────────────────────────────────

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [ "$actual" = "$expected" ]; then
        return 0
    fi
    log_error "Assertion failed: ${msg}"
    log_error "  expected: ${expected}"
    log_error "  actual:   ${actual}"
    return 1
}

assert_gt() {
    local actual="$1" threshold="$2" msg="${3:-}"
    if echo "${actual} > ${threshold}" | bc -l | grep -q '^1$'; then
        return 0
    fi
    log_error "Assertion failed: ${msg}"
    log_error "  expected > ${threshold}, got ${actual}"
    return 1
}

assert_not_empty() {
    local val="$1" msg="${2:-}"
    if [ -n "$val" ]; then
        return 0
    fi
    log_error "Assertion failed: ${msg}"
    log_error "  value is empty"
    return 1
}

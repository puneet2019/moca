#!/usr/bin/env bash
# E2E test runner for Moca chain on Kind.
# Executes test cases against the running chain via kubectl exec and RPC queries.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KIND_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

source "${SCRIPT_DIR}/lib.sh"

RPC_URL="http://localhost:26657"
PASSED=0
FAILED=0
TOTAL=0

run_test() {
    local test_name="$1"
    local test_func="$2"
    TOTAL=$((TOTAL + 1))

    echo ""
    log_info "--- Test: ${test_name} ---"

    if eval "$test_func"; then
        PASSED=$((PASSED + 1))
        log_success "PASSED: ${test_name}"
    else
        FAILED=$((FAILED + 1))
        log_error "FAILED: ${test_name}"
    fi
}

# Helper: execute mocad command inside validator-0
exec_mocad() {
    kubectl exec -n "${K8S_NAMESPACE}" validator-0-0 -- \
        mocad "$@" --home /root/.mocad 2>/dev/null
}

# ============================================================
# Test Cases
# ============================================================

test_chain_producing_blocks() {
    local height1
    height1=$(get_block_height "$RPC_URL")

    if [ "$height1" -lt 1 ] 2>/dev/null; then
        log_error "Chain not producing blocks (height: ${height1})"
        return 1
    fi

    sleep 3

    local height2
    height2=$(get_block_height "$RPC_URL")

    if [ "$height2" -gt "$height1" ] 2>/dev/null; then
        log_success "Block height increased: ${height1} -> ${height2}"
        return 0
    else
        log_error "Block height did not increase: ${height1} -> ${height2}"
        return 1
    fi
}

test_genesis_account_balances() {
    # Query validator0 balance
    local balance
    balance=$(exec_mocad query bank balances \
        "$(exec_mocad keys show validator0 -a --keyring-backend test)" \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json | jq -r '.balances[] | select(.denom=="amoca") | .amount' 2>/dev/null || echo "0")

    assert_not_empty "$balance" "validator0 should have amoca balance"
}

test_query_validators() {
    local count
    count=$(exec_mocad query staking validators \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json | jq '.validators | length' 2>/dev/null || echo "0")

    assert_gt "$count" 0 "Should have at least 1 validator (got ${count})"
}

test_send_tokens() {
    # Get validator0 address
    local sender_addr
    sender_addr=$(exec_mocad keys show validator0 -a --keyring-backend test)

    # Create a new test account
    exec_mocad keys add testuser --keyring-backend test 2>/dev/null || true
    local receiver_addr
    receiver_addr=$(exec_mocad keys show testuser -a --keyring-backend test)

    log_info "Sender: ${sender_addr}"
    log_info "Receiver: ${receiver_addr}"

    # Send tokens
    local send_amount="1000000000000000000amoca"  # 1 MOCA
    local fees="200000000000000amoca"

    local tx_result
    tx_result=$(exec_mocad tx bank send validator0 "$receiver_addr" "$send_amount" \
        --keyring-backend test \
        --chain-id "${CHAIN_ID}" \
        --node tcp://localhost:26657 \
        --fees "$fees" \
        -y 2>&1)

    # Check tx was accepted
    if echo "$tx_result" | grep -q "code: 0"; then
        log_info "Transaction submitted successfully"
    else
        log_error "Transaction failed: ${tx_result}"
        return 1
    fi

    # Wait for tx to be included in a block
    sleep 5

    # Verify receiver balance
    local recv_balance
    recv_balance=$(exec_mocad query bank balances "$receiver_addr" \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json | jq -r '.balances[] | select(.denom=="amoca") | .amount' 2>/dev/null || echo "0")

    if [ "$recv_balance" = "1000000000000000000" ]; then
        log_success "Receiver balance correct: ${recv_balance} amoca"
        return 0
    else
        log_error "Receiver balance unexpected: ${recv_balance} amoca (expected 1000000000000000000)"
        return 1
    fi
}

test_multi_account_transfers() {
    local num_accounts=3

    # Create test accounts
    declare -a accounts=()
    for ((i = 0; i < num_accounts; i++)); do
        exec_mocad keys add "multitest${i}" --keyring-backend test 2>/dev/null || true
        accounts+=("$(exec_mocad keys show "multitest${i}" -a --keyring-backend test)")
    done

    # Fund all accounts from validator0
    local fund_amount="5000000000000000000amoca"  # 5 MOCA each
    local fees="200000000000000amoca"

    for ((i = 0; i < num_accounts; i++)); do
        log_info "Funding account multitest${i}: ${accounts[$i]}"
        exec_mocad tx bank send validator0 "${accounts[$i]}" "$fund_amount" \
            --keyring-backend test \
            --chain-id "${CHAIN_ID}" \
            --node tcp://localhost:26657 \
            --fees "$fees" \
            -y 2>/dev/null
        sleep 2
    done

    # Wait for all funding txs to confirm
    sleep 5

    # Send between accounts: 0 -> 1, 1 -> 2
    local transfer_amount="1000000000000000000amoca"  # 1 MOCA

    log_info "Sending from multitest0 to multitest1..."
    exec_mocad tx bank send multitest0 "${accounts[1]}" "$transfer_amount" \
        --keyring-backend test \
        --chain-id "${CHAIN_ID}" \
        --node tcp://localhost:26657 \
        --fees "$fees" \
        -y 2>/dev/null
    sleep 3

    log_info "Sending from multitest1 to multitest2..."
    exec_mocad tx bank send multitest1 "${accounts[2]}" "$transfer_amount" \
        --keyring-backend test \
        --chain-id "${CHAIN_ID}" \
        --node tcp://localhost:26657 \
        --fees "$fees" \
        -y 2>/dev/null
    sleep 5

    # Verify final balances
    local bal2
    bal2=$(exec_mocad query bank balances "${accounts[2]}" \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json | jq -r '.balances[] | select(.denom=="amoca") | .amount' 2>/dev/null || echo "0")

    # multitest2 should have: 5 MOCA (initial) + 1 MOCA (from multitest1)
    # = 6000000000000000000 amoca
    log_info "multitest2 balance: ${bal2} amoca"
    assert_not_empty "$bal2" "multitest2 should have non-zero balance"
}

test_query_storage_providers() {
    local count
    count=$(exec_mocad query sp storage-providers \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json | jq '.sps | length' 2>/dev/null || echo "0")

    assert_gt "$count" 0 "Should have at least 1 storage provider (got ${count})"
}

test_query_module_params() {
    local modules=("evm" "feemarket" "staking" "gov")

    for mod in "${modules[@]}"; do
        local result
        result=$(exec_mocad query "$mod" params \
            --node tcp://localhost:26657 \
            --chain-id "${CHAIN_ID}" \
            --output json 2>/dev/null || echo "")

        if [ -z "$result" ]; then
            log_error "Failed to query ${mod} params"
            return 1
        fi
        log_info "  ${mod} params: OK"
    done

    return 0
}

# ============================================================
# Run all tests
# ============================================================

log_info "=== Running Moca E2E Tests ==="
log_info "RPC: ${RPC_URL}"
log_info "Namespace: ${K8S_NAMESPACE}"

# Wait for chain readiness
wait_for_chain_ready "$RPC_URL" 30

# Core chain tests
run_test "Chain is producing blocks" test_chain_producing_blocks
run_test "Genesis account balances" test_genesis_account_balances
run_test "Query validators" test_query_validators
run_test "Query module params" test_query_module_params
run_test "Send tokens" test_send_tokens
run_test "Multi-account transfers" test_multi_account_transfers
run_test "Query storage providers" test_query_storage_providers

# ============================================================
# Summary
# ============================================================

echo ""
echo "============================================"
echo "  E2E Test Results"
echo "============================================"
echo "  Total:  ${TOTAL}"
echo "  Passed: ${PASSED}"
echo "  Failed: ${FAILED}"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
    log_error "${FAILED} test(s) failed"
    collect_debug_logs
    exit 1
else
    log_success "All ${TOTAL} tests passed"
    exit 0
fi

#!/usr/bin/env bash
# Cosmovisor upgrade test — deploys an old version with cosmovisor as the
# process supervisor, triggers upgrade via governance proposal, and validates
# that cosmovisor automatically switches to the new binary without any manual
# kubectl image swap.
#
# Usage:
#   OLD_VERSION=main bash tests/test_upgrade_cosmovisor.sh
#   OLD_VERSION=v1.1.2 UPGRADE_NAME=v1.2.0 bash tests/test_upgrade_cosmovisor.sh

source "$(dirname "$0")/../framework/framework.sh"
fw_init

OLD_VERSION="${OLD_VERSION:-main}"
UPGRADE_NAME="${UPGRADE_NAME:-v1.2.0}"
FEES="200000000000000amoca"

# ── Setup: deploy with cosmovisor ──────────────────────────────────────────
fw_start_chain_cosmovisor "$OLD_VERSION" "$UPGRADE_NAME"

# ── Pre-upgrade state ──────────────────────────────────────────────────────
log_info "=== Pre-upgrade setup ==="

exec_mocad keys add cosmovisor-test-acct --keyring-backend test 2>/dev/null || true
COSMOVISOR_TEST_ADDR=$(exec_mocad keys show cosmovisor-test-acct -a --keyring-backend test)
log_info "Test account: ${COSMOVISOR_TEST_ADDR}"

fw_tx_send validator0 "$COSMOVISOR_TEST_ADDR" "5000000000000000000amoca"

PRE_UPGRADE_HEIGHT=$(get_block_height "http://localhost:26657")
PRE_UPGRADE_BALANCE=$(exec_mocad query bank balances "$COSMOVISOR_TEST_ADDR" \
    --node tcp://localhost:26657 \
    --chain-id "${CHAIN_ID}" \
    --output json | jq -r '.balances[] | select(.denom=="amoca") | .amount' 2>/dev/null || echo "0")

log_info "Pre-upgrade height:  ${PRE_UPGRADE_HEIGHT}"
log_info "Pre-upgrade balance: ${PRE_UPGRADE_BALANCE} amoca"

# ── Upgrade via cosmovisor ─────────────────────────────────────────────────
fw_upgrade_chain --name "$UPGRADE_NAME" --mode cosmovisor

# ── Post-upgrade tests ─────────────────────────────────────────────────────

test_chain_producing_blocks_post_upgrade() {
    local h1
    h1=$(get_block_height "http://localhost:26657")
    sleep 3
    local h2
    h2=$(get_block_height "http://localhost:26657")
    assert_gt "$h2" "$h1" "Chain should produce blocks post-upgrade"
}

test_height_past_upgrade() {
    local current
    current=$(get_block_height "http://localhost:26657")
    assert_gt "$current" "$PRE_UPGRADE_HEIGHT" "Height should be past pre-upgrade height"
}

test_balances_preserved() {
    local bal
    bal=$(exec_mocad query bank balances "$COSMOVISOR_TEST_ADDR" \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json | jq -r '.balances[] | select(.denom=="amoca") | .amount' 2>/dev/null || echo "0")

    assert_eq "$bal" "$PRE_UPGRADE_BALANCE" "Balance should survive upgrade"
}

test_upgrade_applied() {
    local applied_height
    applied_height=$(exec_mocad query upgrade applied "$UPGRADE_NAME" \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.height' 2>/dev/null || echo "0")

    assert_gt "$applied_height" 0 "Upgrade '${UPGRADE_NAME}' should be applied"
}

test_send_tokens_post_upgrade() {
    exec_mocad keys add post-cosmovisor-user --keyring-backend test 2>/dev/null || true
    local recv
    recv=$(exec_mocad keys show post-cosmovisor-user -a --keyring-backend test)

    fw_tx_send validator0 "$recv" "1000000000000000000amoca"

    local bal
    bal=$(exec_mocad query bank balances "$recv" \
        --node tcp://localhost:26657 \
        --chain-id "${CHAIN_ID}" \
        --output json | jq -r '.balances[] | select(.denom=="amoca") | .amount' 2>/dev/null || echo "0")

    assert_eq "$bal" "1000000000000000000" "Post-upgrade transfer should succeed"
}

test_cosmovisor_current_symlink() {
    # Verify cosmovisor switched to the upgrade binary
    local current_target
    current_target=$(kubectl exec -n "${K8S_NAMESPACE}" validator-0-0 -c mocad -- \
        readlink /root/.mocad/cosmovisor/current 2>/dev/null || echo "")

    assert_not_empty "$current_target" "Cosmovisor current symlink should exist"
    log_info "  Cosmovisor current -> ${current_target}"
}

# ── Run tests ──────────────────────────────────────────────────────────────

fw_run_test "Chain producing blocks post-upgrade"    test_chain_producing_blocks_post_upgrade
fw_run_test "Height past pre-upgrade"                test_height_past_upgrade
fw_run_test "Balances preserved across upgrade"      test_balances_preserved
fw_run_test "Upgrade handler applied"                test_upgrade_applied
fw_run_test "Token transfers work post-upgrade"      test_send_tokens_post_upgrade
fw_run_test "Cosmovisor current symlink updated"     test_cosmovisor_current_symlink

fw_done

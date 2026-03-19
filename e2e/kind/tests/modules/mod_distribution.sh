#!/usr/bin/env bash
# Module: distribution — reward withdrawal before and after upgrade.

distribution_pre_upgrade() {
    fw_wait_blocks 5
    for ((i = 0; i < NUM_VALIDATORS; i++)); do
        log_info "  [distribution] withdraw rewards: validator${i}"
        cosmos_tx_on "$i" distribution withdraw-rewards "${VAL_OPERS[$i]}" --from "validator${i}"
    done
}

distribution_post_upgrade() {
    fw_wait_blocks 5
    for ((i = 0; i < NUM_VALIDATORS; i++)); do
        log_info "  [distribution] post withdraw rewards: validator${i}"
        cosmos_tx_on "$i" distribution withdraw-rewards "${VAL_OPERS[$i]}" --from "validator${i}"
    done
}

_distribution_test_rewards_available() {
    local rewards; rewards=$(exec_mocad query distribution rewards \
        "$(exec_mocad keys show validator0 -a --keyring-backend test)" \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.total[] | select(.denom=="amoca") | .amount // "0"') || true
    assert_not_empty "$rewards" "Validator0 should have pending rewards post-upgrade"
}

register_pre_upgrade  distribution_pre_upgrade
register_post_upgrade distribution_post_upgrade
register_test "Distribution rewards available" _distribution_test_rewards_available

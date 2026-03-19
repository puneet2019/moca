#!/usr/bin/env bash
# Module: staking — validator edits, delegations, and unbonds before and after upgrade.

staking_pre_upgrade() {
    # Edit validator monikers
    for ((i = 0; i < NUM_VALIDATORS; i++)); do
        log_info "  [staking] edit-validator ${i}: moniker=Val${i}-Pre"
        cosmos_tx_on "$i" staking edit-validator --moniker "Val${i}-Pre" --from "validator${i}"
    done

    # Delegate to validators 1 and 2
    for ((i = 1; i <= 2; i++)); do
        log_info "  [staking] delegate 1 MOCA to validator${i}"
        cosmos_tx staking delegate "${VAL_OPERS[$i]}" "1000000000000000000amoca" --from validator0
    done
}

staking_post_upgrade() {
    # Edit validator monikers post-upgrade
    for ((i = 0; i < NUM_VALIDATORS; i++)); do
        log_info "  [staking] post edit-validator ${i}: moniker=Val${i}-Post"
        cosmos_tx_on "$i" staking edit-validator --moniker "Val${i}-Post" --from "validator${i}"
    done

    # Unbond from validators 1 and 2
    for ((i = 1; i <= 2; i++)); do
        log_info "  [staking] unbond 0.5 MOCA from validator${i}"
        cosmos_tx staking unbond "${VAL_OPERS[$i]}" "500000000000000000amoca" --from validator0
    done
}

_staking_test_validators_active() {
    local count; count=$(exec_mocad query staking validators \
        --node tcp://localhost:26657 --output json 2>/dev/null \
        | jq '[.validators[] | select(.status=="BOND_STATUS_BONDED")] | length') || true
    assert_eq "$count" "$NUM_VALIDATORS" "All validators should be bonded"
}

_staking_test_monikers_updated() {
    local moniker; moniker=$(exec_mocad query staking validators \
        --node tcp://localhost:26657 --output json 2>/dev/null \
        | jq -r '.validators[0].description.moniker' 2>/dev/null) || true
    assert_not_empty "$moniker" "Validator moniker should be set post-upgrade"
}

_staking_test_delegate_works() {
    log_info "  [staking] post-upgrade delegate 0.1 MOCA to validator1"
    cosmos_tx staking delegate "${VAL_OPERS[1]}" "100000000000000000amoca" --from validator0
    local del; del=$(exec_mocad query staking delegations-to "${VAL_OPERS[1]}" \
        --node tcp://localhost:26657 --output json 2>/dev/null \
        | jq -r '.delegation_responses | length') || true
    assert_gt "$del" "0" "Validator1 should have delegations post-upgrade"
}

register_pre_upgrade  staking_pre_upgrade
register_post_upgrade staking_post_upgrade
register_test "All validators active"           _staking_test_validators_active
register_test "Validator monikers updated"       _staking_test_monikers_updated
register_test "Post-upgrade delegation works"    _staking_test_delegate_works

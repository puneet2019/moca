#!/usr/bin/env bash
# Module: bank — Cosmos bank send transactions before and after upgrade.

_BANK_ADDRS=()
_BANK_PRE_BAL=""

bank_pre_upgrade() {
    log_info "[bank] Creating test accounts..."
    for ((i = 0; i < 10; i++)); do
        exec_mocad keys add "bank-test-${i}" --keyring-backend test 2>/dev/null || true
        _BANK_ADDRS+=("$(exec_mocad keys show "bank-test-${i}" -a --keyring-backend test)")
    done

    local amounts=("1000000000000000000" "2000000000000000000" "500000000000000000"
                   "3000000000000000000" "100000000000000000"  "750000000000000000"
                   "4000000000000000000" "250000000000000000"  "1500000000000000000"
                   "5000000000000000000" "800000000000000000"  "1200000000000000000"
                   "600000000000000000"  "900000000000000000"  "350000000000000000")
    for ((i = 0; i < 15; i++)); do
        log_info "  [bank] send $((i+1))/15"
        cosmos_tx bank send validator0 "${_BANK_ADDRS[$((i % 10))]}" "${amounts[$i]}amoca" --from validator0
    done

    _BANK_PRE_BAL=$(exec_mocad query bank balances "${_BANK_ADDRS[0]}" \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="amoca") | .amount // "0"') || true
    log_info "[bank] Pre-upgrade balance[0]: ${_BANK_PRE_BAL}"
}

bank_post_upgrade() {
    local amounts=("1100000000000000000" "2200000000000000000" "550000000000000000"
                   "3300000000000000000" "110000000000000000"  "770000000000000000"
                   "4400000000000000000" "275000000000000000"  "1650000000000000000"
                   "5500000000000000000" "880000000000000000"  "1320000000000000000"
                   "660000000000000000"  "990000000000000000"  "385000000000000000")
    for ((i = 0; i < 15; i++)); do
        log_info "  [bank] post send $((i+1))/15"
        cosmos_tx bank send validator0 "${_BANK_ADDRS[$((i % 10))]}" "${amounts[$i]}amoca" --from validator0
    done
}

_bank_test_balances_preserved() {
    local bal; bal=$(exec_mocad query bank balances "${_BANK_ADDRS[0]}" \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="amoca") | .amount // "0"') || true
    assert_gt "$bal" "0" "Test account should have balance post-upgrade"
}

_bank_test_send_works() {
    exec_mocad keys add bank-final-recv --keyring-backend test 2>/dev/null || true
    local recv; recv=$(exec_mocad keys show bank-final-recv -a --keyring-backend test)
    fw_tx_send validator0 "$recv" "1000000000000000000amoca"
    local bal; bal=$(exec_mocad query bank balances "$recv" \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="amoca") | .amount // "0"') || true
    assert_eq "$bal" "1000000000000000000" "Post-upgrade bank send should work"
}

register_pre_upgrade  bank_pre_upgrade
register_post_upgrade bank_post_upgrade
register_test "Bank balances preserved"      _bank_test_balances_preserved
register_test "Post-upgrade bank send works" _bank_test_send_works

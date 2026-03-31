#!/usr/bin/env bash
# Module: validator health checks.

_validator_rpc_url() {
    echo "http://localhost:26657"
}

_validator_query_status() {
    curl -sf "$(_validator_rpc_url)/status" 2>/dev/null || return 1
}

_validator_test_rpc_accessible() {
    local status
    status="$(_validator_query_status 0)" || return 1
    local node_id
    node_id=$(echo "$status" | jq -r '.result.node_info.id // empty' 2>/dev/null || true)
    assert_not_empty "$node_id" "RPC endpoint should return node id"
}

_validator_test_sync_status() {
    local status
    status="$(_validator_query_status 0)" || return 1
    local catching_up
    catching_up=$(echo "$status" | jq -r '.result.sync_info.catching_up // "true"' 2>/dev/null || echo "true")
    assert_eq "$catching_up" "false" "validator should not be catching up"
}

_validator_test_voting_power() {
    local validators_json
    validators_json=$(exec_mocad query staking validators --node tcp://localhost:26657 --output json 2>/dev/null || echo "{}")
    local total
    total=$(echo "$validators_json" | jq -r '.validators | length // 0' 2>/dev/null || echo "0")
    assert_gt "$total" "0" "should have at least one validator"

    local first_power
    first_power=$(echo "$validators_json" | jq -r '.validators[0].consensus_power // "0"' 2>/dev/null || echo "0")
    assert_gt "$first_power" "0" "first validator consensus power should be > 0"
}

_validator_test_block_production() {
    local h1 h2
    h1=$(get_block_height "$(_validator_rpc_url)")
    sleep 4
    h2=$(get_block_height "$(_validator_rpc_url)")
    assert_gt "$h2" "$h1" "block height should increase over time"
}

register_verify "Validator RPC accessible"      _validator_test_rpc_accessible
register_verify "Validator sync status healthy" _validator_test_sync_status
register_verify "Validator voting power healthy" _validator_test_voting_power
register_verify "Validator block production"    _validator_test_block_production

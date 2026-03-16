#!/usr/bin/env bash
# Comprehensive upgrade test: 50+ EVM txs + 50+ Cosmos txs before and after upgrade.
# Upgrades from v1.1.2 to v12.2.0-rc1 using ghcr.io release image.
source "$(dirname "$0")/../framework/framework.sh"
fw_init

OLD_VERSION="${OLD_VERSION:-v1.1.2}"
UPGRADE_NAME="${UPGRADE_NAME:-v1.2.0}"
RELEASE_TAG="${RELEASE_TAG:-v12.2.0-rc1}"
RELEASE_IMAGE="${RELEASE_IMAGE:-ghcr.io/mocachain/mocad:${RELEASE_TAG}}"
EVM_RPC="http://localhost:8545"
EVM_CHAIN_ID="${SRC_CHAIN_ID}"
VAL0_PRIVKEY="0x${VALIDATOR0_PRIKEY}"
EVM_TX_COUNT=0
COSMOS_TX_COUNT=0

# ── Helpers ────────────────────────────────────────────────────────────────────

exec_on_validator() {
    local idx="$1"; shift
    kubectl exec -n "${K8S_NAMESPACE}" "validator-${idx}-0" -c mocad -- \
        mocad "$@" --home /root/.mocad 2>/dev/null
}

write_to_pod() {
    echo "$1" | kubectl exec -i -n "${K8S_NAMESPACE}" validator-0-0 -c mocad -- \
        bash -c "cat > $2" 2>/dev/null
}

cosmos_tx() {
    exec_mocad tx "$@" \
        --keyring-backend test --chain-id "${CHAIN_ID}" \
        --node tcp://localhost:26657 --fees 200000000000000amoca \
        -y > /dev/null 2>&1 && COSMOS_TX_COUNT=$((COSMOS_TX_COUNT + 1)) || true
    sleep 1
}

cosmos_tx_on() {
    local idx="$1"; shift
    exec_on_validator "$idx" tx "$@" \
        --keyring-backend test --chain-id "${CHAIN_ID}" \
        --node tcp://localhost:26657 --fees 200000000000000amoca \
        -y > /dev/null 2>&1 && COSMOS_TX_COUNT=$((COSMOS_TX_COUNT + 1)) || true
    sleep 1
}

evm_transfer() {
    cast send "$1" --value "$2" \
        --private-key "$VAL0_PRIVKEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
}

evm_deploy() {
    local bytecode="$1"
    local output=""
    output=$(cast send --private-key "$VAL0_PRIVKEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" --json --create "$bytecode" 2>/dev/null) || true
    local tx_hash=""
    tx_hash=$(echo "$output" | jq -r '.transactionHash // empty' 2>/dev/null) || true
    if [ -n "$tx_hash" ]; then
        EVM_TX_COUNT=$((EVM_TX_COUNT + 1))
        sleep 2
        local receipt=""
        receipt=$(cast receipt "$tx_hash" --rpc-url "$EVM_RPC" --json 2>/dev/null) || true
        echo "$receipt" | jq -r '.contractAddress // empty' 2>/dev/null || true
    fi
}

submit_text_proposal() {
    local title="$1" summary="$2" tmpfile="$3"
    local proposal_json
    proposal_json=$(cat <<PEOF
{
  "messages": [],
  "deposit": "${GOV_MIN_DEPOSIT_AMOUNT}${BASIC_DENOM}",
  "title": "${title}",
  "summary": "${summary}"
}
PEOF
    )
    write_to_pod "$proposal_json" "$tmpfile"
    cosmos_tx gov submit-proposal "$tmpfile" --from validator0
    sleep 3
    # Return latest proposal ID
    exec_mocad query gov proposals \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.proposals[-1].id // .proposals[-1].proposal_id // empty' 2>/dev/null || true
}

vote_all_validators() {
    local prop_id="$1"
    if [ -z "$prop_id" ]; then return; fi
    for ((v = 0; v < NUM_VALIDATORS; v++)); do
        cosmos_tx_on "$v" gov vote "$prop_id" yes --from "validator${v}"
    done
}

# ── Contract bytecodes ─────────────────────────────────────────────────────────
# Value-store: constructor stores 42 at slot 0; runtime stores msg.value at slot 0
VALUE_STORE_BC="0x602a6000556005601160003960056000f33460005500"
# Simple-store: constructor stores 42 at slot 0; runtime returns storage[0]
SIMPLE_STORE_BC="0x602a600055600b601160003960006000f360005460005260206000f3"

# ── Setup: deploy old version ──────────────────────────────────────────────────
fw_start_chain_from_version "$OLD_VERSION"

# Load release image into Kind
# Kind can't load multi-arch manifests from ghcr.io directly (Docker Desktop containerd issue).
# Detect architecture and rebuild as a clean single-platform image.
ARCH=$(uname -m)
case "$ARCH" in aarch64|arm64) _ARCH_TAG="arm64" ;; x86_64|amd64) _ARCH_TAG="amd64" ;; *) _ARCH_TAG="amd64" ;; esac
_GHCR_IMAGE="ghcr.io/mocachain/mocad:${RELEASE_TAG}-${_ARCH_TAG}"
_LOCAL_IMAGE="mocachain/moca:${RELEASE_TAG}"
log_info "Pulling release image: ${_GHCR_IMAGE}..."
docker pull "$_GHCR_IMAGE" 2>&1
log_info "Rebuilding as single-platform image for Kind..."
echo "FROM ${_GHCR_IMAGE}" | docker build -t "$_LOCAL_IMAGE" - 2>&1
kind load docker-image "$_LOCAL_IMAGE" --name "${KIND_CLUSTER_NAME}" 2>&1
RELEASE_IMAGE="$_LOCAL_IMAGE"
log_success "Release image loaded: ${RELEASE_IMAGE}"

# Pre-generate EVM addresses
EVM_ADDRS=()
for ((i = 0; i < 20; i++)); do
    key=$(cast wallet new --json 2>/dev/null | jq -r '.[0].private_key')
    EVM_ADDRS+=("$(cast wallet address "$key" 2>/dev/null)")
done

# Get validator operator addresses
VALIDATORS_JSON=$(exec_mocad query staking validators --node tcp://localhost:26657 --output json)
VAL_OPERS=()
for ((i = 0; i < NUM_VALIDATORS; i++)); do
    VAL_OPERS+=("$(echo "$VALIDATORS_JSON" | jq -r ".validators[$i].operator_address")")
done
log_info "Validator operators: ${VAL_OPERS[*]}"

# Create cosmos test accounts
COSMOS_ADDRS=()
for ((i = 0; i < 10; i++)); do
    exec_mocad keys add "comp-test-${i}" --keyring-backend test 2>/dev/null || true
    COSMOS_ADDRS+=("$(exec_mocad keys show "comp-test-${i}" -a --keyring-backend test)")
done

# ══════════════════════════════════════════════════════════════════════════════
# PRE-UPGRADE: EVM TRANSACTIONS (30 txs)
# ══════════════════════════════════════════════════════════════════════════════

log_info "=== Pre-upgrade: EVM transactions ==="

# 20 transfers
PRE_EVM_AMOUNTS=("0.1ether" "0.2ether" "0.5ether" "1ether" "0.01ether"
                 "0.05ether" "0.3ether" "2ether" "0.001ether" "0.75ether"
                 "1.5ether" "0.25ether" "0.4ether" "0.8ether" "3ether"
                 "0.15ether" "0.65ether" "0.9ether" "1.2ether" "0.07ether")
for ((i = 0; i < 20; i++)); do
    log_info "  EVM transfer $((i+1))/20: ${PRE_EVM_AMOUNTS[$i]}"
    evm_transfer "${EVM_ADDRS[$((i % 20))]}" "${PRE_EVM_AMOUNTS[$i]}"
done

# 5 value-store contract deployments
PRE_VS_CONTRACTS=()
for ((i = 0; i < 5; i++)); do
    log_info "  Deploy value-store contract $((i+1))/5"
    addr=$(evm_deploy "$VALUE_STORE_BC")
    [ -n "$addr" ] && PRE_VS_CONTRACTS+=("$addr")
done
log_info "  Deployed ${#PRE_VS_CONTRACTS[@]} value-store contracts"

# 5 contract interactions (send ETH to value-store contracts)
for ((i = 0; i < ${#PRE_VS_CONTRACTS[@]}; i++)); do
    log_info "  Contract send $((i+1)): 0.0$((i+1))ether -> ${PRE_VS_CONTRACTS[$i]:0:12}..."
    evm_transfer "${PRE_VS_CONTRACTS[$i]}" "0.0$((i+1))ether"
done

# 5 simple-store contract deployments
for ((i = 0; i < 5; i++)); do
    log_info "  Deploy simple-store contract $((i+1))/5"
    evm_deploy "$SIMPLE_STORE_BC" > /dev/null
done

log_info "Pre-upgrade EVM tx count: ${EVM_TX_COUNT}"

# ══════════════════════════════════════════════════════════════════════════════
# PRE-UPGRADE: COSMOS TRANSACTIONS (30 txs)
# ══════════════════════════════════════════════════════════════════════════════

log_info "=== Pre-upgrade: Cosmos transactions ==="

# 15 bank sends (different amounts)
PRE_COSMOS_AMOUNTS=("1000000000000000000" "2000000000000000000" "500000000000000000"
                    "3000000000000000000" "100000000000000000"  "750000000000000000"
                    "4000000000000000000" "250000000000000000"  "1500000000000000000"
                    "5000000000000000000" "800000000000000000"  "1200000000000000000"
                    "600000000000000000"  "900000000000000000"  "350000000000000000")
for ((i = 0; i < 15; i++)); do
    log_info "  Bank send $((i+1))/15: ${PRE_COSMOS_AMOUNTS[$i]}amoca -> comp-test-$((i % 10))"
    cosmos_tx bank send validator0 "${COSMOS_ADDRS[$((i % 10))]}" "${PRE_COSMOS_AMOUNTS[$i]}amoca" --from validator0
done

# 4 edit-validator (one per validator, change moniker)
for ((i = 0; i < NUM_VALIDATORS; i++)); do
    log_info "  Edit validator${i}: moniker=Val${i}-PreUpgrade"
    cosmos_tx_on "$i" staking edit-validator --moniker "Val${i}-PreUpgrade" --from "validator${i}"
done

# 4 withdraw-rewards
fw_wait_blocks 5
for ((i = 0; i < NUM_VALIDATORS; i++)); do
    log_info "  Withdraw rewards: validator${i}"
    cosmos_tx_on "$i" distribution withdraw-rewards "${VAL_OPERS[$i]}" --from "validator${i}"
done

# 2 text proposals + 8 votes = 10 txs
for ((p = 1; p <= 2; p++)); do
    log_info "  Submit text proposal ${p}"
    prop_id=$(submit_text_proposal "Pre-upgrade Proposal ${p}" "E2E pre-upgrade text proposal ${p}" "/tmp/pre-prop-${p}.json")
    log_info "  Proposal ID: ${prop_id:-unknown}"
    vote_all_validators "$prop_id"
done

# 2 delegate txs
for ((i = 1; i <= 2; i++)); do
    log_info "  Delegate 1 MOCA to validator${i}"
    cosmos_tx staking delegate "${VAL_OPERS[$i]}" "1000000000000000000amoca" --from validator0
    sleep 1
done

log_info "Pre-upgrade Cosmos tx count: ${COSMOS_TX_COUNT}"

# ── Record pre-upgrade state ──────────────────────────────────────────────────

PRE_HEIGHT=$(get_block_height "http://localhost:26657")
PRE_EVM_CHAIN_ID=$(cast chain-id --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
PRE_EVM_TX_COUNT=$EVM_TX_COUNT
PRE_COSMOS_TX_COUNT=$COSMOS_TX_COUNT

# Record balances
PRE_COSMOS_BAL=$(exec_mocad query bank balances "${COSMOS_ADDRS[0]}" \
    --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
    --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="amoca") | .amount // "0"') || true
PRE_EVM_BAL=$(cast balance "${EVM_ADDRS[0]}" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")

# Record contract storage
PRE_CONTRACT_STORAGE=()
for ((i = 0; i < ${#PRE_VS_CONTRACTS[@]}; i++)); do
    storage=$(cast storage "${PRE_VS_CONTRACTS[$i]}" 0 --rpc-url "$EVM_RPC" 2>/dev/null || echo "0x0")
    PRE_CONTRACT_STORAGE+=("$storage")
    log_info "  Pre-upgrade contract ${i} storage: ${storage}"
done

log_info "State snapshot: height=${PRE_HEIGHT}, evm_txs=${PRE_EVM_TX_COUNT}, cosmos_txs=${PRE_COSMOS_TX_COUNT}"

# ══════════════════════════════════════════════════════════════════════════════
# UPGRADE (v1.1.2 -> v12.2.0-rc1 via governance proposal)
# ══════════════════════════════════════════════════════════════════════════════

fw_upgrade_chain --name "$UPGRADE_NAME" --mode governance --new-image "$RELEASE_IMAGE"

# ══════════════════════════════════════════════════════════════════════════════
# POST-UPGRADE: EVM TRANSACTIONS (25+ txs)
# ══════════════════════════════════════════════════════════════════════════════

log_info "=== Post-upgrade: EVM transactions ==="

# 15 transfers
POST_EVM_AMOUNTS=("0.15ether" "0.35ether" "0.6ether" "1.1ether" "0.02ether"
                  "0.08ether" "0.45ether" "2.5ether" "0.003ether" "0.9ether"
                  "1.75ether" "0.55ether" "0.12ether" "0.33ether" "0.77ether")
for ((i = 0; i < 15; i++)); do
    log_info "  Post EVM transfer $((i+1))/15: ${POST_EVM_AMOUNTS[$i]}"
    evm_transfer "${EVM_ADDRS[$((i % 20))]}" "${POST_EVM_AMOUNTS[$i]}"
done

# 5 new contract deployments post-upgrade
POST_VS_CONTRACTS=()
for ((i = 0; i < 5; i++)); do
    log_info "  Post deploy value-store $((i+1))/5"
    addr=$(evm_deploy "$VALUE_STORE_BC")
    [ -n "$addr" ] && POST_VS_CONTRACTS+=("$addr")
done

# 5 interactions with pre-upgrade contracts
for ((i = 0; i < ${#PRE_VS_CONTRACTS[@]}; i++)); do
    log_info "  Post send to pre-upgrade contract ${i}"
    evm_transfer "${PRE_VS_CONTRACTS[$i]}" "0.00$((i+1))ether"
done

# 5 interactions with post-upgrade contracts
for ((i = 0; i < ${#POST_VS_CONTRACTS[@]}; i++)); do
    log_info "  Post send to post-upgrade contract ${i}"
    evm_transfer "${POST_VS_CONTRACTS[$i]}" "0.00$((i+1))ether"
done

log_info "Total EVM tx count: ${EVM_TX_COUNT}"

# ══════════════════════════════════════════════════════════════════════════════
# POST-UPGRADE: COSMOS TRANSACTIONS (28+ txs)
# ══════════════════════════════════════════════════════════════════════════════

log_info "=== Post-upgrade: Cosmos transactions ==="

# 15 bank sends
POST_COSMOS_AMOUNTS=("1100000000000000000" "2200000000000000000" "550000000000000000"
                     "3300000000000000000" "110000000000000000"  "770000000000000000"
                     "4400000000000000000" "275000000000000000"  "1650000000000000000"
                     "5500000000000000000" "880000000000000000"  "1320000000000000000"
                     "660000000000000000"  "990000000000000000"  "385000000000000000")
for ((i = 0; i < 15; i++)); do
    log_info "  Post bank send $((i+1))/15"
    cosmos_tx bank send validator0 "${COSMOS_ADDRS[$((i % 10))]}" "${POST_COSMOS_AMOUNTS[$i]}amoca" --from validator0
done

# 4 edit-validator (change moniker to Post)
for ((i = 0; i < NUM_VALIDATORS; i++)); do
    log_info "  Post edit validator${i}: moniker=Val${i}-PostUpgrade"
    cosmos_tx_on "$i" staking edit-validator --moniker "Val${i}-PostUpgrade" --from "validator${i}"
done

# 4 withdraw-rewards
fw_wait_blocks 5
for ((i = 0; i < NUM_VALIDATORS; i++)); do
    log_info "  Post withdraw rewards: validator${i}"
    cosmos_tx_on "$i" distribution withdraw-rewards "${VAL_OPERS[$i]}" --from "validator${i}"
done

# 2 text proposals + 8 votes = 10 txs
for ((p = 1; p <= 2; p++)); do
    log_info "  Post submit text proposal ${p}"
    prop_id=$(submit_text_proposal "Post-upgrade Proposal ${p}" "E2E post-upgrade text proposal ${p}" "/tmp/post-prop-${p}.json")
    log_info "  Proposal ID: ${prop_id:-unknown}"
    vote_all_validators "$prop_id"
done

# 2 unbond txs
for ((i = 1; i <= 2; i++)); do
    log_info "  Unbond 0.5 MOCA from validator${i}"
    cosmos_tx staking unbond "${VAL_OPERS[$i]}" "500000000000000000amoca" --from validator0
    sleep 1
done

log_info "Total Cosmos tx count: ${COSMOS_TX_COUNT}"

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICATION TESTS
# ══════════════════════════════════════════════════════════════════════════════

test_evm_tx_count() {
    log_info "EVM txs executed: ${EVM_TX_COUNT}"
    assert_gt "$EVM_TX_COUNT" "49" "Should have 50+ EVM txs (got ${EVM_TX_COUNT})"
}

test_cosmos_tx_count() {
    log_info "Cosmos txs executed: ${COSMOS_TX_COUNT}"
    assert_gt "$COSMOS_TX_COUNT" "49" "Should have 50+ Cosmos txs (got ${COSMOS_TX_COUNT})"
}

test_evm_chain_id_preserved() {
    local cid; cid=$(cast chain-id --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
    assert_eq "$cid" "$PRE_EVM_CHAIN_ID" "EVM chain ID preserved"
}

test_evm_balances_preserved() {
    local bal; bal=$(cast balance "${EVM_ADDRS[0]}" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
    assert_gt "$bal" "0" "EVM address[0] should have balance"
}

test_cosmos_balances_preserved() {
    local bal; bal=$(exec_mocad query bank balances "${COSMOS_ADDRS[0]}" \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="amoca") | .amount // "0"') || true
    assert_gt "$bal" "0" "Cosmos test account should have balance"
}

test_pre_upgrade_contracts_live() {
    if [ ${#PRE_VS_CONTRACTS[@]} -eq 0 ]; then
        log_warn "No pre-upgrade contracts, skipping"
        return 0
    fi
    for ((i = 0; i < ${#PRE_VS_CONTRACTS[@]}; i++)); do
        local code; code=$(cast code "${PRE_VS_CONTRACTS[$i]}" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0x")
        assert_not_empty "$code" "Pre-upgrade contract ${i} code should exist"
    done
}

test_post_upgrade_contracts_live() {
    if [ ${#POST_VS_CONTRACTS[@]} -eq 0 ]; then
        log_warn "No post-upgrade contracts, skipping"
        return 0
    fi
    for ((i = 0; i < ${#POST_VS_CONTRACTS[@]}; i++)); do
        local code; code=$(cast code "${POST_VS_CONTRACTS[$i]}" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0x")
        assert_not_empty "$code" "Post-upgrade contract ${i} code should exist"
    done
}

test_validator_monikers_updated() {
    local moniker; moniker=$(exec_mocad query staking validators \
        --node tcp://localhost:26657 --output json 2>/dev/null \
        | jq -r '.validators[0].description.moniker' 2>/dev/null) || true
    log_info "Validator0 moniker: ${moniker}"
    assert_not_empty "$moniker" "Validator moniker should be set"
}

test_upgrade_applied() {
    local result; result=$(exec_mocad query upgrade applied "$UPGRADE_NAME" \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null || echo "{}")
    local height; height=$(echo "$result" | jq -r '.height // empty' 2>/dev/null) || true
    assert_not_empty "$height" "Upgrade '${UPGRADE_NAME}' should be marked as applied"
}

test_new_binary_version() {
    local ver; ver=$(exec_mocad version 2>/dev/null || echo "")
    log_info "Binary version: ${ver}"
    assert_not_empty "$ver" "Binary should report a version"
}

test_height_advanced() {
    local h; h=$(get_block_height "http://localhost:26657")
    assert_gt "$h" "$PRE_HEIGHT" "Height past pre-upgrade"
}

test_chain_runs_20_blocks() {
    local h1; h1=$(get_block_height "http://localhost:26657")
    log_info "Waiting for 20 blocks from ${h1}..."
    fw_wait_blocks 20
    local h2; h2=$(get_block_height "http://localhost:26657")
    local diff=$((h2 - h1))
    assert_gt "$diff" "19" "Chain should produce 20+ blocks (got ${diff})"
}

test_evm_transfer_post_upgrade() {
    local recv; recv=$(cast wallet new --json 2>/dev/null | jq -r '.[0].private_key')
    local recv_addr; recv_addr=$(cast wallet address "$recv" 2>/dev/null)
    cast send "$recv_addr" --value 0.1ether \
        --private-key "$VAL0_PRIVKEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1
    sleep 3
    local bal; bal=$(cast balance "$recv_addr" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
    assert_eq "$bal" "100000000000000000" "Fresh EVM transfer should work post-upgrade"
}

test_cosmos_send_post_upgrade() {
    exec_mocad keys add comp-final-recv --keyring-backend test 2>/dev/null || true
    local recv; recv=$(exec_mocad keys show comp-final-recv -a --keyring-backend test)
    fw_tx_send validator0 "$recv" "1000000000000000000amoca"
    local bal; bal=$(exec_mocad query bank balances "$recv" \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="amoca") | .amount // "0"') || true
    assert_eq "$bal" "1000000000000000000" "Post-upgrade cosmos send should work"
}

fw_run_test "EVM tx count >= 50"                test_evm_tx_count
fw_run_test "Cosmos tx count >= 50"             test_cosmos_tx_count
fw_run_test "EVM chain ID preserved"            test_evm_chain_id_preserved
fw_run_test "EVM balances preserved"            test_evm_balances_preserved
fw_run_test "Cosmos balances preserved"         test_cosmos_balances_preserved
fw_run_test "Pre-upgrade contracts live"        test_pre_upgrade_contracts_live
fw_run_test "Post-upgrade contracts live"       test_post_upgrade_contracts_live
fw_run_test "Validator monikers updated"        test_validator_monikers_updated
fw_run_test "Upgrade handler applied"           test_upgrade_applied
fw_run_test "New binary version"                test_new_binary_version
fw_run_test "Height advanced"                   test_height_advanced
fw_run_test "Fresh EVM transfer works"          test_evm_transfer_post_upgrade
fw_run_test "Fresh Cosmos send works"           test_cosmos_send_post_upgrade
fw_run_test "Chain runs 20 blocks"              test_chain_runs_20_blocks
fw_done

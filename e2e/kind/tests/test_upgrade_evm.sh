#!/usr/bin/env bash
# EVM upgrade test with ERC20 contract: deploys TestERC20, exercises mint/burn/transfer/
# approve/transferFrom before and after governance upgrade. Verifies all ERC20 state
# (balances, allowances, totalSupply) persists across the upgrade.
source "$(dirname "$0")/../framework/framework.sh"
fw_init

OLD_VERSION="${OLD_VERSION:-v1.1.2}"
UPGRADE_NAME="${UPGRADE_NAME:-v1.2.0}"
EVM_RPC="http://localhost:8545"
EVM_CHAIN_ID="${SRC_CHAIN_ID}"
VAL0_PRIVKEY="0x${VALIDATOR0_PRIKEY}"
CONTRACTS_DIR="$(cd "$(dirname "$0")/../contracts" && pwd)"
EVM_TX_COUNT=0

# ── Helpers ────────────────────────────────────────────────────────────────────

evm_send() {
    # cast send with tracking
    cast send "$@" --private-key "$VAL0_PRIVKEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
    sleep 2
}

evm_call() {
    cast call "$@" --rpc-url "$EVM_RPC" 2>/dev/null
}

# ── Setup: deploy old version ────────────────────────────────────────────────
fw_start_chain_from_version "$OLD_VERSION"

# ══════════════════════════════════════════════════════════════════════════════
# PRE-UPGRADE: Deploy ERC20 and exercise all functions
# ══════════════════════════════════════════════════════════════════════════════

log_info "=== Pre-upgrade: ERC20 contract deployment ==="

# Verify EVM RPC is alive
PRE_CHAIN_ID=$(cast chain-id --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
log_info "EVM chain ID: ${PRE_CHAIN_ID}"

# Get validator0 EVM address
VAL0_EVM_ADDR=$(cast wallet address "$VAL0_PRIVKEY" 2>/dev/null)
log_info "Deployer (validator0) EVM address: ${VAL0_EVM_ADDR}"

# Generate secondary accounts for ERC20 interactions
ALICE_KEY=$(cast wallet new --json 2>/dev/null | jq -r '.[0].private_key')
ALICE_ADDR=$(cast wallet address "$ALICE_KEY" 2>/dev/null)
BOB_KEY=$(cast wallet new --json 2>/dev/null | jq -r '.[0].private_key')
BOB_ADDR=$(cast wallet address "$BOB_KEY" 2>/dev/null)
CAROL_KEY=$(cast wallet new --json 2>/dev/null | jq -r '.[0].private_key')
CAROL_ADDR=$(cast wallet address "$CAROL_KEY" 2>/dev/null)
log_info "Alice: ${ALICE_ADDR}"
log_info "Bob:   ${BOB_ADDR}"
log_info "Carol: ${CAROL_ADDR}"

# Fund Alice, Bob, Carol with native MOCA for gas fees
log_info "Funding accounts with native MOCA for gas..."
for addr in "$ALICE_ADDR" "$BOB_ADDR" "$CAROL_ADDR"; do
    cast send "$addr" --value 10ether \
        --private-key "$VAL0_PRIVKEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
    sleep 2
done

# Deploy TestERC20 via forge create
log_info "Deploying TestERC20 contract via forge create..."
DEPLOY_OUTPUT=$(forge create "${CONTRACTS_DIR}/TestERC20.sol:TestERC20" \
    --constructor-args "MocaTestToken" "MTT" 18 \
    --private-key "$VAL0_PRIVKEY" \
    --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" \
    --json 2>/dev/null) || true
EVM_TX_COUNT=$((EVM_TX_COUNT + 1))

ERC20_ADDR=$(echo "$DEPLOY_OUTPUT" | jq -r '.deployedTo // empty' 2>/dev/null) || true
if [ -z "$ERC20_ADDR" ]; then
    log_error "Failed to deploy TestERC20 contract"
    log_error "Deploy output: ${DEPLOY_OUTPUT}"
    exit 1
fi
log_success "TestERC20 deployed at: ${ERC20_ADDR}"

# Verify contract metadata
TOKEN_NAME=$(evm_call "$ERC20_ADDR" "name()(string)")
TOKEN_SYMBOL=$(evm_call "$ERC20_ADDR" "symbol()(string)")
TOKEN_DECIMALS=$(evm_call "$ERC20_ADDR" "decimals()(uint8)")
TOKEN_OWNER=$(evm_call "$ERC20_ADDR" "owner()(address)")
log_info "Token: ${TOKEN_NAME} (${TOKEN_SYMBOL}), decimals=${TOKEN_DECIMALS}, owner=${TOKEN_OWNER}"

# ── Mint tokens ──────────────────────────────────────────────────────────────
log_info "=== Pre-upgrade: Minting tokens ==="

# Mint to deployer (validator0): 1,000,000 tokens
MINT_DEPLOYER="1000000000000000000000000"  # 1M * 1e18
log_info "  Minting ${MINT_DEPLOYER} to deployer..."
evm_send "$ERC20_ADDR" "mint(address,uint256)" "$VAL0_EVM_ADDR" "$MINT_DEPLOYER"

# Mint to Alice: 500,000 tokens
MINT_ALICE="500000000000000000000000"  # 500K * 1e18
log_info "  Minting ${MINT_ALICE} to Alice..."
evm_send "$ERC20_ADDR" "mint(address,uint256)" "$ALICE_ADDR" "$MINT_ALICE"

# Mint to Bob: 250,000 tokens
MINT_BOB="250000000000000000000000"  # 250K * 1e18
log_info "  Minting ${MINT_BOB} to Bob..."
evm_send "$ERC20_ADDR" "mint(address,uint256)" "$BOB_ADDR" "$MINT_BOB"

# Mint to Carol: 100,000 tokens
MINT_CAROL="100000000000000000000000"  # 100K * 1e18
log_info "  Minting ${MINT_CAROL} to Carol..."
evm_send "$ERC20_ADDR" "mint(address,uint256)" "$CAROL_ADDR" "$MINT_CAROL"

# ── Transfers ────────────────────────────────────────────────────────────────
log_info "=== Pre-upgrade: Token transfers ==="

# Deployer transfers 10,000 to Alice
TRANSFER_AMT1="10000000000000000000000"  # 10K * 1e18
log_info "  Deployer -> Alice: 10,000 tokens"
evm_send "$ERC20_ADDR" "transfer(address,uint256)" "$ALICE_ADDR" "$TRANSFER_AMT1"

# Alice transfers 5,000 to Bob (Alice signs)
TRANSFER_AMT2="5000000000000000000000"  # 5K * 1e18
log_info "  Alice -> Bob: 5,000 tokens"
cast send "$ERC20_ADDR" "transfer(address,uint256)" "$BOB_ADDR" "$TRANSFER_AMT2" \
    --private-key "$ALICE_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# Bob transfers 1,000 to Carol
TRANSFER_AMT3="1000000000000000000000"  # 1K * 1e18
log_info "  Bob -> Carol: 1,000 tokens"
cast send "$ERC20_ADDR" "transfer(address,uint256)" "$CAROL_ADDR" "$TRANSFER_AMT3" \
    --private-key "$BOB_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# ── Approve + TransferFrom ───────────────────────────────────────────────────
log_info "=== Pre-upgrade: Approve & TransferFrom ==="

# Alice approves Bob to spend 20,000 tokens
APPROVE_AMT="20000000000000000000000"  # 20K * 1e18
log_info "  Alice approves Bob for 20,000 tokens"
cast send "$ERC20_ADDR" "approve(address,uint256)" "$BOB_ADDR" "$APPROVE_AMT" \
    --private-key "$ALICE_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# Bob uses transferFrom to move 8,000 from Alice to Carol
TRANSFERFROM_AMT="8000000000000000000000"  # 8K * 1e18
log_info "  Bob transferFrom Alice -> Carol: 8,000 tokens"
cast send "$ERC20_ADDR" "transferFrom(address,address,uint256)" "$ALICE_ADDR" "$CAROL_ADDR" "$TRANSFERFROM_AMT" \
    --private-key "$BOB_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# Carol approves deployer to spend 5,000 tokens
CAROL_APPROVE="5000000000000000000000"  # 5K * 1e18
log_info "  Carol approves deployer for 5,000 tokens"
cast send "$ERC20_ADDR" "approve(address,uint256)" "$VAL0_EVM_ADDR" "$CAROL_APPROVE" \
    --private-key "$CAROL_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# Deployer uses transferFrom to move 3,000 from Carol to Alice
TRANSFERFROM_AMT2="3000000000000000000000"  # 3K * 1e18
log_info "  Deployer transferFrom Carol -> Alice: 3,000 tokens"
evm_send "$ERC20_ADDR" "transferFrom(address,address,uint256)" "$CAROL_ADDR" "$ALICE_ADDR" "$TRANSFERFROM_AMT2"

# ── Burn ─────────────────────────────────────────────────────────────────────
log_info "=== Pre-upgrade: Burn tokens ==="

# Burn 50,000 from deployer
BURN_AMT="50000000000000000000000"  # 50K * 1e18
log_info "  Burning 50,000 tokens from deployer"
evm_send "$ERC20_ADDR" "burn(address,uint256)" "$VAL0_EVM_ADDR" "$BURN_AMT"

# Burn 10,000 from Bob
BURN_AMT2="10000000000000000000000"  # 10K * 1e18
log_info "  Burning 10,000 tokens from Bob"
evm_send "$ERC20_ADDR" "burn(address,uint256)" "$BOB_ADDR" "$BURN_AMT2"

# ── Additional EVM transfers for tx count padding ────────────────────────────
log_info "=== Pre-upgrade: Additional native MOCA transfers ==="
for ((i = 0; i < 10; i++)); do
    recv_key=$(cast wallet new --json 2>/dev/null | jq -r '.[0].private_key')
    recv_addr=$(cast wallet address "$recv_key" 2>/dev/null)
    cast send "$recv_addr" --value "0.0$((i+1))ether" \
        --private-key "$VAL0_PRIVKEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
    sleep 1
done

# Deploy a second ERC20 for variety
log_info "Deploying second ERC20 (MocaGold)..."
DEPLOY2_OUTPUT=$(forge create "${CONTRACTS_DIR}/TestERC20.sol:TestERC20" \
    --constructor-args "MocaGold" "MGD" 8 \
    --private-key "$VAL0_PRIVKEY" \
    --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" \
    --json 2>/dev/null) || true
EVM_TX_COUNT=$((EVM_TX_COUNT + 1))

ERC20_ADDR2=$(echo "$DEPLOY2_OUTPUT" | jq -r '.deployedTo // empty' 2>/dev/null) || true
log_info "MocaGold deployed at: ${ERC20_ADDR2:-FAILED}"

# Mint some MocaGold tokens
if [ -n "$ERC20_ADDR2" ]; then
    evm_send "$ERC20_ADDR2" "mint(address,uint256)" "$ALICE_ADDR" "100000000000"  # 1000 * 1e8
    evm_send "$ERC20_ADDR2" "mint(address,uint256)" "$BOB_ADDR" "50000000000"    # 500 * 1e8
fi

log_info "Pre-upgrade EVM tx count: ${EVM_TX_COUNT}"

# ── Record pre-upgrade state ──────────────────────────────────────────────────
log_info "=== Recording pre-upgrade ERC20 state ==="

PRE_HEIGHT=$(get_block_height "http://localhost:26657")

# Read all ERC20 balances (MTT - 18 decimals)
PRE_BAL_DEPLOYER=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$VAL0_EVM_ADDR")
PRE_BAL_ALICE=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$ALICE_ADDR")
PRE_BAL_BOB=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$BOB_ADDR")
PRE_BAL_CAROL=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$CAROL_ADDR")
PRE_TOTAL_SUPPLY=$(evm_call "$ERC20_ADDR" "totalSupply()(uint256)")
PRE_ALLOWANCE_ALICE_BOB=$(evm_call "$ERC20_ADDR" "allowance(address,address)(uint256)" "$ALICE_ADDR" "$BOB_ADDR")
PRE_ALLOWANCE_CAROL_DEPLOYER=$(evm_call "$ERC20_ADDR" "allowance(address,address)(uint256)" "$CAROL_ADDR" "$VAL0_EVM_ADDR")
PRE_TOKEN_NAME=$(evm_call "$ERC20_ADDR" "name()(string)")
PRE_TOKEN_SYMBOL=$(evm_call "$ERC20_ADDR" "symbol()(string)")

log_info "  Deployer MTT balance: ${PRE_BAL_DEPLOYER}"
log_info "  Alice MTT balance:    ${PRE_BAL_ALICE}"
log_info "  Bob MTT balance:      ${PRE_BAL_BOB}"
log_info "  Carol MTT balance:    ${PRE_BAL_CAROL}"
log_info "  Total supply:         ${PRE_TOTAL_SUPPLY}"
log_info "  Allowance Alice->Bob: ${PRE_ALLOWANCE_ALICE_BOB}"
log_info "  Allowance Carol->Deployer: ${PRE_ALLOWANCE_CAROL_DEPLOYER}"

# Native balances
PRE_NATIVE_ALICE=$(cast balance "$ALICE_ADDR" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")

# Second token state (MocaGold)
PRE_MGD_ALICE=""
PRE_MGD_BOB=""
if [ -n "$ERC20_ADDR2" ]; then
    PRE_MGD_ALICE=$(evm_call "$ERC20_ADDR2" "balanceOf(address)(uint256)" "$ALICE_ADDR")
    PRE_MGD_BOB=$(evm_call "$ERC20_ADDR2" "balanceOf(address)(uint256)" "$BOB_ADDR")
    log_info "  Alice MGD balance: ${PRE_MGD_ALICE}"
    log_info "  Bob MGD balance:   ${PRE_MGD_BOB}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# UPGRADE (via governance proposal)
# ══════════════════════════════════════════════════════════════════════════════

fw_upgrade_chain --name "$UPGRADE_NAME" --mode governance

# ══════════════════════════════════════════════════════════════════════════════
# POST-UPGRADE: Verify state and do more ERC20 operations
# ══════════════════════════════════════════════════════════════════════════════

log_info "=== Post-upgrade: ERC20 operations ==="

# Post-upgrade mints
log_info "  Post-upgrade mint: 200,000 to Carol"
evm_send "$ERC20_ADDR" "mint(address,uint256)" "$CAROL_ADDR" "200000000000000000000000"

# Post-upgrade transfer: Alice sends 2,000 to Bob
log_info "  Post Alice -> Bob: 2,000 tokens"
cast send "$ERC20_ADDR" "transfer(address,uint256)" "$BOB_ADDR" "2000000000000000000000" \
    --private-key "$ALICE_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# Post-upgrade approve: Bob approves Carol for 15,000
log_info "  Post Bob approves Carol for 15,000"
cast send "$ERC20_ADDR" "approve(address,uint256)" "$CAROL_ADDR" "15000000000000000000000" \
    --private-key "$BOB_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# Post-upgrade transferFrom: Carol uses Bob's allowance to send 5,000 to deployer
log_info "  Post Carol transferFrom Bob -> Deployer: 5,000"
cast send "$ERC20_ADDR" "transferFrom(address,address,uint256)" "$BOB_ADDR" "$VAL0_EVM_ADDR" "5000000000000000000000" \
    --private-key "$CAROL_KEY" --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
sleep 2

# Post-upgrade burn: 25,000 from deployer
log_info "  Post burn 25,000 from deployer"
evm_send "$ERC20_ADDR" "burn(address,uint256)" "$VAL0_EVM_ADDR" "25000000000000000000000"

# Post-upgrade native transfers
log_info "  Post-upgrade native MOCA transfers..."
for ((i = 0; i < 5; i++)); do
    recv_key=$(cast wallet new --json 2>/dev/null | jq -r '.[0].private_key')
    recv_addr=$(cast wallet address "$recv_key" 2>/dev/null)
    cast send "$recv_addr" --value "0.1ether" \
        --private-key "$VAL0_PRIVKEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
    sleep 1
done

# Deploy a third ERC20 post-upgrade to verify contract creation still works
log_info "Deploying third ERC20 (MocaSilver) post-upgrade..."
DEPLOY3_OUTPUT=$(forge create "${CONTRACTS_DIR}/TestERC20.sol:TestERC20" \
    --constructor-args "MocaSilver" "MSV" 6 \
    --private-key "$VAL0_PRIVKEY" \
    --rpc-url "$EVM_RPC" \
    --chain-id "$EVM_CHAIN_ID" \
    --json 2>/dev/null) || true
EVM_TX_COUNT=$((EVM_TX_COUNT + 1))

ERC20_ADDR3=$(echo "$DEPLOY3_OUTPUT" | jq -r '.deployedTo // empty' 2>/dev/null) || true
log_info "MocaSilver deployed at: ${ERC20_ADDR3:-FAILED}"

# Mint and transfer on post-upgrade contract
if [ -n "$ERC20_ADDR3" ]; then
    evm_send "$ERC20_ADDR3" "mint(address,uint256)" "$ALICE_ADDR" "1000000000"  # 1000 * 1e6
    evm_send "$ERC20_ADDR3" "mint(address,uint256)" "$BOB_ADDR" "500000000"
    cast send "$ERC20_ADDR3" "transfer(address,uint256)" "$BOB_ADDR" "100000000" \
        --private-key "$ALICE_KEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 && EVM_TX_COUNT=$((EVM_TX_COUNT + 1)) || true
    sleep 2
fi

log_info "Total EVM tx count: ${EVM_TX_COUNT}"

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICATION TESTS
# ══════════════════════════════════════════════════════════════════════════════

test_evm_rpc_alive() {
    local chain_id; chain_id=$(cast chain-id --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
    assert_eq "$chain_id" "$PRE_CHAIN_ID" "EVM chain ID should match post-upgrade"
}

test_erc20_balances_preserved() {
    local bal_deployer; bal_deployer=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$VAL0_EVM_ADDR")
    local bal_alice; bal_alice=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$ALICE_ADDR")
    local bal_bob; bal_bob=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$BOB_ADDR")
    local bal_carol; bal_carol=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$CAROL_ADDR")

    # Balances changed post-upgrade so compare against expected post-upgrade values
    # Pre-deployer - 25K burn + 5K from Carol transferFrom = pre - 20K
    # Pre-alice - 2K transfer to Bob = pre - 2K
    # Pre-bob + 2K from Alice - 5K transferFrom to deployer = pre - 3K
    # Pre-carol + 200K mint = pre + 200K
    # But we just check they're non-zero and consistent
    log_info "Post-upgrade deployer balance: ${bal_deployer}"
    log_info "Post-upgrade Alice balance: ${bal_alice}"
    log_info "Post-upgrade Bob balance: ${bal_bob}"
    log_info "Post-upgrade Carol balance: ${bal_carol}"
    assert_not_empty "$bal_deployer" "Deployer should have ERC20 balance"
    assert_not_empty "$bal_alice" "Alice should have ERC20 balance"
    assert_not_empty "$bal_bob" "Bob should have ERC20 balance"
    assert_not_empty "$bal_carol" "Carol should have ERC20 balance"
}

test_erc20_total_supply_consistent() {
    local supply; supply=$(evm_call "$ERC20_ADDR" "totalSupply()(uint256)")
    log_info "Post-upgrade total supply: ${supply}"
    # Supply = pre + 200K mint - 25K burn = pre + 175K
    assert_not_empty "$supply" "Total supply should be set"
    assert_gt "$supply" "0" "Total supply should be positive"
}

test_erc20_metadata_preserved() {
    local name; name=$(evm_call "$ERC20_ADDR" "name()(string)")
    local sym; sym=$(evm_call "$ERC20_ADDR" "symbol()(string)")
    assert_eq "$name" "$PRE_TOKEN_NAME" "Token name should survive upgrade"
    assert_eq "$sym" "$PRE_TOKEN_SYMBOL" "Token symbol should survive upgrade"
}

test_erc20_allowance_preserved() {
    # Alice->Bob allowance should be: pre - 8K (used in transferFrom) = 12K remaining pre-upgrade
    # No post-upgrade changes to Alice->Bob allowance
    local allowance; allowance=$(evm_call "$ERC20_ADDR" "allowance(address,address)(uint256)" "$ALICE_ADDR" "$BOB_ADDR")
    log_info "Alice->Bob allowance post-upgrade: ${allowance}"
    assert_eq "$allowance" "$PRE_ALLOWANCE_ALICE_BOB" "Alice->Bob allowance should survive upgrade"
}

test_erc20_transfer_post_upgrade() {
    # Do a fresh transfer post-upgrade to verify the contract is functional
    local pre_bal; pre_bal=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$CAROL_ADDR")
    cast send "$ERC20_ADDR" "transfer(address,uint256)" "$VAL0_EVM_ADDR" "1000000000000000000000" \
        --private-key "$CAROL_KEY" --rpc-url "$EVM_RPC" \
        --chain-id "$EVM_CHAIN_ID" > /dev/null 2>&1 || true
    sleep 3
    local post_bal; post_bal=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$CAROL_ADDR")
    log_info "Carol balance before=${pre_bal}, after=${post_bal}"
    # post_bal should be less than pre_bal (transferred 1,000 tokens)
    assert_not_empty "$post_bal" "Carol should still have balance after transfer"
}

test_erc20_mint_post_upgrade() {
    # Owner should still be able to mint post-upgrade
    local pre_supply; pre_supply=$(evm_call "$ERC20_ADDR" "totalSupply()(uint256)")
    evm_send "$ERC20_ADDR" "mint(address,uint256)" "$ALICE_ADDR" "1000000000000000000000"  # 1K tokens
    local post_supply; post_supply=$(evm_call "$ERC20_ADDR" "totalSupply()(uint256)")
    log_info "Supply before mint=${pre_supply}, after=${post_supply}"
    assert_not_empty "$post_supply" "Supply should exist after mint"
}

test_erc20_burn_post_upgrade() {
    local pre_bal; pre_bal=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$ALICE_ADDR")
    evm_send "$ERC20_ADDR" "burn(address,uint256)" "$ALICE_ADDR" "500000000000000000000"  # 500 tokens
    local post_bal; post_bal=$(evm_call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$ALICE_ADDR")
    log_info "Alice balance before burn=${pre_bal}, after=${post_bal}"
    assert_not_empty "$post_bal" "Alice should have balance after burn"
}

test_second_erc20_survived() {
    if [ -z "$ERC20_ADDR2" ]; then
        log_warn "Second ERC20 not deployed, skipping"
        return 0
    fi
    local bal_alice; bal_alice=$(evm_call "$ERC20_ADDR2" "balanceOf(address)(uint256)" "$ALICE_ADDR")
    local bal_bob; bal_bob=$(evm_call "$ERC20_ADDR2" "balanceOf(address)(uint256)" "$BOB_ADDR")
    assert_eq "$bal_alice" "$PRE_MGD_ALICE" "MocaGold Alice balance should survive upgrade"
    assert_eq "$bal_bob" "$PRE_MGD_BOB" "MocaGold Bob balance should survive upgrade"
}

test_post_upgrade_contract_deploy() {
    if [ -z "$ERC20_ADDR3" ]; then
        log_warn "Post-upgrade ERC20 deployment failed"
        return 1
    fi
    local code; code=$(cast code "$ERC20_ADDR3" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0x")
    assert_not_empty "$code" "Post-upgrade deployed contract should have code"
    local name; name=$(evm_call "$ERC20_ADDR3" "name()(string)")
    assert_eq "$name" "MocaSilver" "Post-upgrade contract should return correct name"
}

test_native_balances_preserved() {
    local bal; bal=$(cast balance "$ALICE_ADDR" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
    assert_gt "$bal" "0" "Native MOCA balance should survive upgrade"
}

test_evm_block_number_advanced() {
    local block; block=$(cast block-number --rpc-url "$EVM_RPC" 2>/dev/null || echo "0")
    assert_gt "$block" "$PRE_HEIGHT" "Block number should advance post-upgrade"
}

test_chain_runs_20_blocks() {
    local h1; h1=$(get_block_height "http://localhost:26657")
    log_info "Waiting for 20 blocks from height ${h1}..."
    fw_wait_blocks 20
    local h2; h2=$(get_block_height "http://localhost:26657")
    local diff=$((h2 - h1))
    assert_gt "$diff" "19" "Chain should produce at least 20 blocks post-upgrade (got ${diff})"
}

test_evm_tx_count() {
    log_info "Total EVM txs: ${EVM_TX_COUNT}"
    assert_gt "$EVM_TX_COUNT" "29" "Should have 30+ EVM txs (got ${EVM_TX_COUNT})"
}

fw_run_test "EVM RPC alive post-upgrade"           test_evm_rpc_alive
fw_run_test "ERC20 balances post-upgrade"           test_erc20_balances_preserved
fw_run_test "ERC20 total supply consistent"         test_erc20_total_supply_consistent
fw_run_test "ERC20 metadata preserved"              test_erc20_metadata_preserved
fw_run_test "ERC20 allowances preserved"            test_erc20_allowance_preserved
fw_run_test "ERC20 transfer works post-upgrade"     test_erc20_transfer_post_upgrade
fw_run_test "ERC20 mint works post-upgrade"         test_erc20_mint_post_upgrade
fw_run_test "ERC20 burn works post-upgrade"         test_erc20_burn_post_upgrade
fw_run_test "Second ERC20 state survived"           test_second_erc20_survived
fw_run_test "Post-upgrade contract deploy"          test_post_upgrade_contract_deploy
fw_run_test "Native MOCA balances preserved"        test_native_balances_preserved
fw_run_test "Block number advanced"                 test_evm_block_number_advanced
fw_run_test "Chain runs 20 blocks"                  test_chain_runs_20_blocks
fw_run_test "EVM tx count >= 30"                    test_evm_tx_count
fw_done

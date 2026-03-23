#!/usr/bin/env bash
# Module: gov — text proposal submission and voting.

_GOV_PROP_IDX=0

# Submit a gov proposal using direct kubectl exec (same pattern as upgrade-chain.sh).
# This bypasses the cosmos_tx helper which silences all output and has proven unreliable
# for submit-proposal commands that require file arguments.
# Usage: _gov_submit_proposal <proposal_json> <tmpfile>
# Returns: 0 on success, 1 on failure. Sets _GOV_LAST_PROP_ID on success.
_gov_submit_proposal() {
    local proposal_json="$1"
    local tmpfile="$2"
    local fees="200000000000000amoca"

    # Write proposal JSON into the pod
    echo "$proposal_json" | kubectl exec -i -n "${K8S_NAMESPACE}" validator-0-0 -c mocad -- \
        bash -c "cat > ${tmpfile}" 2>/dev/null

    # Verify the file was written
    local written
    written=$(kubectl exec -n "${K8S_NAMESPACE}" validator-0-0 -c mocad -- \
        cat "${tmpfile}" 2>/dev/null) || true
    if [ -z "$written" ]; then
        log_warn "  [gov] Failed to write proposal JSON to pod at ${tmpfile}"
        return 1
    fi

    # Submit proposal using direct kubectl exec (matches upgrade-chain.sh pattern)
    local submit_out
    submit_out=$(kubectl exec -n "${K8S_NAMESPACE}" validator-0-0 -c mocad -- \
        mocad tx gov submit-proposal "${tmpfile}" \
        --from validator0 \
        --keyring-backend test \
        --chain-id "${CHAIN_ID}" \
        --node tcp://localhost:26657 \
        --fees "$fees" \
        --home /root/.mocad \
        -y 2>&1) || true

    local tx_code
    tx_code=$(echo "$submit_out" | grep -o 'code: [0-9]*' | head -1 | awk '{print $2}') || true
    if [ -n "$tx_code" ] && [ "$tx_code" != "0" ]; then
        log_warn "  [gov] Proposal tx failed with code ${tx_code}"
        log_warn "  [gov] Output: ${submit_out}"
        return 1
    fi

    sleep 3
    return 0
}

# Single gov tx — submit a text proposal and vote YES from all validators
gov_tx() {
    _GOV_PROP_IDX=$((_GOV_PROP_IDX + 1))
    local title="E2E Proposal ${_GOV_PROP_IDX}"
    local summary="E2E text proposal ${_GOV_PROP_IDX}"
    local tmpfile="/tmp/gov-prop-${_GOV_PROP_IDX}.json"

    log_info "  [gov] submit proposal: ${title}"
    local proposal_json
    proposal_json=$(cat <<PEOF
{"messages":[],"deposit":"${GOV_MIN_DEPOSIT_AMOUNT}${BASIC_DENOM}","title":"${title}","summary":"${summary}"}
PEOF
    )

    _gov_submit_proposal "$proposal_json" "$tmpfile" || return 0

    local prop_id
    prop_id=$(exec_mocad query gov proposals \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.proposals[-1].id // .proposals[-1].proposal_id // empty') || true
    if [ -n "$prop_id" ]; then
        log_info "  [gov] proposal ${prop_id} created, voting..."
        for ((v = 0; v < NUM_VALIDATORS; v++)); do
            cosmos_tx_on "$v" gov vote "$prop_id" yes --from "validator${v}"
        done
    else
        log_warn "  [gov] could not find proposal ID after submission"
    fi
}

_gov_verify_proposals_exist() {
    local count; count=$(exec_mocad query gov proposals \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq '.proposals | length') || true
    assert_gt "$count" "0" "Proposals should exist post-upgrade"
}

_gov_verify_submit_works() {
    local pre_count; pre_count=$(exec_mocad query gov proposals \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq '.proposals | length') || true
    pre_count="${pre_count:-0}"
    log_info "  [gov] pre_count=${pre_count}"

    # Query the actual min deposit from chain params (may differ across versions)
    local min_deposit; min_deposit=$(exec_mocad query gov params \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '
            .params.min_deposit[0].amount //
            .deposit_params.min_deposit[0].amount //
            empty' 2>/dev/null) || true
    min_deposit="${min_deposit:-${GOV_MIN_DEPOSIT_AMOUNT}}"
    local denom; denom=$(exec_mocad query gov params \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '
            .params.min_deposit[0].denom //
            .deposit_params.min_deposit[0].denom //
            empty' 2>/dev/null) || true
    denom="${denom:-${BASIC_DENOM}}"
    log_info "  [gov] using deposit=${min_deposit}${denom}"

    local prop_json="{\"messages\":[],\"deposit\":\"${min_deposit}${denom}\",\"title\":\"E2E Post-Upgrade Test\",\"summary\":\"Post-upgrade proposal\"}"
    local tmpfile="/tmp/gov-prop-verify.json"

    _gov_submit_proposal "$prop_json" "$tmpfile"
    sleep 5

    local post_count; post_count=$(exec_mocad query gov proposals \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq '.proposals | length') || true
    post_count="${post_count:-0}"
    log_info "  [gov] post_count=${post_count}"
    assert_gt "$post_count" "$pre_count" "Post-upgrade proposal submission should work"
}

register_tx     gov_tx
register_verify "Proposals preserved"                _gov_verify_proposals_exist
register_verify "Post-upgrade proposal submission"   _gov_verify_submit_works

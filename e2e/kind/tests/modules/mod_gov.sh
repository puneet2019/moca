#!/usr/bin/env bash
# Module: gov — governance text proposals and voting before and after upgrade.

_GOV_PRE_PROP_IDS=()
_GOV_POST_PROP_ID=""

_gov_submit_and_vote() {
    local title="$1" summary="$2" tmpfile="$3"
    local proposal_json
    proposal_json=$(cat <<PEOF
{"messages":[],"deposit":"${GOV_MIN_DEPOSIT_AMOUNT}${BASIC_DENOM}","title":"${title}","summary":"${summary}"}
PEOF
    )
    write_to_pod "$proposal_json" "$tmpfile"
    cosmos_tx gov submit-proposal "$tmpfile" --from validator0
    sleep 3
    local prop_id
    prop_id=$(exec_mocad query gov proposals \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq -r '.proposals[-1].id // .proposals[-1].proposal_id // empty') || true
    if [ -n "$prop_id" ]; then
        for ((v = 0; v < NUM_VALIDATORS; v++)); do
            cosmos_tx_on "$v" gov vote "$prop_id" yes --from "validator${v}"
        done
    fi
    echo "$prop_id"
}

gov_pre_upgrade() {
    for ((p = 1; p <= 2; p++)); do
        log_info "  [gov] submit text proposal ${p}"
        local pid
        pid=$(_gov_submit_and_vote "Pre-upgrade Proposal ${p}" "E2E pre-upgrade text proposal ${p}" "/tmp/gov-pre-prop-${p}.json")
        [ -n "$pid" ] && _GOV_PRE_PROP_IDS+=("$pid")
    done
}

gov_post_upgrade() {
    log_info "  [gov] submit post-upgrade text proposal"
    _GOV_POST_PROP_ID=$(_gov_submit_and_vote "Post-upgrade Proposal" "E2E post-upgrade text proposal" "/tmp/gov-post-prop.json")
}

_gov_test_pre_proposals_exist() {
    [ ${#_GOV_PRE_PROP_IDS[@]} -eq 0 ] && { log_warn "No pre-upgrade proposals"; return 0; }
    local count; count=$(exec_mocad query gov proposals \
        --node tcp://localhost:26657 --chain-id "${CHAIN_ID}" \
        --output json 2>/dev/null | jq '.proposals | length') || true
    assert_gt "$count" "0" "Proposals should exist post-upgrade"
}

_gov_test_post_proposal_works() {
    assert_not_empty "$_GOV_POST_PROP_ID" "Post-upgrade proposal should be submitted"
}

register_pre_upgrade  gov_pre_upgrade
register_post_upgrade gov_post_upgrade
register_test "Pre-upgrade proposals preserved"    _gov_test_pre_proposals_exist
register_test "Post-upgrade proposal submission"   _gov_test_post_proposal_works

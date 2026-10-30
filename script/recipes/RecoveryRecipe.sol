// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {
    OP_ADD,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MIN,
    OP_SATURATING_SUB,
    OP_SUB
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ClaimRecipe} from "./ClaimRecipe.sol";
import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RecoveryRecipe
 * @notice Library for ordered liquidity recovery and later redemption claims against one debt asset.
 * @dev This is an offchain recipe builder, not a scheduler. All amounts are computed from live reads;
 * execution inputs are empty, and runtime supplies only the configured groups' actions and permissions.
 * Withdrawals must come from positions that do not collateralize this debt. The health-based repayment
 * formula assumes unchanged collateral and one debt asset. Reads must normalize debt, capacities,
 * pending principal and claimable principal to raw repayment-asset units; health uses 1e18 precision.
 * Issuer queries are protocol-specific: fixture getters are not a universal issuer API. Capacity reads
 * must exclude already committed holdings, and pending reads must cover distinct outstanding requests.
 */
library RecoveryRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;
    error InvalidConfiguration();

    struct Read {
        address target;
        bytes data;
        uint256 offset;
    }

    struct Source {
        Read capacity;
        bytes32[] leaves;
        uint256[][] amountOffsets;
    }

    struct Redemption {
        address token;
        address spender;
        Read capacity;
        Read pending;
        uint256 maxTokenPerAssetWad;
        bytes32[] leaves;
        uint256[][] amountOffsets;
        uint256[][] approvalAmountOffsets;
        uint256[][] clearApprovalAmountOffsets;
    }

    struct Claim {
        Read claimable;
        Read pending;
        uint256 maxAmount;
        uint256 minAssetPerClaimWad;
        bytes32[] leaves;
        uint256[][] amountOffsets;
        Read selectedId;
        uint256[] claimableIdOffsets;
        uint256[] pendingIdOffsets;
        uint256[][] idOffsets;
        Read minimum;
    }

    struct Config {
        address account;
        address asset;
        address repayTarget;
        bytes32 approvalLeaf;
        bytes32 repayLeaf;
        uint256[] repayAmountOffsets;
        Read healthFactor;
        Read debt;
        uint256 triggerHealthFactor;
        uint256 targetHealthFactor;
        uint256 maxRepayment;
        uint256 debtTolerance;
        bool skipUnusedReads;

        Source[] sources;
        Redemption[] redemptions;
        Claim[] claims;
    }

    // Calls and approvals index runtime payloads; packed result operands reference instructions.
    struct Layout {
        uint256[] sourceCalls;
        uint256[] requestCalls;
        uint256[] claimCalls;
        uint256 approve;
        uint256 repay;
        uint256 clearApproval;
    }

    struct Snapshot {
        uint256 health;
        uint256 debt;
        uint256 cash;
    }

    /**
     * @notice Builds low-health recovery: spend held cash, exhaust sources in order, repay,
     * then queue RWAs.
     * @dev The trigger is checked before any other read. Pending principal only reduces the remaining request
     * gap; it never counts as repayment or improved health. Partial progress is permitted when cash and
     * capacities cannot meet the target. Each rate is raw RWA units per raw repayment-asset unit, scaled by
     * 1e18, including decimal conversion.
     * @param config Position, sources, redemptions, repayment permissions and limits.
     */
    function recovery(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        uint256 redemptionsLength = config.redemptions.length;
        ExecutingRecipe.Builder memory builder = _start(config, 64 + 8 * config.sources.length + 18 * redemptionsLength);
        layout.requestCalls = new uint256[](redemptionsLength);
        layout.claimCalls = new uint256[](0);
        (uint256 remaining, uint256 funded, Snapshot memory afterRepay) = _recoverCash(builder, config, layout);

        uint256 gap = _need(builder, config, afterRepay);
        uint256 pending = builder.literal(0);
        for (uint256 i; i < redemptionsLength; ++i) {
            pending = builder.binary(
                OP_ADD,
                pending,
                _readIf(
                    builder,
                    config.redemptions[i].pending,
                    config.skipUnusedReads ? builder.binary(OP_MIN, gap, remaining) : 1
                )
            );
        }
        gap = builder.binary(OP_MIN, builder.binary(OP_SATURATING_SUB, gap, pending), remaining);
        uint256 initialGap = gap;

        for (uint256 i; i < redemptionsLength; ++i) {
            (gap, layout.requestCalls[i]) = _request(builder, config, config.redemptions[i], gap);
        }

        Snapshot memory finalState = _snapshot(builder, config);
        builder.check(OP_LESS_OR_EQUAL, afterRepay.health, finalState.health);
        builder.check(OP_EQUAL, afterRepay.debt, finalState.debt);
        builder.check(OP_EQUAL, afterRepay.cash, finalState.cash);
        uint256 progress = builder.binary(OP_SUB, initialGap, gap);
        progress = builder.binary(OP_ADD, funded, progress);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), progress);
        recipe = builder.finish();
    }

    /**
     * @notice Builds a claim-and-repay recipe that remains executable after health has recovered.
     * @dev Claimable and pending reads measure principal, while repayment uses actual fresh cash.
     * maxAmount bounds each selected claim; zero selects all ready principal. An omitted pending query
     * instead requires the readiness query to decrease by the selected principal for the same requests.
     * minAssetPerClaimWad bounds received raw asset units per claimed principal unit, scaled by 1e18.
     * Each claim compiles as a ClaimRecipe group settling in the debt asset, followed by the shared repayment.
     * Existing cash remains untouched; cash exceeding the current target need or budget stays available.
     */
    function claim(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        uint256 length = config.claims.length;
        ExecutingRecipe.Builder memory builder = _start(config, 64 + 14 * length);
        Snapshot memory initial = _snapshot(builder, config);
        layout.sourceCalls = new uint256[](0);
        layout.requestCalls = new uint256[](0);
        layout.claimCalls = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            layout.claimCalls[i] = ClaimRecipe.group(builder, config.account, _claimGroup(config, config.claims[i]));
        }

        Snapshot memory beforeRepay = _snapshot(builder, config);
        builder.check(OP_LESS_OR_EQUAL, initial.health, beforeRepay.health);
        builder.check(OP_EQUAL, initial.debt, beforeRepay.debt);
        uint256 freshCash = builder.binary(OP_SUB, beforeRepay.cash, initial.cash);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), freshCash);
        uint256 amount = builder.binary(
            OP_MIN,
            builder.binary(OP_MIN, freshCash, _need(builder, config, beforeRepay)),
            builder.literal(config.maxRepayment)
        );
        _repay(builder, config, amount, beforeRepay, layout);
        recipe = builder.finish();
    }

    /**
     * @notice Builds bounded repayment from cash received before this run, preserving a configured reserve.
     * @dev Use after pushed payouts or earlier claims. No request or claim call is executed. Repayment is
     * capped by live target-health need and maxRepayment, and does not require health below the trigger.
     * @param config Position, repayment permissions and limits.
     * @param minCashBalance Cash in raw asset units that must remain in the account.
     */
    function repay(Config memory config, uint256 minCashBalance)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = _start(config, 64);
        Snapshot memory initial = _snapshot(builder, config);
        uint256 amount = builder.binary(
            OP_MIN,
            builder.binary(
                OP_MIN,
                builder.binary(OP_SATURATING_SUB, initial.cash, builder.literal(minCashBalance)),
                _need(builder, config, initial)
            ),
            builder.literal(config.maxRepayment)
        );
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), amount);
        _repay(builder, config, amount, initial, layout);
        recipe = builder.finish();
    }

    /// @dev Kept separate from recovery so its cash locals do not exceed the stack limit.
    function _recoverCash(ExecutingRecipe.Builder memory builder, Config memory config, Layout memory layout)
        private
        pure
        returns (uint256 remaining, uint256 funded, Snapshot memory afterRepay)
    {
        Snapshot memory initial;
        initial.health = _read(builder, config.healthFactor);
        builder.check(OP_LESS_OR_EQUAL, initial.health, builder.literal(config.triggerHealthFactor));
        initial.debt = _read(builder, config.debt);
        initial.cash = builder.balance(config.asset, config.account);
        // Budget and the part of it covered by held cash; memory keeps both off the stack.
        uint256[2] memory plan;
        plan[0] = builder.binary(
            OP_MIN,
            builder.binary(
                OP_SUB,
                initial.debt,
                builder.mulDiv(initial.debt, initial.health, builder.literal(config.targetHealthFactor))
            ),
            builder.literal(config.maxRepayment)
        );
        plan[1] = builder.binary(OP_MIN, plan[0], initial.cash);
        uint256 cash;
        (remaining, cash) = _sources(builder, config, layout, builder.binary(OP_SUB, plan[0], plan[1]), initial.cash);

        Snapshot memory beforeRepay = config.skipUnusedReads && config.sources.length > 0
            ? _snapshot(builder, config, cash)
            : _snapshot(builder, config);
        builder.check(OP_LESS_OR_EQUAL, initial.health, beforeRepay.health);
        builder.check(OP_EQUAL, initial.debt, beforeRepay.debt);
        funded = builder.binary(OP_SUB, plan[0], remaining);
        afterRepay = _repay(builder, config, funded, beforeRepay, layout);
        builder.check(OP_EQUAL, afterRepay.cash, builder.binary(OP_SUB, initial.cash, plan[1]));
    }

    function _sources(
        ExecutingRecipe.Builder memory builder,
        Config memory config,
        Layout memory layout,
        uint256 remaining,
        uint256 cash
    ) private pure returns (uint256, uint256) {
        layout.sourceCalls = new uint256[](config.sources.length);
        for (uint256 i; i < config.sources.length; ++i) {
            (remaining, layout.sourceCalls[i], cash) = _source(builder, config, config.sources[i], remaining, cash);
        }
        return (remaining, cash);
    }

    function _source(
        ExecutingRecipe.Builder memory builder,
        Config memory config,
        Source memory source,
        uint256 remaining,
        uint256 previousCash
    ) private pure returns (uint256 remainingAfter, uint256 callIndex, uint256 cashAfter) {
        uint256 take = builder.binary(
            OP_MIN, remaining, _readIf(builder, source.capacity, config.skipUnusedReads ? remaining : 1)
        );
        if (!config.skipUnusedReads) previousCash = builder.balance(config.asset, config.account);
        callIndex = builder.manage(take, source.leaves, ExecutingRecipe.amountBindings(source.amountOffsets, take));
        cashAfter = config.skipUnusedReads
            ? builder.readIf(ExecutingRecipe.balanceQuery(config.asset, config.account), take, previousCash)
            : builder.balance(config.asset, config.account);
        builder.check(OP_EQUAL, builder.binary(OP_SUB, cashAfter, previousCash), take);
        remainingAfter = builder.binary(OP_SUB, remaining, take);
    }

    function _request(
        ExecutingRecipe.Builder memory builder,
        Config memory config,
        Redemption memory redemption,
        uint256 gap
    ) private pure returns (uint256 gapAfter, uint256 callIndex) {
        if (redemption.maxTokenPerAssetWad == 0) revert InvalidConfiguration();
        uint256 take =
            builder.binary(OP_MIN, gap, _readIf(builder, redemption.capacity, config.skipUnusedReads ? gap : 1));
        uint256 maximum = builder.mulDiv(take, builder.literal(redemption.maxTokenPerAssetWad), builder.literal(1e18));
        uint256 gate = config.skipUnusedReads ? take : 1;
        uint256[2] memory beforeValues;
        beforeValues[0] = _readIf(builder, redemption.pending, gate);
        beforeValues[1] = _balanceIf(builder, redemption.token, config.account, gate);
        callIndex = builder.manage(
            take,
            redemption.leaves,
            ExecutingRecipe.joinBindings(
                ExecutingRecipe.amountBindings(redemption.amountOffsets, take),
                ExecutingRecipe.joinBindings(
                    ExecutingRecipe.amountBindings(redemption.approvalAmountOffsets, maximum),
                    ExecutingRecipe.amountBindings(redemption.clearApprovalAmountOffsets, builder.literal(0))
                )
            )
        );
        builder.check(
            OP_EQUAL, builder.binary(OP_SUB, _readIf(builder, redemption.pending, gate), beforeValues[0]), take
        );
        beforeValues[1] =
            builder.binary(OP_SUB, beforeValues[1], _balanceIf(builder, redemption.token, config.account, gate));
        builder.check(OP_LESS_OR_EQUAL, beforeValues[1], maximum);
        builder.check(
            OP_EQUAL,
            _readIf(
                builder,
                Read({
                    target: redemption.token,
                    data: abi.encodeCall(IERC20.allowance, (config.account, redemption.spender)),
                    offset: 0
                }),
                1
            ),
            builder.literal(0)
        );
        gapAfter = builder.binary(OP_SUB, gap, take);
    }

    function _claimGroup(Config memory config, Claim memory claimConfig)
        private
        pure
        returns (ClaimRecipe.Claim memory group)
    {
        group.claimable = _query(claimConfig.claimable);
        group.selectedId = ExecutingRecipe.Read({
            target: claimConfig.selectedId.target,
            data: claimConfig.selectedId.data,
            offset: claimConfig.selectedId.offset
        });
        group.claimableIdOffsets = claimConfig.claimableIdOffsets;
        group.idOffsets = claimConfig.idOffsets;
        group.maxAmount = claimConfig.maxAmount;
        group.leaves = claimConfig.leaves;
        group.amountOffsets = claimConfig.amountOffsets;
        group.outputs = new ClaimRecipe.Output[](1);
        group.outputs[0] = ClaimRecipe.Output({
            token: config.asset,
            balance: ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
            minimum: ExecutingRecipe.Read({
                target: claimConfig.minimum.target, data: claimConfig.minimum.data, offset: claimConfig.minimum.offset
            }),
            minNumerator: claimConfig.minAssetPerClaimWad,
            denominator: 1e18
        });
        group.pending = _query(claimConfig.pending);
        group.pendingIdOffsets = claimConfig.pendingIdOffsets;
        // Without a pending ledger, readiness must fall by exactly the claimed principal.
        group.exactDebit = true;
    }

    function _start(Config memory config, uint256 capacity)
        private
        pure
        returns (ExecutingRecipe.Builder memory builder)
    {
        if (
            config.triggerHealthFactor == 0 || config.targetHealthFactor <= config.triggerHealthFactor
                || config.maxRepayment == 0 || config.debtTolerance > 1
        ) revert InvalidConfiguration();
        builder = ExecutingRecipe.start(capacity);
    }

    function _snapshot(ExecutingRecipe.Builder memory builder, Config memory config)
        private
        pure
        returns (Snapshot memory state)
    {
        state.health = _read(builder, config.healthFactor);
        state.debt = _read(builder, config.debt);
        state.cash = builder.balance(config.asset, config.account);
    }

    function _snapshot(ExecutingRecipe.Builder memory builder, Config memory config, uint256 cash)
        private
        pure
        returns (Snapshot memory state)
    {
        state.health = _read(builder, config.healthFactor);
        state.debt = _read(builder, config.debt);
        state.cash = cash;
    }

    function _need(ExecutingRecipe.Builder memory builder, Config memory config, Snapshot memory state)
        private
        pure
        returns (uint256)
    {
        return builder.binary(
            OP_SUB,
            state.debt,
            builder.mulDiv(
                state.debt,
                builder.binary(OP_MIN, state.health, builder.literal(config.targetHealthFactor)),
                builder.literal(config.targetHealthFactor)
            )
        );
    }

    function _repay(
        ExecutingRecipe.Builder memory builder,
        Config memory config,
        uint256 amount,
        Snapshot memory beforeRepay,
        Layout memory layout
    ) private pure returns (Snapshot memory afterRepay) {
        layout.approve = _approve(builder, config, amount);
        uint256[2] memory delta;
        delta[0] = builder.balance(config.asset, config.account);
        delta[1] = _read(builder, config.debt);
        {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.repayLeaf;
            uint256[][] memory bindings = new uint256[][](1);
            uint256 length = config.repayAmountOffsets.length;
            bindings[0] = new uint256[](length);
            for (uint256 i; i < length; ++i) {
                bindings[0][i] = ExecutingRecipe.binding(config.repayAmountOffsets[i], amount);
            }
            layout.repay = builder.manage(amount, leaves, bindings);
        }
        delta[0] = builder.binary(OP_SUB, delta[0], builder.balance(config.asset, config.account));
        delta[1] = builder.binary(OP_SUB, delta[1], _read(builder, config.debt));
        builder.check(OP_EQUAL, delta[0], amount);
        builder.check(OP_LESS_OR_EQUAL, delta[1], builder.binary(OP_ADD, amount, builder.literal(config.debtTolerance)));
        builder.check(OP_LESS_OR_EQUAL, amount, builder.binary(OP_ADD, delta[1], builder.literal(config.debtTolerance)));
        layout.clearApproval = builder.clearApproval(config.asset, config.repayTarget, config.approvalLeaf);
        afterRepay = _snapshot(builder, config);
        builder.check(OP_LESS_OR_EQUAL, beforeRepay.health, afterRepay.health);
        builder.check(OP_EQUAL, afterRepay.cash, builder.binary(OP_SUB, beforeRepay.cash, delta[0]));
        builder.check(OP_EQUAL, afterRepay.debt, builder.binary(OP_SUB, beforeRepay.debt, delta[1]));
    }

    function _query(Read memory readConfig) private pure returns (ExecutingRecipe.Query memory) {
        return ExecutingRecipe.query(
            ExecutingRecipe.Read({target: readConfig.target, data: readConfig.data, offset: readConfig.offset})
        );
    }

    function _read(ExecutingRecipe.Builder memory builder, Read memory readConfig) private pure returns (uint256) {
        return builder.read(
            ExecutingRecipe.Read({target: readConfig.target, data: readConfig.data, offset: readConfig.offset})
        );
    }

    function _balanceIf(ExecutingRecipe.Builder memory builder, address token, address account, uint256 gate)
        private
        pure
        returns (uint256)
    {
        return gate == 1
            ? builder.balance(token, account)
            : builder.readIf(ExecutingRecipe.balanceQuery(token, account), gate, 0);
    }

    function _readIf(ExecutingRecipe.Builder memory builder, Read memory readConfig, uint256 gate)
        private
        pure
        returns (uint256)
    {
        return builder.readIf(
            ExecutingRecipe.query(
                ExecutingRecipe.Read({target: readConfig.target, data: readConfig.data, offset: readConfig.offset})
            ),
            gate,
            0
        );
    }

    function _approve(ExecutingRecipe.Builder memory builder, Config memory config, uint256 amount)
        private
        pure
        returns (uint256)
    {
        return builder.approve(amount, config.asset, config.repayTarget, config.approvalLeaf);
    }
}

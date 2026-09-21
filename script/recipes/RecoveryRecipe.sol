// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

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
    }

    struct Claim {
        Read claimable;
        Read pending;
        uint256 minAssetPerClaimWad;
        bytes32[] leaves;
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
        Source[] sources;
        Redemption[] redemptions;
        Claim[] claims;
    }

    // Calls and approvals index runtime payloads; numeric Values index instructions.
    struct Layout {
        uint256[] sourceCalls;
        uint256[] requestCalls;
        uint256[] claimCalls;
        uint256 approve;
        uint256 repay;
        uint256 clearApproval;
    }

    struct Snapshot {
        IRecipeExecutor.Value health;
        IRecipeExecutor.Value debt;
        IRecipeExecutor.Value cash;
    }

    /**
     * @notice Builds low-health recovery: exhaust sources in order, repay fresh cash, then queue RWAs.
     * @dev Pending principal only reduces the remaining request gap; it never counts as repayment or
     * improved health. Partial progress is permitted when capacities cannot meet the target. Each rate
     * is raw RWA units per raw repayment-asset unit, scaled by 1e18, including decimal conversion.
     */
    function recovery(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder =
            _start(config, 64 + 8 * config.sources.length + 18 * config.redemptions.length);
        IRecipeExecutor.Value memory remaining;
        IRecipeExecutor.Value memory funded;
        Snapshot memory afterRepay;
        {
            Snapshot memory initial = _snapshot(builder, config);
            builder.check(
                IRecipeExecutor.Operation.LessOrEqual, initial.health, builder.literal(config.triggerHealthFactor)
            );
            IRecipeExecutor.Value memory budget = builder.binary(
                IRecipeExecutor.Operation.Min, _need(builder, config, initial), builder.literal(config.maxRepayment)
            );
            remaining = budget;
            layout.sourceCalls = new uint256[](config.sources.length);
            layout.requestCalls = new uint256[](config.redemptions.length);
            layout.claimCalls = new uint256[](0);

            for (uint256 i; i < config.sources.length; ++i) {
                (remaining, layout.sourceCalls[i]) = _source(builder, config, config.sources[i], remaining);
            }

            Snapshot memory beforeRepay = _snapshot(builder, config);
            builder.check(IRecipeExecutor.Operation.LessOrEqual, initial.health, beforeRepay.health);
            builder.check(IRecipeExecutor.Operation.Equal, initial.debt, beforeRepay.debt);
            funded = builder.binary(IRecipeExecutor.Operation.Sub, budget, remaining);
            afterRepay = _repay(builder, config, funded, beforeRepay, layout);
            builder.check(IRecipeExecutor.Operation.Equal, afterRepay.cash, initial.cash);
        }

        IRecipeExecutor.Value memory gap =
            builder.binary(IRecipeExecutor.Operation.Min, _need(builder, config, afterRepay), remaining);
        IRecipeExecutor.Value memory pending = builder.literal(0);
        for (uint256 i; i < config.redemptions.length; ++i) {
            pending =
                builder.binary(IRecipeExecutor.Operation.Add, pending, _read(builder, config.redemptions[i].pending));
        }
        gap = builder.binary(IRecipeExecutor.Operation.SaturatingSub, gap, pending);
        IRecipeExecutor.Value memory initialGap = gap;

        for (uint256 i; i < config.redemptions.length; ++i) {
            (gap, layout.requestCalls[i]) = _request(builder, config, config.redemptions[i], gap);
        }

        Snapshot memory finalState = _snapshot(builder, config);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, afterRepay.health, finalState.health);
        builder.check(IRecipeExecutor.Operation.Equal, afterRepay.debt, finalState.debt);
        builder.check(IRecipeExecutor.Operation.Equal, afterRepay.cash, finalState.cash);
        IRecipeExecutor.Value memory progress = builder.binary(IRecipeExecutor.Operation.Sub, initialGap, gap);
        progress = builder.binary(IRecipeExecutor.Operation.Add, funded, progress);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, builder.literal(1), progress);
        recipe = builder.finish();
    }

    /**
     * @notice Builds a claim-and-repay recipe that remains executable after health has recovered.
     * @dev Claimable and pending reads measure principal, while repayment uses actual fresh cash.
     * minAssetPerClaimWad bounds received raw asset units per claimed principal unit, scaled by 1e18.
     * Existing cash remains untouched; cash exceeding the current target need or budget stays available.
     */
    function claim(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = _start(config, 64 + 14 * config.claims.length);
        Snapshot memory initial = _snapshot(builder, config);
        layout.sourceCalls = new uint256[](0);
        layout.requestCalls = new uint256[](0);
        layout.claimCalls = new uint256[](config.claims.length);
        for (uint256 i; i < config.claims.length; ++i) {
            layout.claimCalls[i] = _claim(builder, config, config.claims[i]);
        }

        Snapshot memory beforeRepay = _snapshot(builder, config);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, initial.health, beforeRepay.health);
        builder.check(IRecipeExecutor.Operation.Equal, initial.debt, beforeRepay.debt);
        IRecipeExecutor.Value memory freshCash =
            builder.binary(IRecipeExecutor.Operation.Sub, beforeRepay.cash, initial.cash);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, builder.literal(1), freshCash);
        IRecipeExecutor.Value memory amount = builder.binary(
            IRecipeExecutor.Operation.Min,
            builder.binary(IRecipeExecutor.Operation.Min, freshCash, _need(builder, config, beforeRepay)),
            builder.literal(config.maxRepayment)
        );
        Snapshot memory afterRepay = _repay(builder, config, amount, beforeRepay, layout);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, initial.cash, afterRepay.cash);
        recipe = builder.finish();
    }

    function _source(
        ExecutingRecipe.Builder memory builder,
        Config memory config,
        Source memory source,
        IRecipeExecutor.Value memory remaining
    ) private pure returns (IRecipeExecutor.Value memory remainingAfter, uint256 callIndex) {
        IRecipeExecutor.Value memory take =
            builder.binary(IRecipeExecutor.Operation.Min, remaining, _read(builder, source.capacity));
        IRecipeExecutor.Value memory cash = builder.balance(config.asset, config.account);
        callIndex = builder.manage(source.leaves, take, ExecutingRecipe.amountBindings(source.amountOffsets, take));
        builder.check(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Sub, builder.balance(config.asset, config.account), cash),
            take
        );
        remainingAfter = builder.binary(IRecipeExecutor.Operation.Sub, remaining, take);
    }

    function _request(
        ExecutingRecipe.Builder memory builder,
        Config memory config,
        Redemption memory redemption,
        IRecipeExecutor.Value memory gap
    ) private pure returns (IRecipeExecutor.Value memory gapAfter, uint256 callIndex) {
        if (redemption.maxTokenPerAssetWad == 0) revert InvalidConfiguration();
        IRecipeExecutor.Value memory take =
            builder.binary(IRecipeExecutor.Operation.Min, gap, _read(builder, redemption.capacity));
        IRecipeExecutor.Value memory maximum =
            builder.mulDiv(take, builder.literal(redemption.maxTokenPerAssetWad), builder.literal(1e18));
        IRecipeExecutor.Value[2] memory beforeValues;
        beforeValues[0] = _read(builder, redemption.pending);
        beforeValues[1] = builder.balance(redemption.token, config.account);
        callIndex = builder.manage(redemption.leaves, take);
        builder.check(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Sub, _read(builder, redemption.pending), beforeValues[0]),
            take
        );
        beforeValues[1] = builder.binary(
            IRecipeExecutor.Operation.Sub, beforeValues[1], builder.balance(redemption.token, config.account)
        );
        builder.check(IRecipeExecutor.Operation.LessOrEqual, beforeValues[1], maximum);
        builder.check(
            IRecipeExecutor.Operation.Equal,
            _read(
                builder,
                Read({
                    target: redemption.token,
                    data: abi.encodeCall(IERC20.allowance, (config.account, redemption.spender)),
                    offset: 0
                })
            ),
            builder.literal(0)
        );
        gapAfter = builder.binary(IRecipeExecutor.Operation.Sub, gap, take);
    }

    function _claim(ExecutingRecipe.Builder memory builder, Config memory config, Claim memory claimConfig)
        private
        pure
        returns (uint256 callIndex)
    {
        if (claimConfig.minAssetPerClaimWad == 0) revert InvalidConfiguration();
        IRecipeExecutor.Value memory claimable = _read(builder, claimConfig.claimable);
        IRecipeExecutor.Value memory minimum =
            builder.mulDiv(claimable, builder.literal(claimConfig.minAssetPerClaimWad), builder.literal(1e18));
        IRecipeExecutor.Value memory positive =
            builder.binary(IRecipeExecutor.Operation.Min, builder.literal(1), claimable);
        IRecipeExecutor.Value[2] memory beforeValues;
        beforeValues[0] = _read(builder, claimConfig.pending);
        beforeValues[1] = builder.balance(config.asset, config.account);
        callIndex = builder.manage(claimConfig.leaves, claimable);
        builder.check(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Sub, beforeValues[0], _read(builder, claimConfig.pending)),
            claimable
        );
        IRecipeExecutor.Value memory received = builder.binary(
            IRecipeExecutor.Operation.Sub, builder.balance(config.asset, config.account), beforeValues[1]
        );
        builder.check(IRecipeExecutor.Operation.LessOrEqual, positive, received);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, minimum, received);
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

    function _need(ExecutingRecipe.Builder memory builder, Config memory config, Snapshot memory state)
        private
        pure
        returns (IRecipeExecutor.Value memory)
    {
        return builder.binary(
            IRecipeExecutor.Operation.Sub,
            state.debt,
            builder.mulDiv(
                state.debt,
                builder.binary(IRecipeExecutor.Operation.Min, state.health, builder.literal(config.targetHealthFactor)),
                builder.literal(config.targetHealthFactor)
            )
        );
    }

    function _repay(
        ExecutingRecipe.Builder memory builder,
        Config memory config,
        IRecipeExecutor.Value memory amount,
        Snapshot memory beforeRepay,
        Layout memory layout
    ) private pure returns (Snapshot memory afterRepay) {
        layout.approve = _approve(builder, config, amount);
        IRecipeExecutor.Value[2] memory delta;
        delta[0] = builder.balance(config.asset, config.account);
        delta[1] = _read(builder, config.debt);
        {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.repayLeaf;
            IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
            bindings[0] = new IRecipeExecutor.Binding[](config.repayAmountOffsets.length);
            for (uint256 i; i < config.repayAmountOffsets.length; ++i) {
                bindings[0][i] = IRecipeExecutor.Binding({offset: config.repayAmountOffsets[i], value: amount});
            }
            layout.repay = builder.manage(leaves, amount, bindings);
        }
        delta[0] =
            builder.binary(IRecipeExecutor.Operation.Sub, delta[0], builder.balance(config.asset, config.account));
        delta[1] = builder.binary(IRecipeExecutor.Operation.Sub, delta[1], _read(builder, config.debt));
        builder.check(IRecipeExecutor.Operation.Equal, delta[0], amount);
        builder.check(
            IRecipeExecutor.Operation.LessOrEqual,
            delta[1],
            builder.binary(IRecipeExecutor.Operation.Add, amount, builder.literal(config.debtTolerance))
        );
        builder.check(
            IRecipeExecutor.Operation.LessOrEqual,
            amount,
            builder.binary(IRecipeExecutor.Operation.Add, delta[1], builder.literal(config.debtTolerance))
        );
        layout.clearApproval = _approve(builder, config, builder.literal(0));
        afterRepay = _snapshot(builder, config);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, beforeRepay.health, afterRepay.health);
        builder.check(
            IRecipeExecutor.Operation.Equal,
            afterRepay.cash,
            builder.binary(IRecipeExecutor.Operation.Sub, beforeRepay.cash, delta[0])
        );
        builder.check(
            IRecipeExecutor.Operation.Equal,
            afterRepay.debt,
            builder.binary(IRecipeExecutor.Operation.Sub, beforeRepay.debt, delta[1])
        );
    }

    function _read(ExecutingRecipe.Builder memory builder, Read memory readConfig)
        private
        pure
        returns (IRecipeExecutor.Value memory)
    {
        return builder.read(
            ExecutingRecipe.Read({target: readConfig.target, data: readConfig.data, offset: readConfig.offset})
        );
    }

    function _approve(ExecutingRecipe.Builder memory builder, Config memory config, IRecipeExecutor.Value memory amount)
        private
        pure
        returns (uint256)
    {
        return builder.approve(config.asset, config.repayTarget, config.approvalLeaf, amount);
    }
}

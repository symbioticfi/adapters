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

    struct Builder {
        ExecutingRecipe.Builder execution;
        IRecipeExecutor.Value target;
        IRecipeExecutor.Value limit;
        IRecipeExecutor.Value tolerance;
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
        Builder memory builder = _start(config, 64 + 8 * config.sources.length + 18 * config.redemptions.length);
        IRecipeExecutor.Value memory remaining;
        IRecipeExecutor.Value memory funded;
        Snapshot memory afterRepay;
        {
            Snapshot memory initial = _snapshot(builder, config);
            _check(
                builder,
                IRecipeExecutor.Operation.LessOrEqual,
                initial.health,
                _constant(builder, config.triggerHealthFactor)
            );
            IRecipeExecutor.Value memory budget =
                _binary(builder, IRecipeExecutor.Operation.Min, _need(builder, initial), builder.limit);
            remaining = budget;
            layout.sourceCalls = new uint256[](config.sources.length);
            layout.requestCalls = new uint256[](config.redemptions.length);
            layout.claimCalls = new uint256[](0);

            for (uint256 i; i < config.sources.length; ++i) {
                (remaining, layout.sourceCalls[i]) = _source(builder, config, config.sources[i], remaining);
            }

            Snapshot memory beforeRepay = _snapshot(builder, config);
            _check(builder, IRecipeExecutor.Operation.LessOrEqual, initial.health, beforeRepay.health);
            _check(builder, IRecipeExecutor.Operation.Equal, initial.debt, beforeRepay.debt);
            funded = _binary(builder, IRecipeExecutor.Operation.Sub, budget, remaining);
            afterRepay = _repay(builder, config, funded, beforeRepay, layout);
            _check(builder, IRecipeExecutor.Operation.Equal, afterRepay.cash, initial.cash);
        }

        IRecipeExecutor.Value memory gap =
            _binary(builder, IRecipeExecutor.Operation.Min, _need(builder, afterRepay), remaining);
        IRecipeExecutor.Value memory pending = _constant(builder, 0);
        for (uint256 i; i < config.redemptions.length; ++i) {
            pending =
                _binary(builder, IRecipeExecutor.Operation.Add, pending, _read(builder, config.redemptions[i].pending));
        }
        gap = _binary(builder, IRecipeExecutor.Operation.SaturatingSub, gap, pending);
        IRecipeExecutor.Value memory initialGap = gap;

        for (uint256 i; i < config.redemptions.length; ++i) {
            (gap, layout.requestCalls[i]) = _request(builder, config, config.redemptions[i], gap);
        }

        Snapshot memory finalState = _snapshot(builder, config);
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, afterRepay.health, finalState.health);
        _check(builder, IRecipeExecutor.Operation.Equal, afterRepay.debt, finalState.debt);
        _check(builder, IRecipeExecutor.Operation.Equal, afterRepay.cash, finalState.cash);
        IRecipeExecutor.Value memory progress = _binary(builder, IRecipeExecutor.Operation.Sub, initialGap, gap);
        progress = _binary(builder, IRecipeExecutor.Operation.Add, funded, progress);
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, _constant(builder, 1), progress);
        recipe = _finish(builder);
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
        Builder memory builder = _start(config, 64 + 14 * config.claims.length);
        Snapshot memory initial = _snapshot(builder, config);
        layout.sourceCalls = new uint256[](0);
        layout.requestCalls = new uint256[](0);
        layout.claimCalls = new uint256[](config.claims.length);
        for (uint256 i; i < config.claims.length; ++i) {
            layout.claimCalls[i] = _claim(builder, config, config.claims[i]);
        }

        Snapshot memory beforeRepay = _snapshot(builder, config);
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, initial.health, beforeRepay.health);
        _check(builder, IRecipeExecutor.Operation.Equal, initial.debt, beforeRepay.debt);
        IRecipeExecutor.Value memory freshCash =
            _binary(builder, IRecipeExecutor.Operation.Sub, beforeRepay.cash, initial.cash);
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, _constant(builder, 1), freshCash);
        IRecipeExecutor.Value memory amount = _binary(
            builder,
            IRecipeExecutor.Operation.Min,
            _binary(builder, IRecipeExecutor.Operation.Min, freshCash, _need(builder, beforeRepay)),
            builder.limit
        );
        Snapshot memory afterRepay = _repay(builder, config, amount, beforeRepay, layout);
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, initial.cash, afterRepay.cash);
        recipe = _finish(builder);
    }

    function _source(
        Builder memory builder,
        Config memory config,
        Source memory source,
        IRecipeExecutor.Value memory remaining
    ) private pure returns (IRecipeExecutor.Value memory remainingAfter, uint256 callIndex) {
        IRecipeExecutor.Value memory take =
            _binary(builder, IRecipeExecutor.Operation.Min, remaining, _read(builder, source.capacity));
        IRecipeExecutor.Value memory cash = _balance(builder, config.asset, config.account);
        callIndex = _manage(builder, take, source.leaves, ExecutingRecipe.amountBindings(source.amountOffsets, take));
        _check(
            builder,
            IRecipeExecutor.Operation.Equal,
            _binary(builder, IRecipeExecutor.Operation.Sub, _balance(builder, config.asset, config.account), cash),
            take
        );
        remainingAfter = _binary(builder, IRecipeExecutor.Operation.Sub, remaining, take);
    }

    function _request(
        Builder memory builder,
        Config memory config,
        Redemption memory redemption,
        IRecipeExecutor.Value memory gap
    ) private pure returns (IRecipeExecutor.Value memory gapAfter, uint256 callIndex) {
        if (redemption.maxTokenPerAssetWad == 0) revert InvalidConfiguration();
        IRecipeExecutor.Value memory take =
            _binary(builder, IRecipeExecutor.Operation.Min, gap, _read(builder, redemption.capacity));
        IRecipeExecutor.Value memory maximum =
            _mulDiv(builder, take, _constant(builder, redemption.maxTokenPerAssetWad), _constant(builder, 1e18));
        IRecipeExecutor.Value[2] memory beforeValues;
        beforeValues[0] = _read(builder, redemption.pending);
        beforeValues[1] = _balance(builder, redemption.token, config.account);
        callIndex = _manage(builder, take, redemption.leaves);
        _check(
            builder,
            IRecipeExecutor.Operation.Equal,
            _binary(builder, IRecipeExecutor.Operation.Sub, _read(builder, redemption.pending), beforeValues[0]),
            take
        );
        beforeValues[1] = _binary(
            builder, IRecipeExecutor.Operation.Sub, beforeValues[1], _balance(builder, redemption.token, config.account)
        );
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, beforeValues[1], maximum);
        _check(
            builder,
            IRecipeExecutor.Operation.Equal,
            _read(
                builder,
                Read({
                    target: redemption.token,
                    data: abi.encodeCall(IERC20.allowance, (config.account, redemption.spender)),
                    offset: 0
                })
            ),
            _constant(builder, 0)
        );
        gapAfter = _binary(builder, IRecipeExecutor.Operation.Sub, gap, take);
    }

    function _claim(Builder memory builder, Config memory config, Claim memory claimConfig)
        private
        pure
        returns (uint256 callIndex)
    {
        if (claimConfig.minAssetPerClaimWad == 0) revert InvalidConfiguration();
        IRecipeExecutor.Value memory claimable = _read(builder, claimConfig.claimable);
        IRecipeExecutor.Value memory minimum =
            _mulDiv(builder, claimable, _constant(builder, claimConfig.minAssetPerClaimWad), _constant(builder, 1e18));
        IRecipeExecutor.Value memory positive =
            _binary(builder, IRecipeExecutor.Operation.Min, _constant(builder, 1), claimable);
        IRecipeExecutor.Value[2] memory beforeValues;
        beforeValues[0] = _read(builder, claimConfig.pending);
        beforeValues[1] = _balance(builder, config.asset, config.account);
        callIndex = _manage(builder, claimable, claimConfig.leaves);
        _check(
            builder,
            IRecipeExecutor.Operation.Equal,
            _binary(builder, IRecipeExecutor.Operation.Sub, beforeValues[0], _read(builder, claimConfig.pending)),
            claimable
        );
        IRecipeExecutor.Value memory received = _binary(
            builder, IRecipeExecutor.Operation.Sub, _balance(builder, config.asset, config.account), beforeValues[1]
        );
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, positive, received);
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, minimum, received);
    }

    function _start(Config memory config, uint256 capacity) private pure returns (Builder memory builder) {
        if (
            config.triggerHealthFactor == 0 || config.targetHealthFactor <= config.triggerHealthFactor
                || config.maxRepayment == 0 || config.debtTolerance > 1
        ) revert InvalidConfiguration();
        builder.execution = ExecutingRecipe.start(capacity);
        builder.target = _constant(builder, config.targetHealthFactor);
        builder.limit = _constant(builder, config.maxRepayment);
        builder.tolerance = _constant(builder, config.debtTolerance);
    }

    function _snapshot(Builder memory builder, Config memory config) private pure returns (Snapshot memory state) {
        state.health = _read(builder, config.healthFactor);
        state.debt = _read(builder, config.debt);
        state.cash = _balance(builder, config.asset, config.account);
    }

    function _need(Builder memory builder, Snapshot memory state) private pure returns (IRecipeExecutor.Value memory) {
        return _binary(
            builder,
            IRecipeExecutor.Operation.Sub,
            state.debt,
            _mulDiv(
                builder,
                state.debt,
                _binary(builder, IRecipeExecutor.Operation.Min, state.health, builder.target),
                builder.target
            )
        );
    }

    function _repay(
        Builder memory builder,
        Config memory config,
        IRecipeExecutor.Value memory amount,
        Snapshot memory beforeRepay,
        Layout memory layout
    ) private pure returns (Snapshot memory afterRepay) {
        layout.approve = _approve(builder, config, amount);
        IRecipeExecutor.Value[2] memory delta;
        delta[0] = _balance(builder, config.asset, config.account);
        delta[1] = _read(builder, config.debt);
        {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.repayLeaf;
            IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
            bindings[0] = new IRecipeExecutor.Binding[](config.repayAmountOffsets.length);
            for (uint256 i; i < config.repayAmountOffsets.length; ++i) {
                bindings[0][i] = IRecipeExecutor.Binding({offset: config.repayAmountOffsets[i], value: amount});
            }
            layout.repay = _manage(builder, amount, leaves, bindings);
        }
        delta[0] =
            _binary(builder, IRecipeExecutor.Operation.Sub, delta[0], _balance(builder, config.asset, config.account));
        delta[1] = _binary(builder, IRecipeExecutor.Operation.Sub, delta[1], _read(builder, config.debt));
        _check(builder, IRecipeExecutor.Operation.Equal, delta[0], amount);
        _check(
            builder,
            IRecipeExecutor.Operation.LessOrEqual,
            delta[1],
            _binary(builder, IRecipeExecutor.Operation.Add, amount, builder.tolerance)
        );
        _check(
            builder,
            IRecipeExecutor.Operation.LessOrEqual,
            amount,
            _binary(builder, IRecipeExecutor.Operation.Add, delta[1], builder.tolerance)
        );
        layout.clearApproval = _approve(builder, config, _constant(builder, 0));
        afterRepay = _snapshot(builder, config);
        _check(builder, IRecipeExecutor.Operation.LessOrEqual, beforeRepay.health, afterRepay.health);
        _check(
            builder,
            IRecipeExecutor.Operation.Equal,
            afterRepay.cash,
            _binary(builder, IRecipeExecutor.Operation.Sub, beforeRepay.cash, delta[0])
        );
        _check(
            builder,
            IRecipeExecutor.Operation.Equal,
            afterRepay.debt,
            _binary(builder, IRecipeExecutor.Operation.Sub, beforeRepay.debt, delta[1])
        );
    }

    function _constant(Builder memory, uint256 value) private pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Literal, value: value});
    }

    function _read(Builder memory builder, Read memory readConfig) private pure returns (IRecipeExecutor.Value memory) {
        return builder.execution
            .read(ExecutingRecipe.Read({target: readConfig.target, data: readConfig.data, offset: readConfig.offset}));
    }

    function _balance(Builder memory builder, address token, address account)
        private
        pure
        returns (IRecipeExecutor.Value memory)
    {
        return builder.execution.balance(token, account);
    }

    function _binary(
        Builder memory builder,
        IRecipeExecutor.Operation operation,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) private pure returns (IRecipeExecutor.Value memory) {
        return builder.execution.binary(operation, a, b);
    }

    function _check(
        Builder memory builder,
        IRecipeExecutor.Operation comparison,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) private pure {
        builder.execution.check(comparison, a, b);
    }

    function _mulDiv(
        Builder memory builder,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b,
        IRecipeExecutor.Value memory c
    ) private pure returns (IRecipeExecutor.Value memory) {
        return builder.execution.mulDiv(a, b, c);
    }

    function _manage(Builder memory builder, IRecipeExecutor.Value memory guard, bytes32[] memory leaves)
        private
        pure
        returns (uint256)
    {
        return builder.execution.manage(leaves, guard);
    }

    function _manage(
        Builder memory builder,
        IRecipeExecutor.Value memory guard,
        bytes32[] memory leaves,
        IRecipeExecutor.Binding[][] memory bindings
    ) private pure returns (uint256) {
        return builder.execution.manage(leaves, guard, bindings);
    }

    function _approve(Builder memory builder, Config memory config, IRecipeExecutor.Value memory amount)
        private
        pure
        returns (uint256)
    {
        return builder.execution.approve(config.asset, config.repayTarget, config.approvalLeaf, amount);
    }

    function _finish(Builder memory builder) private pure returns (ExecutingRecipe.Recipe memory) {
        return builder.execution.finish();
    }
}

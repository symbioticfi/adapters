// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RecoveryRecipe
 * @notice Library for ordered liquidity recovery and later redemption claims against one debt asset.
 * @dev This is an offchain recipe builder, not a scheduler. All amounts are computed from live reads;
 * execution inputs are empty, and runtime supplies only the committed groups' actions and permissions.
 * Withdrawals must come from positions that do not collateralize this debt. The health-based repayment
 * formula assumes unchanged collateral and one debt asset. Reads must normalize debt, capacities,
 * pending principal and claimable principal to raw repayment-asset units; health uses 1e18 precision.
 * Issuer queries are protocol-specific: fixture getters are not a universal issuer API. Capacity reads
 * must exclude already committed holdings, and pending reads must cover distinct outstanding requests.
 */
library RecoveryRecipe {
    error InvalidConfiguration();

    struct Read {
        address target;
        bytes data;
        uint256 offset;
    }

    struct Source {
        Read capacity;
        bytes32[] leaves;
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
        address adapter;
        address asset;
        address repayTarget;
        bytes32 approvalLeaf;
        bytes32 repayLeaf;
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

    struct Layout {
        uint256[] sourceCalls;
        uint256[] requestCalls;
        uint256[] claimCalls;
        uint256 approve;
        uint256 repay;
        uint256 clearApproval;
    }

    struct Builder {
        IRecipeExecutor.Step[] recipe;
        uint256 length;
    }

    struct Snapshot {
        uint256 health;
        uint256 debt;
        uint256 cash;
    }

    // These are result indices initialized by _start, not runtime amounts.
    uint256 internal constant ZERO = 0;
    uint256 internal constant ONE = 1;
    uint256 internal constant WAD = 2;
    uint256 internal constant TARGET = 3;
    uint256 internal constant LIMIT = 4;
    uint256 internal constant TOLERANCE = 5;

    /**
     * @notice Builds low-health recovery: exhaust sources in order, repay fresh cash, then queue RWAs.
     * @dev Pending principal only reduces the remaining request gap; it never counts as repayment or
     * improved health. Partial progress is permitted when capacities cannot meet the target. Each rate
     * is raw RWA units per raw repayment-asset unit, scaled by 1e18, including decimal conversion.
     */
    function recovery(Config memory config)
        internal
        pure
        returns (IRecipeExecutor.Step[] memory recipe, Layout memory layout)
    {
        Builder memory builder = _start(config, 64 + 8 * config.sources.length + 18 * config.redemptions.length);
        uint256 remaining;
        uint256 funded;
        Snapshot memory afterRepay;
        {
            Snapshot memory initial = _snapshot(builder, config);
            _binary(
                builder,
                IRecipeExecutor.Operation.LessOrEqual,
                initial.health,
                _constant(builder, config.triggerHealthFactor)
            );
            uint256 budget = _binary(builder, IRecipeExecutor.Operation.Minimum, _need(builder, initial), LIMIT);
            remaining = budget;
            layout.sourceCalls = new uint256[](config.sources.length);
            layout.requestCalls = new uint256[](config.redemptions.length);
            layout.claimCalls = new uint256[](0);

            for (uint256 i; i < config.sources.length; ++i) {
                (remaining, layout.sourceCalls[i]) = _source(builder, config, config.sources[i], remaining);
            }

            Snapshot memory beforeRepay = _snapshot(builder, config);
            _binary(builder, IRecipeExecutor.Operation.LessOrEqual, initial.health, beforeRepay.health);
            _binary(builder, IRecipeExecutor.Operation.Equal, initial.debt, beforeRepay.debt);
            funded = _binary(builder, IRecipeExecutor.Operation.Subtract, budget, remaining);
            afterRepay = _repay(builder, config, funded, beforeRepay, layout);
            _binary(builder, IRecipeExecutor.Operation.Equal, afterRepay.cash, initial.cash);
        }

        uint256 gap = _binary(builder, IRecipeExecutor.Operation.Minimum, _need(builder, afterRepay), remaining);
        uint256 pending = ZERO;
        for (uint256 i; i < config.redemptions.length; ++i) {
            pending =
                _binary(builder, IRecipeExecutor.Operation.Add, pending, _read(builder, config.redemptions[i].pending));
        }
        gap = _binary(
            builder,
            IRecipeExecutor.Operation.Subtract,
            gap,
            _binary(builder, IRecipeExecutor.Operation.Minimum, gap, pending)
        );
        uint256 initialGap = gap;

        for (uint256 i; i < config.redemptions.length; ++i) {
            (gap, layout.requestCalls[i]) = _request(builder, config, config.redemptions[i], gap);
        }

        Snapshot memory finalState = _snapshot(builder, config);
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, afterRepay.health, finalState.health);
        _binary(builder, IRecipeExecutor.Operation.Equal, afterRepay.debt, finalState.debt);
        _binary(builder, IRecipeExecutor.Operation.Equal, afterRepay.cash, finalState.cash);
        uint256 progress = _binary(builder, IRecipeExecutor.Operation.Subtract, initialGap, gap);
        progress = _binary(builder, IRecipeExecutor.Operation.Add, funded, progress);
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, ONE, progress);
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
        returns (IRecipeExecutor.Step[] memory recipe, Layout memory layout)
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
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, initial.health, beforeRepay.health);
        _binary(builder, IRecipeExecutor.Operation.Equal, initial.debt, beforeRepay.debt);
        uint256 freshCash = _binary(builder, IRecipeExecutor.Operation.Subtract, beforeRepay.cash, initial.cash);
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, ONE, freshCash);
        uint256 amount = _binary(
            builder,
            IRecipeExecutor.Operation.Minimum,
            _binary(builder, IRecipeExecutor.Operation.Minimum, freshCash, _need(builder, beforeRepay)),
            LIMIT
        );
        Snapshot memory afterRepay = _repay(builder, config, amount, beforeRepay, layout);
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, initial.cash, afterRepay.cash);
        recipe = _finish(builder);
    }

    function _source(Builder memory builder, Config memory config, Source memory source, uint256 remaining)
        private
        pure
        returns (uint256 remainingAfter, uint256 callIndex)
    {
        uint256 take = _binary(builder, IRecipeExecutor.Operation.Minimum, remaining, _read(builder, source.capacity));
        uint256 beforeCash = _balance(builder, config.asset, config.adapter);
        callIndex = _manage(builder, take, source.leaves);
        uint256 received = _binary(
            builder, IRecipeExecutor.Operation.Subtract, _balance(builder, config.asset, config.adapter), beforeCash
        );
        _binary(builder, IRecipeExecutor.Operation.Equal, received, take);
        remainingAfter = _binary(builder, IRecipeExecutor.Operation.Subtract, remaining, take);
    }

    function _request(Builder memory builder, Config memory config, Redemption memory redemption, uint256 gap)
        private
        pure
        returns (uint256 gapAfter, uint256 callIndex)
    {
        if (redemption.maxTokenPerAssetWad == 0) revert InvalidConfiguration();
        uint256 take = _binary(builder, IRecipeExecutor.Operation.Minimum, gap, _read(builder, redemption.capacity));
        uint256 beforeToken;
        {
            uint256 beforePending = _read(builder, redemption.pending);
            beforeToken = _balance(builder, redemption.token, config.adapter);
            callIndex = _manage(builder, take, redemption.leaves);
            _binary(
                builder,
                IRecipeExecutor.Operation.Equal,
                _read(
                    builder,
                    Read(redemption.token, abi.encodeCall(IERC20.allowance, (config.adapter, redemption.spender)), 0)
                ),
                ZERO
            );
            uint256 added =
                _binary(builder, IRecipeExecutor.Operation.Subtract, _read(builder, redemption.pending), beforePending);
            _binary(builder, IRecipeExecutor.Operation.Equal, added, take);
        }

        uint256 spent = _binary(
            builder,
            IRecipeExecutor.Operation.Subtract,
            beforeToken,
            _balance(builder, redemption.token, config.adapter)
        );
        uint256 maximum = _constant(builder, redemption.maxTokenPerAssetWad);
        maximum = _mulDiv(builder, take, maximum, WAD);
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, spent, maximum);
        gapAfter = _binary(builder, IRecipeExecutor.Operation.Subtract, gap, take);
    }

    function _claim(Builder memory builder, Config memory config, Claim memory claimConfig)
        private
        pure
        returns (uint256 callIndex)
    {
        if (claimConfig.minAssetPerClaimWad == 0) revert InvalidConfiguration();
        uint256 claimable = _read(builder, claimConfig.claimable);
        uint256 beforeCash;
        {
            uint256 beforePending = _read(builder, claimConfig.pending);
            beforeCash = _balance(builder, config.asset, config.adapter);
            callIndex = _manage(builder, claimable, claimConfig.leaves);
            uint256 removed = _binary(
                builder, IRecipeExecutor.Operation.Subtract, beforePending, _read(builder, claimConfig.pending)
            );
            _binary(builder, IRecipeExecutor.Operation.Equal, removed, claimable);
        }

        uint256 received = _binary(
            builder, IRecipeExecutor.Operation.Subtract, _balance(builder, config.asset, config.adapter), beforeCash
        );
        _binary(
            builder,
            IRecipeExecutor.Operation.LessOrEqual,
            _binary(builder, IRecipeExecutor.Operation.Minimum, ONE, claimable),
            received
        );
        uint256 minimum = _constant(builder, claimConfig.minAssetPerClaimWad);
        minimum = _mulDiv(builder, claimable, minimum, WAD);
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, minimum, received);
    }

    function _start(Config memory config, uint256 capacity) private pure returns (Builder memory builder) {
        if (
            config.triggerHealthFactor == 0 || config.targetHealthFactor <= config.triggerHealthFactor
                || config.maxRepayment == 0 || config.debtTolerance > 1
        ) revert InvalidConfiguration();
        builder.recipe = new IRecipeExecutor.Step[](capacity);
        _constant(builder, 0);
        _constant(builder, 1);
        _constant(builder, 1e18);
        _constant(builder, config.targetHealthFactor);
        _constant(builder, config.maxRepayment);
        _constant(builder, config.debtTolerance);
    }

    function _snapshot(Builder memory builder, Config memory config) private pure returns (Snapshot memory state) {
        state.health = _read(builder, config.healthFactor);
        state.debt = _read(builder, config.debt);
        state.cash = _balance(builder, config.asset, config.adapter);
    }

    function _need(Builder memory builder, Snapshot memory state) private pure returns (uint256) {
        return _binary(
            builder,
            IRecipeExecutor.Operation.Subtract,
            state.debt,
            _mulDiv(
                builder, state.debt, _binary(builder, IRecipeExecutor.Operation.Minimum, state.health, TARGET), TARGET
            )
        );
    }

    function _repay(
        Builder memory builder,
        Config memory config,
        uint256 amount,
        Snapshot memory beforeRepay,
        Layout memory layout
    ) private pure returns (Snapshot memory afterRepay) {
        layout.approve = _approve(builder, config, amount);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.repayLeaf;
        layout.repay = _manage(builder, amount, leaves);
        layout.clearApproval = _approve(builder, config, ZERO);
        afterRepay = _snapshot(builder, config);
        _binary(
            builder,
            IRecipeExecutor.Operation.Equal,
            _binary(builder, IRecipeExecutor.Operation.Subtract, beforeRepay.cash, afterRepay.cash),
            amount
        );
        uint256 decrease = _binary(builder, IRecipeExecutor.Operation.Subtract, beforeRepay.debt, afterRepay.debt);
        _binary(
            builder,
            IRecipeExecutor.Operation.LessOrEqual,
            decrease,
            _binary(builder, IRecipeExecutor.Operation.Add, amount, TOLERANCE)
        );
        _binary(
            builder,
            IRecipeExecutor.Operation.LessOrEqual,
            amount,
            _binary(builder, IRecipeExecutor.Operation.Add, decrease, TOLERANCE)
        );
        _binary(builder, IRecipeExecutor.Operation.LessOrEqual, beforeRepay.health, afterRepay.health);
    }

    function _constant(Builder memory builder, uint256 value) private pure returns (uint256) {
        return _append(builder, IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, value, 0, 0, ""));
    }

    function _read(Builder memory builder, Read memory query) private pure returns (uint256) {
        return _append(
            builder,
            IRecipeExecutor.Step(
                IRecipeExecutor.Operation.Read, query.offset, 0, 0, abi.encode(query.target, query.data)
            )
        );
    }

    function _balance(Builder memory builder, address token, address account) private pure returns (uint256) {
        return _read(builder, Read(token, abi.encodeCall(IERC20.balanceOf, (account)), 0));
    }

    function _binary(Builder memory builder, IRecipeExecutor.Operation operation, uint256 a, uint256 b)
        private
        pure
        returns (uint256)
    {
        return _append(builder, IRecipeExecutor.Step(operation, a, b, 0, ""));
    }

    function _mulDiv(Builder memory builder, uint256 a, uint256 b, uint256 c) private pure returns (uint256) {
        return _append(builder, IRecipeExecutor.Step(IRecipeExecutor.Operation.MulDiv, a, b, c, ""));
    }

    function _manage(Builder memory builder, uint256 guard, bytes32[] memory leaves) private pure returns (uint256) {
        return _append(builder, IRecipeExecutor.Step(IRecipeExecutor.Operation.Manage, guard, 0, 0, abi.encode(leaves)));
    }

    function _approve(Builder memory builder, Config memory config, uint256 amount) private pure returns (uint256) {
        return _append(
            builder,
            IRecipeExecutor.Step(
                IRecipeExecutor.Operation.Approve,
                amount,
                0,
                0,
                abi.encode(config.asset, config.repayTarget, config.approvalLeaf)
            )
        );
    }

    function _append(Builder memory builder, IRecipeExecutor.Step memory step) private pure returns (uint256 index) {
        index = builder.length++;
        builder.recipe[index] = step;
    }

    function _finish(Builder memory builder) private pure returns (IRecipeExecutor.Step[] memory recipe) {
        recipe = builder.recipe;
        uint256 length = builder.length;
        // The builder only removes unused capacity; every retained instruction has been initialized.
        assembly ("memory-safe") {
            mstore(recipe, length)
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Executor} from "./Executor.sol";
import {ThreeFPolicy} from "./ThreeFPolicy.sol";

import {IGuardedCallsCapability} from "../../interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IThreeFExecutor} from "../../interfaces/periphery/IThreeFExecutor.sol";
import {IThreeFPolicy} from "../../interfaces/periphery/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "../../interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "../../interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ThreeFExecutor
/// @notice Contract for preparing liquidity and minting adapter-owned 3F positions.
contract ThreeFExecutor is Executor, IThreeFExecutor {
    /* IMMUTABLES */

    /// @inheritdoc IThreeFExecutor
    address public immutable requestsFactory;

    /// @inheritdoc IThreeFExecutor
    address public immutable policy;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAdapter, address newRequestsFactory) Executor(newOwner, newAdapter) {
        requestsFactory = newRequestsFactory;
        policy = address(new ThreeFPolicy(newOwner, address(this)));
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFExecutor
    function mint(address request, uint128 amount, uint128 minYield, uint256 deadline, Execution calldata execution)
        public
        nonReentrant
        onlyCaller
    {
        if (block.timestamp > deadline) revert MintDeadlineExpired();
        if (!IThreeFRequestFactory(requestsFactory).isRequest(request)) revert NotRequest();
        (uint128 principal, uint128 yieldAssets) = IThreeFPushRequest(request).mintAuthorization(adapter);
        if (principal != amount || amount == 0) revert InvalidMintAuthorization();
        IThreeFPolicy(policy).consume(amount, yieldAssets);
        address asset = IERC4626(IMerkleAdapter(adapter).vault()).asset();
        _prepareLiquidity(asset, amount, request, execution);
        uint256 balance = IERC20(asset).balanceOf(adapter);
        IGuardedCallsCapability.Call[] memory calls = new IGuardedCallsCapability.Call[](1);
        calls[0] = IGuardedCallsCapability.Call(
            request, abi.encodeCall(IThreeFPushRequest.mint, (amount, minYield > yieldAssets ? minYield : yieldAssets))
        );
        _call(
            adapter,
            abi.encodeCall(IGuardedCallsCapability.execute, (calls, new IGuardedCallsCapability.Check[](0))),
            execution.operation,
            operationLeaf
        );
        if (IERC20(asset).balanceOf(adapter) != balance - amount) revert OperationBalanceMismatch();

        emit Mint(request, amount);
    }
}

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Executor} from "./Executor.sol";

import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IThreeFCapability} from "../../interfaces/merkle-adapter/capabilities/IThreeFCapability.sol";
import {IThreeFExecutor} from "../../interfaces/periphery/IThreeFExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ThreeFExecutor
/// @notice Contract for preparing liquidity and minting adapter-owned 3F positions.
contract ThreeFExecutor is Executor, IThreeFExecutor {
    /* CONSTRUCTOR */

    constructor(address newOwner, address newAdapter) Executor(newOwner, newAdapter) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFExecutor
    function mint(address request, uint128 amount, uint128 minYield, uint256 deadline, Execution calldata execution)
        public
        nonReentrant
        onlyCaller
    {
        address asset = IERC4626(IMerkleAdapter(adapter).vault()).asset();
        _prepareLiquidity(asset, amount, request, execution);
        uint256 balance = IERC20(asset).balanceOf(adapter);
        _call(
            adapter,
            abi.encodeCall(IThreeFCapability.mintRequest, (request, amount, minYield, deadline)),
            execution.operation,
            operationLeaf
        );
        if (IERC20(asset).balanceOf(adapter) != balance - amount) revert OperationBalanceMismatch();

        emit Mint(request, amount);
    }
}

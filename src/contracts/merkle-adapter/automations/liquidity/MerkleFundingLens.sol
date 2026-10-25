// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IMerkleFundingLens,
    MAX_FUNDING_SOURCES
} from "../../../../interfaces/merkle-adapter/automations/liquidity/IMerkleFundingLens.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MerkleFundingLens
/// @notice Contract for account cash and reviewed synchronous withdrawal capacity.
contract MerkleFundingLens is IMerkleFundingLens {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleFundingLens
    function getAvailableAssets(address account, address asset, Source[] calldata sources)
        public
        view
        returns (uint256 assets)
    {
        if (account == address(0) || asset == address(0)) revert InvalidSource();
        if (sources.length > MAX_FUNDING_SOURCES) revert InvalidSource();
        assets = IERC20(asset).balanceOf(account);
        bytes32[] memory queries = new bytes32[](sources.length);
        for (uint256 i; i < sources.length; ++i) {
            Source calldata source = sources[i];
            if (
                source.id == bytes32(0) || source.target == address(0) || source.data.length < 4
                    || source.offset % 32 > 0
            ) revert InvalidSource();
            queries[i] = keccak256(abi.encode(source.target, source.data));
            for (uint256 j; j < i; ++j) {
                if (source.id == sources[j].id || queries[i] == queries[j]) revert DuplicateSource();
            }
            (bool success, bytes memory result) = source.target.staticcall(source.data);
            if (!success || result.length < 32 || source.offset > result.length - 32) revert SourceReadFailed();
            uint256 capacity;
            uint256 offset = source.offset;
            assembly ("memory-safe") {
                capacity := mload(add(add(result, 32), offset))
            }
            assets += capacity;
        }
    }
}

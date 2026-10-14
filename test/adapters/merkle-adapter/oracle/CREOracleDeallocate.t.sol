// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./CREOracle.t.sol";
import {MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {UniversalDelegator} from "@symbioticfi/core/src/contracts/delegator/UniversalDelegator.sol";

/// @dev Exercises the production delegator's deallocation body with the existing vault fixture.
contract MerkleDeallocationHarness is UniversalDelegator {
    constructor(address newVault) UniversalDelegator(address(0), address(0)) {
        vault = newVault;
    }

    function execute(address adapter, uint256 amount) external returns (uint256) {
        return _deallocate(adapter, amount);
    }
}

contract CREOracleDeallocateTest is CREOracleTestBase {
    MerkleDeallocationHarness internal path;

    function setUp() public override {
        super.setUp();
        _fundPortfolio(100);
        _releasePortfolio(100);
        path = new MerkleDeallocationHarness(adapter.vault());
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(address(path));
    }

    function test_DeallocationChecksFreshnessForPayoutAndDelegatorAccounting() public {
        _assertReportedAssets(100);
        vm.expectCall(address(oracle), abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()), uint64(2));
        assertEq(path.execute(address(adapter), 40), 40);
        assertEq(adapter.netFlow(), 60);
        assertEq(asset.balanceOf(adapter.vault()), 40);
        assertEq(asset.balanceOf(address(adapter)), 60);
    }

    function test_DelayedOracleAllowsDeallocationAndTransfer() public {
        vm.warp(block.timestamp + 365 days);
        assertEq(path.execute(address(adapter), 40), 40);
        assertEq(adapter.totalAssets(), 60);
        oracle.latestSnapshot();
        assertEq(adapter.netFlow(), 60);
        assertEq(adapter.releasedLiquidity(), 60);
        assertEq(adapter.pendingDeallocation(), 60);
        assertEq(asset.balanceOf(adapter.vault()), 40);
        assertEq(asset.balanceOf(address(adapter)), 60);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./CREOracle.t.sol";
import {MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
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

    function test_DeallocationValidatesExactlyOnceThroughDelegatorTotalAssets() public {
        vm.expectCall(address(oracle), abi.encodeCall(IMerkleAdapterOracle.validate, ()), uint64(1));
        assertEq(path.execute(address(adapter), 40), 40);
        assertEq(oracle.totalAssets(), 60);
        assertEq(asset.balanceOf(adapter.vault()), 40);
        assertEq(asset.balanceOf(address(adapter)), 60);
    }

    function testFuzz_InvalidOracleRollsBackDeallocationAndTransfer(bool frozen) public {
        if (frozen) oracle.freezeOracle();
        else vm.warp(block.timestamp + oracle.MAX_ORACLE_AGE() + 1);
        vm.expectRevert(frozen ? ICREOracle.OracleFrozen.selector : ICREOracle.OracleStale.selector);
        path.execute(address(adapter), 40);
        assertEq(oracle.totalAssets(), 100);
        assertEq(asset.balanceOf(adapter.vault()), 0);
        assertEq(asset.balanceOf(address(adapter)), 100);
    }
}

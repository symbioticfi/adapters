// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";
import {MerkleDeallocationHarness} from "./oracle/CREOracleDeallocate.t.sol";
import {MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

contract MerkleAdapterDeallocatableTest is CREOracleTestBase {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        _fundPortfolio(1000);
    }

    function test_ZeroReleaseReturnsZeroWhenNAVIsInvalid() public {
        stdstore.target(address(oracle)).sig("valuationOffset()").checked_write(type(uint256).max - 1000);
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        oracle.totalAssets();

        assertEq(adapter.deallocatable(), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 1000);
    }

    function test_ZeroReleaseSkipsUnavailableCashRead() public {
        vm.mockCallRevert(
            address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), abi.encode("cash read unavailable")
        );
        assertEq(adapter.deallocatable(), 0);
    }

    function test_ReleasedLiquidityStillRejectsInvalidNAV() public {
        _releasePortfolio(200);
        stdstore.target(address(oracle)).sig("valuationOffset()").checked_write(type(uint256).max - 1000);
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        adapter.deallocatable();
    }

    function test_ReleasedLiquidityStillRequiresCashRead() public {
        _releasePortfolio(200);
        bytes memory reason = abi.encode("cash read unavailable");
        vm.mockCallRevert(address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), reason);
        vm.expectRevert(reason);
        adapter.deallocatable();
    }

    function test_ZeroRequestedAmountWithReleaseStillRejectsInvalidNAV() public {
        _releasePortfolio(200);
        stdstore.target(address(oracle)).sig("valuationOffset()").checked_write(type(uint256).max - 1000);

        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        vm.prank(address(delegator));
        adapter.deallocate(0);

        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.pendingDeallocation(), 200);
        assertEq(adapter.netFlow(), 1000);
    }

    function test_ZeroRequestedAmountWithReleaseStillRequiresCashRead() public {
        _releasePortfolio(200);
        bytes memory reason = abi.encode("cash read unavailable");
        vm.mockCallRevert(address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), reason);

        vm.expectRevert(reason);
        vm.prank(address(delegator));
        adapter.deallocate(0);

        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.pendingDeallocation(), 200);
        assertEq(adapter.netFlow(), 1000);
    }

    function test_ZeroReleaseCannotBypassDelegatorNAVValidation() public {
        address path = address(new MerkleDeallocationHarness(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(path);
        stdstore.target(address(oracle)).sig("valuationOffset()").checked_write(type(uint256).max - 1000);

        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        MerkleDeallocationHarness(path).execute(address(adapter), 1000);

        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);
    }
}

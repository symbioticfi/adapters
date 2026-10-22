// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MerkleCapitalFlowFixture} from "./MerkleCapitalFlow.t.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IAdapter} from "src/interfaces/IAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {stdError} from "forge-std/StdError.sol";

contract MerkleAdapterHotPathsTest is MerkleCapitalFlowFixture {
    function test_UnreleasedPayoutAvoidsWritesAndPreservesStaging() public {
        vm.prank(account);
        _fixtureCashToAccount(1000);
        realDelegator.forceDeallocate(address(adapter), 400);
        vm.prank(account);
        adapter.pull(400);

        vm.prank(address(realDelegator));
        (bool success, bytes memory result) =
            address(adapter).staticcall{gas: 200_000}(abi.encodeCall(IAdapter.deallocate, (100)));

        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0);

        assertEq(adapter.stagedLiquidity(), 400);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 400);
        assertEq(asset.balanceOf(account), 600);
    }

    function test_ZeroRequestedAmountAvoidsWritesAndPreservesReleasedLiquidity() public {
        vm.prank(account);
        _fixtureCashToAccount(1000);
        realDelegator.forceDeallocate(address(adapter), 400);
        vm.prank(account);
        adapter.pull(400);
        _deliver(_capturePortfolio());

        vm.prank(address(realDelegator));
        (bool success, bytes memory result) =
            address(adapter).staticcall{gas: 200_000}(abi.encodeCall(IAdapter.deallocate, (0)));

        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0);

        assertEq(adapter.releasedLiquidity(), 400);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 400);
        assertEq(asset.balanceOf(account), 600);
    }

    /// forge-config: default.isolate = true
    function test_UnreleasedPublicDeallocationAndSimulationPreserveAccounting() public {
        uint256 available = realDelegator.deallocatable();
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicSimulationUnreleased");
        assertEq(available, 0);

        uint256 returned = realDelegator.deallocate(address(adapter), 100);
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicDeallocateUnreleased");
        assertEq(returned, 0);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(account), 0);
        assertEq(asset.balanceOf(address(realVault)), 9000);
        assertEq(adapter.netFlow(), 1000);

        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(realVault.totalAssets(), 10_000);
    }

    /// forge-config: default.isolate = true
    function test_ReleasedPublicDeallocationAndSimulationPreserveAccounting() public {
        vm.prank(account);
        _fixtureCashToAccount(1000);
        realDelegator.forceDeallocate(address(adapter), 400);
        vm.prank(account);
        adapter.pull(400);
        _deliver(_capturePortfolio());

        uint256 available = realDelegator.deallocatable();
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicSimulationReleased");
        assertEq(available, 400);
        assertEq(adapter.releasedLiquidity(), 400);
        assertEq(asset.balanceOf(address(adapter)), 400);
        assertEq(asset.balanceOf(account), 600);
        assertEq(asset.balanceOf(address(realVault)), 9000);
        assertEq(adapter.netFlow(), 1000);

        uint256 returned = realDelegator.deallocate(address(adapter), 100);
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicDeallocateReleased");
        assertEq(returned, 100);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(account), 600);
        assertEq(asset.balanceOf(address(realVault)), 9400);
        assertEq(adapter.netFlow(), 600);

        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(realVault.totalAssets(), 10_000);
    }

    /// forge-config: default.isolate = true
    function test_PublicZeroRequestedAmountStillSweepsReleasedLiquidity() public {
        vm.prank(account);
        _fixtureCashToAccount(1000);
        realDelegator.forceDeallocate(address(adapter), 400);
        vm.prank(account);
        adapter.pull(400);
        _deliver(_capturePortfolio());

        uint256 returned = realDelegator.deallocate(address(adapter), 0);
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicDeallocateZeroAmount");
        assertEq(returned, 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(account), 600);
        assertEq(asset.balanceOf(address(realVault)), 9400);
        assertEq(adapter.netFlow(), 600);

        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(realVault.totalAssets(), 10_000);
    }

    function test_PublicZeroPayoutStillRejectsNAVOverflow() public {
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );

        vm.expectRevert(stdError.arithmeticError);
        realDelegator.deallocatable();
        vm.expectRevert(stdError.arithmeticError);
        realDelegator.deallocate(address(adapter), 100);

        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(address(realVault)), 9000);
    }

    /// forge-config: default.isolate = true
}

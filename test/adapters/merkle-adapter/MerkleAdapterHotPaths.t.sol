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
    function test_UnreleasedPayoutAvoidsWritesAndPreservesPendingDemand() public {
        realDelegator.forceDeallocate(address(adapter), 400);

        vm.prank(address(realDelegator));
        (bool success, bytes memory result) =
            address(adapter).staticcall{gas: 200_000}(abi.encodeCall(IAdapter.deallocate, (100)));

        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0);
        assertEq(adapter.pendingDeallocation(), 400);
        assertEq(adapter.stagedLiquidity(), 400);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 1000);
    }

    function test_ZeroRequestedAmountAvoidsWritesAndPreservesReleasedLiquidity() public {
        realDelegator.forceDeallocate(address(adapter), 400);
        _deliver(_capturePortfolio());

        vm.prank(address(realDelegator));
        (bool success, bytes memory result) =
            address(adapter).staticcall{gas: 200_000}(abi.encodeCall(IAdapter.deallocate, (0)));

        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), 0);
        assertEq(adapter.pendingDeallocation(), 400);
        assertEq(adapter.releasedLiquidity(), 400);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 1000);
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
        assertEq(asset.balanceOf(address(realVault)), 9000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(realVault.totalAssets(), 10_000);
    }

    /// forge-config: default.isolate = true
    function test_ReleasedPublicDeallocationAndSimulationPreserveAccounting() public {
        realDelegator.forceDeallocate(address(adapter), 400);
        _deliver(_capturePortfolio());

        uint256 available = realDelegator.deallocatable();
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicSimulationReleased");
        assertEq(available, 400);
        assertEq(adapter.releasedLiquidity(), 400);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(address(realVault)), 9000);
        assertEq(adapter.netFlow(), 1000);

        uint256 returned = realDelegator.deallocate(address(adapter), 100);
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicDeallocateReleased");
        assertEq(returned, 100);
        assertEq(asset.balanceOf(address(adapter)), 600);
        assertEq(asset.balanceOf(address(realVault)), 9400);
        assertEq(adapter.netFlow(), 600);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(realVault.totalAssets(), 10_000);
    }

    /// forge-config: default.isolate = true
    function test_PublicZeroRequestedAmountStillSweepsReleasedLiquidity() public {
        realDelegator.forceDeallocate(address(adapter), 400);
        _deliver(_capturePortfolio());

        uint256 returned = realDelegator.deallocate(address(adapter), 0);
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "publicDeallocateZeroAmount");
        assertEq(returned, 0);
        assertEq(asset.balanceOf(address(adapter)), 600);
        assertEq(asset.balanceOf(address(realVault)), 9400);
        assertEq(adapter.netFlow(), 600);
        assertEq(adapter.pendingDeallocation(), 0);
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
    function test_ManagedPushUsesOnlyUnreservedCash() public {
        realDelegator.forceDeallocate(address(adapter), 400);
        IMerkleAccount.Action[] memory actions = _pushActions(600);
        IMerkleAccount(account).manage(actions);
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "managedPush");
        assertEq(asset.balanceOf(account), 600);
        assertEq(asset.balanceOf(address(adapter)), 400);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.pendingDeallocation(), 400);
        assertEq(adapter.stagedLiquidity(), 400);

        actions = _pushActions(1);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        vm.startSnapshotGas("MerkleAdapterHotPaths", "managedPushReservedRegion");
        IMerkleAccount(account).manage(actions);
        vm.stopSnapshotGas();
        assertEq(asset.balanceOf(account), 600);
        assertEq(asset.balanceOf(address(adapter)), 400);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.pendingDeallocation(), 400);
        assertEq(adapter.stagedLiquidity(), 400);
    }

    /// forge-config: default.isolate = true
    function test_ManagedZeroPushPreservesAccountingAndEmits() public {
        IMerkleAccount.Action[] memory actions = _pushActions(0);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IMerkleAdapter.Push(0);
        IMerkleAccount(account).manage(actions);
        vm.snapshotGasLastCall("MerkleAdapterHotPaths", "managedPushZero");
        assertEq(asset.balanceOf(account), 0);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);
    }

    function _pushActions(uint256 amount) internal returns (IMerkleAccount.Action[] memory actions) {
        bytes memory data = abi.encodeCall(IMerkleAdapter.push, (amount));
        actions = new IMerkleAccount.Action[](1);
        actions[0] = IMerkleAccount.Action({
            target: address(adapter), value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(address(adapter), bytes1(0), keccak256(actions[0].dataMask), keccak256(data)))
            )
        );
        RootRegistry(IMerkleAccount(account).ROOT_REGISTRY()).setRoot(account, leaf);
        IMerkleAccount(account).acceptRoot(leaf);
        IMerkleAccount(account).grantRole(leaf, address(this));
    }
}

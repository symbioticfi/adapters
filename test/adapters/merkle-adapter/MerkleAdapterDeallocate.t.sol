// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";
import {MerkleDeallocationHarness} from "./oracle/CREOracleDeallocate.t.sol";

import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdError} from "forge-std/StdError.sol";

import {MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";

contract MerkleAdapterDeallocateTest is CREOracleTestBase {
    function setUp() public override {
        super.setUp();
        _fundPortfolio(1000);
    }

    function test_ZeroReleaseReturnsZeroWhenNAVOverflows() public {
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );
        vm.expectRevert(stdError.arithmeticError);
        adapter.totalAssets();

        vm.prank(address(delegator));
        assertEq(adapter.deallocate(1000), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 1000);
    }

    function test_ZeroReleaseReturnsZeroWhenNAVIsDelayed() public {
        vm.warp(block.timestamp + 365 days);
        assertEq(adapter.totalAssets(), 1000);

        vm.prank(address(delegator));
        assertEq(adapter.deallocate(1000), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 1000);
    }

    function test_ZeroReleaseSkipsUnavailableCashRead() public {
        vm.mockCallRevert(
            address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), abi.encode("cash read unavailable")
        );
        vm.prank(address(delegator));
        assertEq(adapter.deallocate(1000), 0);
    }

    function test_ReleasedLiquidityStillRejectsNAVOverflow() public {
        _releasePortfolio(200);
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(delegator));
        adapter.deallocate(1000);
    }

    function test_ReleasedLiquiditySkipsUnavailableCashRead() public {
        _releasePortfolio(200);
        vm.mockCallRevert(
            address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), abi.encode("cash read unavailable")
        );
        vm.prank(address(delegator));
        assertEq(adapter.deallocate(1000), 200);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.netFlow(), 800);
    }

    function test_ZeroRequestedAmountWithReleaseStillRejectsNAVOverflow() public {
        _releasePortfolio(200);
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(delegator));
        adapter.deallocate(0);

        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.pendingDeallocation(), 200);
        assertEq(adapter.netFlow(), 1000);
    }

    function test_ZeroRequestedAmountWithReleaseSkipsUnavailableCashRead() public {
        _releasePortfolio(200);
        vm.mockCallRevert(
            address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), abi.encode("cash read unavailable")
        );

        vm.prank(address(delegator));
        assertEq(adapter.deallocate(0), 0);

        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.pendingDeallocation(), 200);
        assertEq(adapter.netFlow(), 1000);
    }

    function test_ZeroReleaseCannotBypassDelegatorNAVValidation() public {
        address path = address(new MerkleDeallocationHarness(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(path);
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );

        vm.expectRevert(stdError.arithmeticError);
        MerkleDeallocationHarness(path).execute(address(adapter), 1000);

        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);
    }
}

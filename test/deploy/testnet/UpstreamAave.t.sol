// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {
    UpstreamAave,
    IUpstreamAavePool,
    IUpstreamAaveData,
    IUpstreamSpoke
} from "../../../script/deploy/testnet/protocols/UpstreamAave.sol";
import {TestnetToken} from "../../../script/deploy/testnet/protocols/TestnetAssets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract UpstreamAaveTest is Test {
    function test_CrossAssetSupplyBorrowRepayAndStandardReads() public {
        address owner = makeAddr("owner");
        address borrower = makeAddr("borrower");
        address helper = address(new UpstreamAave(owner, false));
        UpstreamAave.Deployment memory deployed = UpstreamAave(helper).deploy();
        address usdc = address(new TestnetToken("USD Coin", "USDC", 6, address(this)));
        address weth = address(new TestnetToken("Wrapped Ether", "WETH", 18, address(this)));
        UpstreamAave(helper).addReserve(usdc, 1e18);
        UpstreamAave.Reserve memory reserve = UpstreamAave(helper).addReserve(weth, 3000e18);
        assertEq(IUpstreamAavePool(deployed.pool).getReservesList().length, 2);
        TestnetToken(usdc).mint(owner, 100_000e6);
        TestnetToken(weth).mint(borrower, 10e18);
        vm.startPrank(owner);
        IERC20(usdc).approve(deployed.pool, type(uint256).max);
        IUpstreamAavePool(deployed.pool).supply(usdc, 100_000e6, owner, 0);
        vm.stopPrank();
        vm.startPrank(borrower);
        IERC20(weth).approve(deployed.pool, type(uint256).max);
        IUpstreamAavePool(deployed.pool).supply(weth, 10e18, borrower, 0);
        IUpstreamAavePool(deployed.pool).borrow(usdc, 10_000e6, 2, 0, borrower);
        vm.stopPrank();
        (,, address debtToken) = IUpstreamAaveData(deployed.dataProvider).getReserveTokensAddresses(usdc);
        assertEq(IERC20(debtToken).balanceOf(borrower), 10_000e6);
        (bool success, bytes memory data) = deployed.dataProvider
            .staticcall(abi.encodeWithSignature("getUserReserveData(address,address)", usdc, borrower));
        assertTrue(success);
        assertEq(data.length, 288);
        vm.startPrank(borrower);
        vm.expectRevert();
        IUpstreamAavePool(deployed.pool).borrow(usdc, 20_000e6, 2, 0, borrower);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.stopPrank();
        TestnetToken(usdc).mint(borrower, 1000e6);
        vm.startPrank(borrower);
        IERC20(usdc).approve(deployed.pool, type(uint256).max);
        IUpstreamAavePool(deployed.pool).repay(usdc, type(uint256).max, 2, borrower);
        IUpstreamAavePool(deployed.pool).withdraw(weth, type(uint256).max, borrower);
        vm.stopPrank();
        assertEq(IERC20(debtToken).balanceOf(borrower), 0);
        assertEq(IERC20(weth).balanceOf(borrower), 10e18);
        assertEq(reserve.spokeReserveId, 1);
        assertEq(IUpstreamSpoke(deployed.spoke).getReserveCount(), 2);
        TestnetToken(usdc).mint(owner, 100_000e6);
        vm.startPrank(owner);
        IERC20(usdc).approve(deployed.spoke, type(uint256).max);
        IUpstreamSpoke(deployed.spoke).supply(0, 100_000e6, owner);
        vm.stopPrank();
        vm.startPrank(borrower);
        IERC20(weth).approve(deployed.spoke, type(uint256).max);
        IUpstreamSpoke(deployed.spoke).supply(1, 10e18, borrower);
        IUpstreamSpoke(deployed.spoke).setUsingAsCollateral(1, true, borrower);
        IUpstreamSpoke(deployed.spoke).borrow(0, 10_000e6, borrower);
        assertEq(IUpstreamSpoke(deployed.spoke).getUserTotalDebt(0, borrower), 10_000e6);
        vm.expectRevert();
        IUpstreamSpoke(deployed.spoke).borrow(0, 20_000e6, borrower);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(IUpstreamSpoke(deployed.spoke).getUserTotalDebt(0, borrower), 10_000e6);
        IERC20(usdc).approve(deployed.spoke, type(uint256).max);
        IUpstreamSpoke(deployed.spoke).repay(0, type(uint256).max, borrower);
        IUpstreamSpoke(deployed.spoke).withdraw(1, type(uint256).max, borrower);
        vm.stopPrank();
        assertEq(IUpstreamSpoke(deployed.spoke).getUserTotalDebt(0, borrower), 0);
        assertEq(IUpstreamSpoke(deployed.spoke).getUserSuppliedShares(1, borrower), 0);
        assertEq(IERC20(weth).balanceOf(borrower), 10e18);
    }
}

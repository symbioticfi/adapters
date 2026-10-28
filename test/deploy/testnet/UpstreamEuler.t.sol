// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {
    UpstreamEuler,
    IUpstreamEVault,
    IUpstreamEVC,
    IUpstreamEulerFactory
} from "../../../script/deploy/testnet/protocols/UpstreamEuler.sol";
import {TestnetToken} from "../../../script/deploy/testnet/protocols/TestnetAssets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract UpstreamEulerTest is Test {
    function test_SubaccountCollateralDebtAndRealFactory() public {
        address owner = makeAddr("owner");
        address borrower = makeAddr("borrower");
        address sub = address(uint160(borrower) ^ uint160(7));
        address collateral = address(new TestnetToken("Ether", "WETH", 18, address(this)));
        address asset = address(new TestnetToken("USD", "USDC", 6, address(this)));
        address helper = address(new UpstreamEuler(owner, false));
        UpstreamEuler.Deployment memory deployed = UpstreamEuler(helper).deploy(collateral, 3000e18);
        address vault = UpstreamEuler(helper).addVault(asset, 1e18);
        assertTrue(IUpstreamEulerFactory(deployed.factory).isProxy(vault));
        TestnetToken(asset).mint(owner, 100_000e6);
        TestnetToken(collateral).mint(borrower, 10e18);
        vm.startPrank(owner);
        IERC20(asset).approve(vault, type(uint256).max);
        IUpstreamEVault(vault).deposit(100_000e6, owner);
        vm.stopPrank();
        vm.startPrank(borrower);
        IERC20(collateral).approve(deployed.collateralVault, type(uint256).max);
        IUpstreamEVault(deployed.collateralVault).deposit(10e18, sub);
        IUpstreamEVC(deployed.evc).enableCollateral(sub, deployed.collateralVault);
        IUpstreamEVC(deployed.evc).enableController(sub, vault);
        IUpstreamEVC(deployed.evc).call(vault, sub, 0, abi.encodeCall(IUpstreamEVault.borrow, (10_000e6, borrower)));
        assertEq(IUpstreamEVault(vault).debtOf(sub), 10_000e6);
        assertEq(IUpstreamEVC(deployed.evc).getAccountOwner(sub), borrower);
        vm.expectRevert();
        IUpstreamEVC(deployed.evc).call(vault, sub, 0, abi.encodeCall(IUpstreamEVault.borrow, (20_000e6, borrower)));
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertGt(IUpstreamEVault(vault).debtOf(sub), 10_000e6);
        TestnetToken(asset).mint(borrower, 100e6);
        vm.startPrank(borrower);
        IERC20(asset).approve(vault, type(uint256).max);
        IUpstreamEVault(vault).repay(type(uint256).max, sub);
        IUpstreamEVC(deployed.evc)
            .call(deployed.collateralVault, sub, 0, abi.encodeCall(IUpstreamEVault.withdraw, (10e18, borrower, sub)));
        vm.stopPrank();
        assertEq(IERC20(collateral).balanceOf(borrower), 10e18);
    }
}

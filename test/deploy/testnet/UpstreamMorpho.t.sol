// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {UpstreamMorpho, IUpstreamMorphoFactory} from "../../../script/deploy/testnet/protocols/UpstreamMorpho.sol";
import {TestnetToken} from "../../../script/deploy/testnet/protocols/TestnetAssets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/src/interfaces/IMorpho.sol";
import {Test} from "forge-std/Test.sol";

contract UpstreamMorphoTest is Test {
    function test_RealVaultAllocationBorrowingAndCashLimitedExit() public {
        address owner = makeAddr("owner");
        address borrower = makeAddr("borrower");
        address asset = address(new TestnetToken("USD", "USDC", 6, address(this)));
        address collateral = address(new TestnetToken("Ether", "WETH", 18, address(this)));
        address helper = address(new UpstreamMorpho(owner, false));
        UpstreamMorpho.Deployment memory deployed = UpstreamMorpho(helper).deploy();
        UpstreamMorpho.Market memory market = UpstreamMorpho(helper).addMarket(asset, collateral, 3000e24);
        assertTrue(IUpstreamMorphoFactory(deployed.vaultFactory).isVaultV2(market.vault));
        TestnetToken(asset).mint(owner, 100_000e6);
        TestnetToken(collateral).mint(borrower, 30e18);
        MarketParams memory params = abi.decode(market.blueParams, (MarketParams));
        vm.startPrank(owner);
        IERC20(asset).approve(deployed.blue, type(uint256).max);
        IMorpho(deployed.blue).supply(params, 1e6, 0, address(0xdead), "");
        IERC20(asset).approve(market.vault, type(uint256).max);
        IERC4626(market.vault).deposit(1e6, address(0xdead));
        uint256 shares = IERC4626(market.vault).deposit(90_000e6, owner);
        vm.stopPrank();
        assertGt(IERC4626(market.vault).previewRedeem(shares), 89_999e6);
        assertEq(IERC20(asset).balanceOf(market.vault), 0);
        vm.startPrank(borrower);
        IERC20(collateral).approve(deployed.blue, type(uint256).max);
        IMorpho(deployed.blue).supplyCollateral(params, 30e18, borrower, "");
        (, uint256 debtShares) = IMorpho(deployed.blue).borrow(params, 60_000e6, 0, borrower, borrower);
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert();
        IERC4626(market.vault).redeem(shares, owner, owner);
        IERC4626(market.vault).withdraw(10_000e6, owner, owner);
        vm.stopPrank();
        vm.startPrank(borrower);
        IERC20(asset).approve(deployed.blue, type(uint256).max);
        IMorpho(deployed.blue).repay(params, 0, debtShares, borrower, "");
        vm.stopPrank();
        vm.startPrank(owner);
        IERC4626(market.vault).redeem(IERC20(market.vault).balanceOf(owner), owner, owner);
        vm.stopPrank();
        assertEq(IERC20(market.vault).balanceOf(owner), 0);
    }
}

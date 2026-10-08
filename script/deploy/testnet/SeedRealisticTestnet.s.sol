// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {TestnetAavePool, TestnetCreditVault} from "./protocols/TestnetLending.sol";
import {TestnetAsyncVault} from "./protocols/TestnetRedemptions.sol";
import {TestnetCatalog} from "./catalog/TestnetCatalog.sol";
import {TestnetMidnight} from "./protocols/upstream/TestnetMidnight.sol";
import {TestnetMorpho} from "./protocols/upstream/TestnetMorpho.sol";
import {TestnetNativeLendingScript, TestnetMidnightLender, TestnetAaveV4} from "./protocols/TestnetNativeLending.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";
import {TestnetThreeFRequest} from "./protocols/TestnetThreeF.sol";
import {TestnetToken} from "./protocols/TestnetAssets.sol";
import {TestnetWETH, TestnetNativeStake, TestnetWrappedStake} from "./protocols/TestnetEthRedemptions.sol";
import {
    TestnetYieldDeploymentScript,
    TestnetMakinaMachine,
    TestnetInfiniFiBucketFeed,
    TestnetParetoCDO,
    TestnetParetoQueue
} from "./protocols/TestnetYieldRedemptions.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IOracle} from "src/interfaces/ll-adapter/IOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";

import {MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

import {Market, Offer as MidnightOffer} from "morpho-midnight/src/interfaces/IMidnight.sol";
import {TickLib} from "morpho-midnight/src/libraries/TickLib.sol";

/// @title SeedRealisticTestnetScript
/// @notice Creates actual vault deposits, adapter positions, borrower debt, issuer cash and RWA inventory.
contract SeedRealisticTestnetScript is TestnetPhaseScript {
    error AlreadySeeded();

    function run() public {
        runBase(load());
    }

    function runBase(DeployRealisticTestnetScript.Deployment memory deployed) public {
        _start(deployed.owner);
        for (uint256 i; i < deployed.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory market = deployed.markets[i];
            if (IERC20(market.vault).totalSupply() > 0) revert AlreadySeeded();
            uint256 assetPrice = i == 5 ? 3000e18 : i >= 2 && i <= 4 ? 60_000e18 : 1e18;
            uint256 amount = deployed.seedAssets * 10 ** IERC20Metadata(market.asset).decimals() * 1e18 / assetPrice;
            if (i == 5) TestnetWETH(payable(market.asset)).deposit{value: amount * 4}();
            else TestnetToken(market.asset).mint(deployed.owner, amount * 4);
            IERC20(market.asset).approve(market.vault, amount);
            IERC4626(market.vault).deposit(amount, deployed.owner);
            IUniversalDelegator(market.delegator).allocateExact(market.aaveAdapter, amount / 5);
            IUniversalDelegator(market.delegator).allocateExact(market.eulerAdapter, amount * 15 / 100);
            IUniversalDelegator(market.delegator).allocateExact(market.morphoAdapter, amount * 15 / 100);
            IUniversalDelegator(market.delegator).allocateExact(market.erc4626Adapter, amount / 10);
            IUniversalDelegator(market.delegator).allocateExact(market.appAdapter, amount / 20);
            IUniversalDelegator(market.delegator).allocateExact(market.merkle.adapter, amount / 5);
            IMerkleAccount.Action[] memory fund = new IMerkleAccount.Action[](1);
            fund[0] = market.actions[market.actions.length - 2];
            fund[0].data = abi.encodeCall(IMerkleAdapter.push, (amount / 5));
            IMerkleAccount(IMerkleAdapter(market.merkle.adapter).account()).manage(fund);
            uint256 principal = amount / 100;
            uint256 yieldAssets = (principal + 9) / 10;
            IERC20(market.asset).transfer(market.request, yieldAssets);
            TestnetThreeFRequest(market.request)
                .authorizeMinting(
                    IMerkleAdapter(market.merkle.adapter).account(), uint128(principal), uint128(yieldAssets)
                );
            _recipe(market, amount, principal, yieldAssets);
            uint256 nestedShares = IERC4626(market.vault).convertToShares(amount / 20);
            IERC20(market.vault).approve(market.restakingVault, nestedShares);
            IERC4626(market.restakingVault).deposit(nestedShares, deployed.owner);
            IUniversalDelegator(market.restakingDelegator).allocateExact(market.restakingAdapter, nestedShares);
            // A second supplier and actual borrowing give the pools nonzero utilization and constrained cash.
            IERC20(market.asset).approve(market.aave, amount / 5);
            TestnetAavePool(market.aave).supply(market.asset, amount / 5, deployed.owner, 0);
            TestnetAavePool(market.aave).borrow(market.asset, amount / 10, 2, 0, deployed.owner);
            uint256 collateral = (deployed.seedAssets / 3000 + 1) * 1e18;
            TestnetToken(deployed.collateral).mint(deployed.owner, collateral * 4);
            IERC20(deployed.collateral).approve(market.euler, collateral);
            TestnetCreditVault(market.euler).supplyCollateral(collateral, deployed.owner);
            TestnetCreditVault(market.euler).borrow(amount / 20, deployed.owner);
            IERC20(deployed.collateral).approve(market.morpho, collateral);
            TestnetCreditVault(market.morpho).supplyCollateral(collateral, deployed.owner);
            TestnetCreditVault(market.morpho).borrow(amount / 20, deployed.owner);
            _nativeLending(market.nativeLending, market.asset, deployed.collateral, collateral, amount, deployed.owner);
            for (uint256 j; j < market.rwas.length; ++j) {
                DeployRealisticTestnetScript.RWA memory rwa = market.rwas[j];
                TestnetCatalog.Profile memory profile = TestnetCatalog.profile(rwa.profile);
                uint256 backing = amount / 100;
                if (rwa.mechanism == 5) {
                    _stop();
                    new TestnetYieldDeploymentScript(deployed.owner, _broadcast())
                        .seed(rwa.token, rwa.redemption, profile.variant, backing, deployed.owner);
                    _start(deployed.owner);
                    if (profile.variant == 2) TestnetMakinaMachine(rwa.token).updateAccounting();
                    if (profile.variant == 8 || profile.variant == 9) TestnetInfiniFiBucketFeed(rwa.feed).refresh();
                    if (profile.variant == 10) {
                        TestnetParetoCDO(TestnetParetoQueue(rwa.redemption).idleCDOEpoch()).startEpoch();
                    }
                } else if (rwa.mechanism == 6) {
                    address underlying = TestnetWrappedStake(rwa.token).underlying();
                    TestnetNativeStake(payable(underlying)).deposit{value: backing}(deployed.owner);
                    IERC20(underlying).approve(rwa.token, backing);
                    TestnetWrappedStake(rwa.token).wrap(backing);
                } else if (rwa.mechanism == 7) {
                    IERC20(market.asset).approve(rwa.token, backing);
                    IERC4626(rwa.token).deposit(backing, deployed.owner);
                } else {
                    uint256 shares = backing * 10 ** IERC20Metadata(rwa.token).decimals() * 1e18
                        / (IOracle(rwa.oracle).getPrice() * 10 ** IERC20Metadata(market.asset).decimals());
                    if (rwa.mechanism == 3) {
                        IERC20(market.asset).approve(rwa.token, backing);
                        TestnetAsyncVault(rwa.token).mint(deployed.owner, shares);
                    } else {
                        TestnetToken(rwa.token).mint(deployed.owner, shares);
                        IERC20(market.asset).transfer(rwa.redemption, backing);
                    }
                }
                // Exercise the production adapter's just-in-time allocation and each account's native redemption path.
                uint256 inventory = IERC20(rwa.token).balanceOf(deployed.owner) / 10;
                if (rwa.mechanism == 7) {
                    // This production account prices shares intrinsically and has ORACLE == address(0).
                    // Exercise its native redemption directly; the legacy adapter cannot quote it.
                    address account = ILiquidLaneAdapter(market.liquidLaneAdapter).accounts(rwa.token);
                    IERC20(rwa.token).transfer(account, inventory);
                    IAccount(account).sync();
                    continue;
                }
                uint256 quote = ILiquidLaneAdapter(market.liquidLaneAdapter).getAmountOut(rwa.token, inventory);
                IERC20(rwa.token).transfer(market.liquidLaneAdapter, inventory);
                ILiquidLaneAdapter(market.liquidLaneAdapter)
                    .swap(
                        ILiquidLaneAdapter.Swap({
                            recipient: deployed.owner,
                            tokenIn: rwa.token,
                            amountIn: inventory,
                            amountOut: quote * 99 / 100
                        })
                    );
            }
        }
        _stop();
    }

    function _nativeLending(
        TestnetNativeLendingScript.Deployment memory native,
        address asset,
        address collateral,
        uint256 collateralAmount,
        uint256 amount,
        address owner
    ) internal {
        MarketParams memory blue = abi.decode(native.blueParams, (MarketParams));
        IERC20(asset).approve(native.blue, amount / 10);
        TestnetMorpho(native.blue).supply(blue, amount / 10, 0, owner, "");
        IERC20(collateral).approve(native.blue, collateralAmount);
        TestnetMorpho(native.blue).supplyCollateral(blue, collateralAmount, owner, "");
        TestnetMorpho(native.blue).borrow(blue, amount / 20, 0, owner, owner);
        Market memory midnight = abi.decode(native.midnightParams, (Market));
        IERC20(collateral).approve(native.midnight, collateralAmount);
        TestnetMidnight(native.midnight).supplyCollateral(midnight, 0, collateralAmount, owner);
        IERC20(asset).transfer(native.midnightLender, amount / 10);
        MidnightOffer memory offer = MidnightOffer({
            market: midnight,
            buy: true,
            maker: native.midnightLender,
            start: block.timestamp,
            expiry: midnight.maturity,
            tick: TickLib.priceToTick(99e16, 4),
            group: keccak256("initial-funded-loan"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: native.midnightLender,
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: uint128(amount / 10),
            continuousFeeCap: type(uint256).max
        });
        TestnetMidnightLender(native.midnightLender).approveOffer(offer, owner);
        TestnetMidnight(native.midnight).take(offer, "", amount / 20, owner, owner, address(0), "");
        IERC20(asset).approve(native.aaveV4, amount / 10);
        TestnetAaveV4(native.aaveV4).supply(0, amount / 10, owner);
    }

    function _recipe(
        DeployRealisticTestnetScript.Market memory market,
        uint256 amount,
        uint256 principal,
        uint256 yieldAssets
    ) internal {
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = amount / 10;
        inputs[1] = principal;
        inputs[2] = yieldAssets;
        bytes[] memory runtime = new bytes[](6);
        runtime[0] = abi.encode(market.actions[0].dataMask, market.actions[0].proof);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = market.actions[1];
        runtime[1] = abi.encode(actions);
        runtime[2] = runtime[0];
        runtime[3] = abi.encode(
            market.actions[market.actions.length - 4].dataMask, market.actions[market.actions.length - 4].proof
        );
        actions[0] = market.actions[market.actions.length - 3];
        runtime[4] = abi.encode(actions);
        runtime[5] = runtime[3];
        RecipeExecutor(market.executor).execute(new bytes[](0), market.recipe, inputs, runtime);
    }
}

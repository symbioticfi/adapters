// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {RealisticTestnetTest} from "./RealisticTestnet.t.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Vm} from "forge-std/Vm.sol";

import {Id, IMorpho, IMorphoBase, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";

import {IdLib} from "morpho-midnight/src/libraries/IdLib.sol";
import {Market, Offer} from "morpho-midnight/src/interfaces/IMidnight.sol";
import {TickLib} from "morpho-midnight/src/libraries/TickLib.sol";

import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {MerkleMarketActivityScript} from "script/deploy/testnet/activity/MerkleMarketActivity.s.sol";
import {MerkleProgram} from "script/deploy/testnet/activity/MerkleProgram.sol";
import {TestnetAavePool, TestnetCreditVault} from "script/deploy/testnet/protocols/TestnetLending.sol";
import {TestnetAaveV4, TestnetMidnightLender} from "script/deploy/testnet/protocols/TestnetNativeLending.sol";
import {TestnetMidnight} from "script/deploy/testnet/protocols/upstream/TestnetMidnight.sol";

contract MerkleMarketActivityHarness is MerkleMarketActivityScript {
    function creditBase(AccountRun memory context, address pool) public returns (uint256) {
        _start(context.program.owner, false);
        uint256 count = _credit(context, pool);
        _stop(false);
        return count;
    }

    function aaveV4Base(AccountRun memory context, address pool) public returns (uint256) {
        _start(context.program.owner, false);
        uint256 count = _aaveV4(context, pool);
        _stop(false);
        return count;
    }

    function seedAaveV4(AccountRun memory context, address pool, uint256 amount) public {
        _start(context.program.owner, false);
        Build memory build = _newBuild();
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, amount)), 0));
        _manage(
            build,
            _action(build, pool, abi.encodeCall(TestnetAaveV4.supply, (uint256(0), amount, context.program.account)), 0)
        );
        MerkleProgram.execute(context.program, _finish(build));
        _stop(false);
    }

    function midnightBase(AccountRun memory context, address pool, address lender, bytes memory params)
        public
        returns (uint256)
    {
        _start(context.program.owner, false);
        uint256 count = _midnight(context, pool, lender, params);
        _stop(false);
        return count;
    }
}

/// @title MerkleMarketActivityTest
/// @notice Verifies atomic account-owned leverage loops, live share bindings and restored curator permissions.
contract MerkleMarketActivityTest is RealisticTestnetTest {
    function test_AccountProgramsExecuteTwoBorrowLoopsAndCloseActualAccountDebt() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address helper = address(new MerkleMarketActivityScript());
        address account = IMerkleAdapter(market.merkle.adapter).account();
        bytes32 root = IMerkleAccount(account).root();
        bytes32 recipe = RecipeExecutor(market.executor).recipeHash();
        uint256 ownerDebt = TestnetAavePool(market.aave).debtOf(_owner);
        uint256 eulerShares = IERC20(market.euler).balanceOf(account);
        uint256 morphoShares = IERC20(market.morpho).balanceOf(account);
        uint256 amount = 100 * 10 ** IERC20Metadata(market.asset).decimals();
        vm.recordLogs();
        uint256[8] memory counts =
            MerkleMarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, amount, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 borrows;
        uint256 resupplies;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != market.aave || logs[i].topics.length < 3) continue;
            if (logs[i].topics[0] == keccak256("Borrow(address,address,address,uint256,uint8,uint256,uint16)")) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), account);
                (address caller, uint256 borrowed,,) = abi.decode(logs[i].data, (address, uint256, uint8, uint256));
                assertEq(caller, account);
                assertEq(borrowed, amount / 4);
                ++borrows;
            } else if (logs[i].topics[0] == keccak256("Supply(address,address,address,uint256,uint16)")) {
                (address caller, uint256 supplied) = abi.decode(logs[i].data, (address, uint256));
                assertEq(caller, account);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), account);
                if (supplied == amount / 4) ++resupplies;
            }
        }
        assertEq(borrows, 2);
        assertEq(resupplies, 1);
        assertEq(counts[0], 2);
        assertEq(counts[1], 7);
        assertEq(counts[2], 7);
        assertEq(counts[3], 7);
        assertEq(counts[4], 2);
        assertEq(counts[5], 8);
        assertEq(counts[6], 4);
        assertEq(counts[7], 2);
        assertEq(TestnetAavePool(market.aave).debtOf(account), 0);
        assertEq(TestnetAavePool(market.aave).debtOf(_owner), ownerDebt);
        assertEq(TestnetCreditVault(market.euler).debtOf(account), 0);
        assertEq(TestnetCreditVault(market.morpho).debtOf(account), 0);
        assertEq(IERC20(market.euler).balanceOf(account), eulerShares);
        assertEq(IERC20(market.morpho).balanceOf(account), morphoShares);
        assertGt(TestnetCreditVault(market.euler).collateral(account), 0);
        assertGt(TestnetCreditVault(market.morpho).collateral(account), 0);
        Position memory position =
            IMorpho(market.nativeLending.blue).position(Id.wrap(market.nativeLending.blueId), account);
        assertEq(position.borrowShares, 0);
        assertEq(position.supplyShares, 0);
        assertEq(position.collateral, 0);
        Market memory midnight = abi.decode(MerkleMarketActivityScript(helper).midnightParams(), (Market));
        assertEq(TestnetMidnight(market.nativeLending.midnight).debt(IdLib.toId(midnight), account), 0);
        assertEq(TestnetMidnight(market.nativeLending.midnight).collateral(IdLib.toId(midnight), account, 0), 0);
        assertEq(TestnetAaveV4(market.nativeLending.aaveV4).suppliedShares(account), 0);
        assertEq(IMerkleAccount(account).root(), root);
        assertEq(RecipeExecutor(market.executor).recipeHash(), recipe);
        assertFalse(MerkleMarketActivityScript(helper).collateralWaiting());
        assertFalse(MerkleMarketActivityScript(helper).midnightWaiting());
        assertEq(IERC20(market.asset).allowance(account, market.aave), 0);
        assertEq(IERC20(market.asset).allowance(account, market.euler), 0);
        assertEq(IERC20(market.asset).allowance(account, market.nativeLending.blue), 0);
    }

    function test_RepeatedBatchesSkipOccupiedDebtAndPreserveEveryExistingPosition() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address helper = address(new MerkleMarketActivityScript());
        address account = IMerkleAdapter(market.merkle.adapter).account();
        _occupy(market, account);
        bytes32 positions = _occupiedPositions(market, account);
        bytes32 root = IMerkleAccount(account).root();
        bytes32 recipe = RecipeExecutor(market.executor).recipeHash();
        for (uint256 batch; batch < 2; ++batch) {
            uint256[8] memory counts =
                MerkleMarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 100e6, false);
            assertEq(counts[0], 2);
            assertEq(counts[1], 0);
            assertEq(counts[2], 0);
            assertEq(counts[3], 0);
            assertEq(counts[4], 2);
            assertEq(counts[5], 0);
            assertEq(counts[6], 0);
            assertEq(counts[7], 2);
            assertEq(MerkleMarketActivityScript(helper).fundedCollateral(), 0);
            assertEq(MerkleMarketActivityScript(helper).fundedAssets(), 100e6);
            assertTrue(MerkleMarketActivityScript(helper).occupiedDebt(1));
            assertTrue(MerkleMarketActivityScript(helper).occupiedDebt(2));
            assertTrue(MerkleMarketActivityScript(helper).occupiedDebt(3));
            assertTrue(MerkleMarketActivityScript(helper).occupiedDebt(5));
            assertTrue(MerkleMarketActivityScript(helper).occupiedDebt(6));
            assertEq(_occupiedPositions(market, account), positions);
            assertEq(IMerkleAccount(account).root(), root);
            assertEq(RecipeExecutor(market.executor).recipeHash(), recipe);
        }
    }

    function test_OccupiedAaveDebtDoesNotSkipOtherBorrowingFamilies() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address account = IMerkleAdapter(market.merkle.adapter).account();
        address helper = address(new MerkleMarketActivityScript());
        vm.prank(account);
        TestnetAavePool(market.aave).borrow(market.asset, 10e6, 2, 0, account);
        uint256 debt = TestnetAavePool(market.aave).debtOf(account);
        uint256 shares = IERC20(TestnetAavePool(market.aave).aToken()).balanceOf(account);
        uint256[8] memory counts =
            MerkleMarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 100e6, false);
        assertEq(counts[1], 0);
        for (uint256 i; i < counts.length; ++i) {
            if (i != 1) assertGt(counts[i], 0);
        }
        assertEq(TestnetAavePool(market.aave).debtOf(account), debt);
        assertEq(IERC20(TestnetAavePool(market.aave).aToken()).balanceOf(account), shares);
    }

    function test_OccupiedMidnightDebtIsSkippedAfterItsOriginalMarketMatures() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address account = IMerkleAdapter(market.merkle.adapter).account();
        address helper = address(new MerkleMarketActivityHarness());
        _occupy(market, account);
        Market memory params = abi.decode(market.nativeLending.midnightParams, (Market));
        vm.warp(params.maturity + 1);
        uint256 debt = TestnetMidnight(market.nativeLending.midnight).debt(market.nativeLending.midnightId, account);
        bytes32 offer = TestnetMidnightLender(market.nativeLending.midnightLender).approvedOffer();
        MerkleMarketActivityScript.AccountRun memory context = MerkleMarketActivityScript.AccountRun({
            program: MerkleProgram.Context({
                owner: _owner,
                account: account,
                rootRegistry: market.merkle.rootRegistry,
                executor: market.executor,
                baseActions: market.actions,
                baseRecipe: market.recipe
            }),
            asset: market.asset,
            collateral: _deployed.collateral,
            amount: 100e6,
            collateralAmount: 1 ether,
            loan: 25e6
        });
        assertEq(
            MerkleMarketActivityHarness(helper)
                .midnightBase(
                    context,
                    market.nativeLending.midnight,
                    market.nativeLending.midnightLender,
                    market.nativeLending.midnightParams
                ),
            0
        );
        assertTrue(MerkleMarketActivityScript(helper).occupiedDebt(6));
        assertEq(TestnetMidnight(market.nativeLending.midnight).debt(market.nativeLending.midnightId, account), debt);
        assertEq(TestnetMidnightLender(market.nativeLending.midnightLender).approvedOffer(), offer);
        assertEq(MerkleMarketActivityScript(helper).midnightParams(), "");
    }

    function test_OccupiedMidnightRolloverTargetDoesNotDebitOwnerCollateral() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address account = IMerkleAdapter(market.merkle.adapter).account();
        address helper = address(new MerkleMarketActivityScript());
        _occupy(market, account);
        Market memory expired = abi.decode(market.nativeLending.midnightParams, (Market));
        // The occupied deployed market is exactly the target selected when this older market rolls over.
        assertEq(expired.maturity, block.timestamp + 30 days);
        expired.maturity = block.timestamp - 1;
        bytes32 originalId = TestnetMidnight(market.nativeLending.midnight).touchMarket(expired);
        assertNotEq(originalId, market.nativeLending.midnightId);
        assertEq(TestnetMidnight(market.nativeLending.midnight).debt(originalId, account), 0);
        _deployed.markets[0].nativeLending.midnightParams = abi.encode(expired);
        uint256 ownerCollateral = IERC20(_deployed.collateral).balanceOf(_owner);
        bytes32 positions = _occupiedPositions(market, account);
        uint256[8] memory counts =
            MerkleMarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 100e6, false);
        assertEq(counts[6], 0);
        assertTrue(MerkleMarketActivityScript(helper).occupiedDebt(6));
        assertEq(MerkleMarketActivityScript(helper).fundedCollateral(), 0);
        assertEq(IERC20(_deployed.collateral).balanceOf(_owner), ownerCollateral);
        assertEq(_occupiedPositions(market, account), positions);
        assertEq(TestnetMidnight(market.nativeLending.midnight).debt(originalId, account), 0);
        assertEq(TestnetMidnight(market.nativeLending.midnight).collateral(originalId, account, 0), 0);
    }

    function test_HealthyBatchesRepeatAfterClosingTheirOwnBorrowLoops() public {
        address helper = address(new MerkleMarketActivityScript());
        for (uint256 batch; batch < 2; ++batch) {
            uint256[8] memory counts =
                MerkleMarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 100e6, false);
            for (uint256 i; i < counts.length; ++i) {
                assertGt(counts[i], 0);
                assertFalse(MerkleMarketActivityScript(helper).occupiedDebt(i));
            }
        }
    }

    function test_AccountProgramsUseSixDecimalBitcoinAndNativeEtherUnits() public {
        address helper = address(new MerkleMarketActivityScript());
        uint256 amount = 100_000 * 10 ** IERC20Metadata(_deployed.markets[2].asset).decimals() / 60_000 / 1000;
        uint256[8] memory counts =
            MerkleMarketActivityScript(helper).runBase(_humanManifest(2), ".markets[0]", _owner, amount, false);
        for (uint256 i; i < counts.length; ++i) {
            assertGt(counts[i], 0);
        }
        assertEq(MerkleMarketActivityScript(helper).fundedAssets(), amount);
        amount = 100_000 * 10 ** IERC20Metadata(_deployed.markets[5].asset).decimals() / 3000 / 1000;
        counts = MerkleMarketActivityScript(helper).runBase(_humanManifest(5), ".markets[0]", _owner, amount, false);
        for (uint256 i; i < counts.length; ++i) {
            assertGt(counts[i], 0);
        }
        assertEq(MerkleMarketActivityScript(helper).fundedAssets(), amount);
    }

    function test_AccountProgramBindsActualCreditSharesAfterSevenDaysOfAccrual() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[6];
        address helper = address(new MerkleMarketActivityHarness());
        address account = IMerkleAdapter(market.merkle.adapter).account();
        uint256 amount = 78 * 10 ** IERC20Metadata(market.asset).decimals();
        vm.startPrank(_owner);
        IERC20(market.asset).transfer(account, amount);
        IERC20(_deployed.collateral).transfer(account, 1 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        uint256 shares = IERC20(market.morpho).balanceOf(account);
        MerkleMarketActivityScript.AccountRun memory context = MerkleMarketActivityScript.AccountRun({
            program: MerkleProgram.Context({
                owner: _owner,
                account: account,
                rootRegistry: market.merkle.rootRegistry,
                executor: market.executor,
                baseActions: market.actions,
                baseRecipe: market.recipe
            }),
            asset: market.asset,
            collateral: _deployed.collateral,
            amount: amount,
            collateralAmount: 1 ether,
            loan: amount / 4
        });
        assertEq(MerkleMarketActivityHarness(helper).creditBase(context, market.morpho), 7);
        assertEq(IERC20(market.morpho).balanceOf(account), shares);
        assertEq(TestnetCreditVault(market.morpho).debtOf(account), 0);
        assertEq(TestnetCreditVault(market.morpho).collateral(account), 1 ether);
    }

    function test_AccountProgramsExplicitlyWaitForUnfundedCollateralFamilies() public {
        address helper = address(new MerkleMarketActivityScript());
        uint256 collateral = IERC20(_deployed.collateral).balanceOf(_owner);
        address custodian = makeAddr("collateral custodian");
        vm.prank(_owner);
        IERC20(_deployed.collateral).transfer(custodian, collateral);
        uint256[8] memory counts =
            MerkleMarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 100e6, false);
        assertTrue(MerkleMarketActivityScript(helper).collateralWaiting());
        assertEq(MerkleMarketActivityScript(helper).fundedCollateral(), 0);
        assertGt(counts[0], 0);
        assertGt(counts[1], 0);
        assertEq(counts[2], 0);
        assertEq(counts[3], 0);
        assertGt(counts[4], 0);
        assertEq(counts[5], 0);
        assertEq(counts[6], 0);
        assertGt(counts[7], 0);
    }

    function test_AaveV4PreservesExistingAccountSharesAfterFundedDonation() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address helper = address(new MerkleMarketActivityHarness());
        address account = IMerkleAdapter(market.merkle.adapter).account();
        address pool = market.nativeLending.aaveV4;
        vm.prank(_owner);
        IERC20(market.asset).transfer(account, 95e6);
        MerkleMarketActivityScript.AccountRun memory context = MerkleMarketActivityScript.AccountRun({
            program: MerkleProgram.Context({
                owner: _owner,
                account: account,
                rootRegistry: market.merkle.rootRegistry,
                executor: market.executor,
                baseActions: market.actions,
                baseRecipe: market.recipe
            }),
            asset: market.asset,
            collateral: _deployed.collateral,
            amount: 78e6,
            collateralAmount: 0,
            loan: 0
        });
        MerkleMarketActivityHarness(helper).seedAaveV4(context, pool, 17e6);
        vm.prank(_owner);
        IERC20(market.asset).transfer(pool, 7e6);
        uint256 shares = TestnetAaveV4(pool).suppliedShares(account);
        uint256 cash = IERC20(market.asset).balanceOf(account);
        assertEq(MerkleMarketActivityHarness(helper).aaveV4Base(context, pool), 2);
        assertEq(TestnetAaveV4(pool).suppliedShares(account), shares);
        assertApproxEqAbs(IERC20(market.asset).balanceOf(account), cash, 1);
    }

    function test_PreflightRejectsAnUnexpectedExecutorCallerBeforeFundingCustody() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address helper = address(new MerkleMarketActivityScript());
        address account = IMerkleAdapter(market.merkle.adapter).account();
        address unexpected = makeAddr("unexpected executor caller");
        vm.prank(_owner);
        RecipeExecutor(market.executor).setCaller(unexpected);
        uint256 ownerCash = IERC20(market.asset).balanceOf(_owner);
        uint256 accountCash = IERC20(market.asset).balanceOf(account);
        string memory json = _humanManifest(0);
        vm.expectRevert(MerkleProgram.InvalidProgram.selector);
        MerkleMarketActivityScript(helper).runBase(json, ".markets[0]", _owner, 100e6, false);
        assertEq(IERC20(market.asset).balanceOf(_owner), ownerCash);
        assertEq(IERC20(market.asset).balanceOf(account), accountCash);
    }

    function test_MidnightRecyclesFreshNetCreditWithContinuousFeesOnANewAccountMarket() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address helper = address(new MerkleMarketActivityHarness());
        address account = IMerkleAdapter(market.merkle.adapter).account();
        vm.startPrank(_owner);
        IERC20(market.asset).transfer(account, 100e6);
        IERC20(_deployed.collateral).transfer(account, 1 ether);
        TestnetMidnight(market.nativeLending.midnight).setFeeSetter(_owner);
        TestnetMidnight(market.nativeLending.midnight).setDefaultContinuousFee(market.asset, 1e8);
        vm.stopPrank();
        vm.warp(abi.decode(market.nativeLending.midnightParams, (Market)).maturity + 1);
        MerkleMarketActivityScript.AccountRun memory context = MerkleMarketActivityScript.AccountRun({
            program: MerkleProgram.Context({
                owner: _owner,
                account: account,
                rootRegistry: market.merkle.rootRegistry,
                executor: market.executor,
                baseActions: market.actions,
                baseRecipe: market.recipe
            }),
            asset: market.asset,
            collateral: _deployed.collateral,
            amount: 100e6,
            collateralAmount: 1 ether,
            loan: 25e6
        });
        assertEq(
            MerkleMarketActivityHarness(helper)
                .midnightBase(
                    context,
                    market.nativeLending.midnight,
                    market.nativeLending.midnightLender,
                    market.nativeLending.midnightParams
                ),
            4
        );
        Market memory params = abi.decode(MerkleMarketActivityScript(helper).midnightParams(), (Market));
        bytes32 id = IdLib.toId(params);
        assertEq(TestnetMidnight(market.nativeLending.midnight).debt(id, account), 0);
        assertEq(TestnetMidnight(market.nativeLending.midnight).collateral(id, account, 0), 0);
        (uint128 credit, uint128 pendingFee,) = TestnetMidnight(market.nativeLending.midnight)
            .updatePositionView(params, id, market.nativeLending.midnightLender);
        assertGt(pendingFee, 0);
        assertGt(credit, pendingFee);
        assertLt(credit, context.loan);
    }

    function _occupy(DeployRealisticTestnetScript.Market memory market, address account) internal {
        vm.prank(_owner);
        IERC20(_deployed.collateral).transfer(account, 4 ether);
        MarketParams memory blue = abi.decode(market.nativeLending.blueParams, (MarketParams));
        Market memory midnight = abi.decode(market.nativeLending.midnightParams, (Market));
        Offer memory offer = Offer({
            market: midnight,
            buy: true,
            maker: market.nativeLending.midnightLender,
            start: block.timestamp,
            expiry: midnight.maturity,
            tick: TickLib.priceToTick(99e16, 4),
            group: keccak256("preexisting-account-loan"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: market.nativeLending.midnightLender,
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: 10e6,
            continuousFeeCap: type(uint256).max
        });
        vm.prank(_owner);
        TestnetMidnightLender(market.nativeLending.midnightLender).approveOffer(offer, account);
        vm.startPrank(account);
        TestnetAavePool(market.aave).borrow(market.asset, 10e6, 2, 0, account);
        IERC20(_deployed.collateral).approve(market.euler, 1 ether);
        TestnetCreditVault(market.euler).supplyCollateral(1 ether, account);
        TestnetCreditVault(market.euler).borrow(10e6, account);
        IERC20(_deployed.collateral).approve(market.morpho, 1 ether);
        TestnetCreditVault(market.morpho).supplyCollateral(1 ether, account);
        TestnetCreditVault(market.morpho).borrow(10e6, account);
        IERC20(_deployed.collateral).approve(market.nativeLending.blue, 1 ether);
        IMorphoBase(market.nativeLending.blue).supplyCollateral(blue, 1 ether, account, "");
        IMorphoBase(market.nativeLending.blue).borrow(blue, 10e6, 0, account, account);
        IERC20(_deployed.collateral).approve(market.nativeLending.midnight, 1 ether);
        TestnetMidnight(market.nativeLending.midnight).supplyCollateral(midnight, 0, 1 ether, account);
        TestnetMidnight(market.nativeLending.midnight).take(offer, "", 10e6, account, account, address(0), "");
        vm.stopPrank();
    }

    function _occupiedPositions(DeployRealisticTestnetScript.Market memory market, address account)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                TestnetAavePool(market.aave).debtOf(account),
                IERC20(TestnetAavePool(market.aave).aToken()).balanceOf(account),
                TestnetCreditVault(market.euler).debtOf(account),
                TestnetCreditVault(market.euler).collateral(account),
                IERC20(market.euler).balanceOf(account),
                TestnetCreditVault(market.morpho).debtOf(account),
                TestnetCreditVault(market.morpho).collateral(account),
                IERC20(market.morpho).balanceOf(account),
                IMorpho(market.nativeLending.blue).position(Id.wrap(market.nativeLending.blueId), account),
                TestnetMidnight(market.nativeLending.midnight).debt(market.nativeLending.midnightId, account),
                TestnetMidnight(market.nativeLending.midnight).collateral(market.nativeLending.midnightId, account, 0),
                TestnetMidnightLender(market.nativeLending.midnightLender).approvedOffer(),
                IERC20(market.asset).allowance(account, market.aave),
                IERC20(market.asset).allowance(account, market.euler),
                IERC20(market.asset).allowance(account, market.morpho),
                IERC20(market.asset).allowance(account, market.nativeLending.blue),
                IERC20(market.asset).allowance(account, market.nativeLending.midnight),
                IERC20(market.asset).allowance(market.nativeLending.midnightLender, market.nativeLending.midnight)
            )
        );
    }

    function _humanManifest(uint256 index) internal returns (string memory json) {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[index];
        string memory key = "merkle-activity-test-market";
        vm.serializeJson(key, "{}");
        vm.serializeAddress(key, "asset", market.asset);
        vm.serializeAddress(key, "vault", market.vault);
        vm.serializeAddress(key, "aavePool", market.aave);
        vm.serializeAddress(key, "eulerVault", market.euler);
        vm.serializeAddress(key, "morphoVault", market.morpho);
        vm.serializeAddress(key, "erc4626Vault", market.erc4626);
        vm.serializeAddress(key, "morphoBlue", market.nativeLending.blue);
        vm.serializeBytes(key, "morphoBlueParams", market.nativeLending.blueParams);
        vm.serializeAddress(key, "morphoMidnight", market.nativeLending.midnight);
        vm.serializeBytes(key, "morphoMidnightParams", market.nativeLending.midnightParams);
        vm.serializeAddress(key, "midnightLender", market.nativeLending.midnightLender);
        vm.serializeAddress(key, "aaveV4", market.nativeLending.aaveV4);
        vm.serializeAddress(key, "account", IMerkleAdapter(market.merkle.adapter).account());
        vm.serializeAddress(key, "rootRegistry", market.merkle.rootRegistry);
        vm.serializeAddress(key, "executor", market.executor);
        vm.serializeBytes(key, "merkleActions", abi.encode(market.actions));
        string memory row = vm.serializeBytes(key, "recipeSteps", abi.encode(market.recipe));
        json = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"owner":"',
            vm.toString(_owner),
            '","seedAssets":100000,"collateral":"',
            vm.toString(_deployed.collateral),
            '","markets":[',
            row,
            "]}"
        );
    }
}

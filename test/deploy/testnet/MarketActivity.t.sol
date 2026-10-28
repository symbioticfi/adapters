// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IUpstreamAavePool, IUpstreamSpoke} from "script/deploy/testnet/protocols/UpstreamAave.sol";
import {IUpstreamEVault, IUpstreamEVC} from "script/deploy/testnet/protocols/UpstreamEuler.sol";

import {RealisticTestnetTest} from "./RealisticTestnet.t.sol";

import {ICoWSwapConverter} from "src/interfaces/common/ICoWSwapConverter.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LibBytes} from "solady/utils/LibBytes.sol";

import {Vm} from "forge-std/Vm.sol";

import {ActivityManifestScript} from "script/deploy/testnet/activity/ActivityManifest.sol";
import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {MarketActivityScript} from "script/deploy/testnet/activity/MarketActivity.s.sol";
import {TestnetCowSettlement, TestnetMerklDistributor} from "script/deploy/testnet/protocols/TestnetServices.sol";

/// @title MarketActivityTest
/// @notice Verifies funded native mutations against the complete deployment and production adapter fixtures.
contract MarketActivityTest is RealisticTestnetTest {
    function test_ActivityExercisesAllThirteenFundedFamiliesAndRestoresConverterPermissions() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address helper = address(new MarketActivityScript());
        address[] memory original = new address[](1);
        original[0] = makeAddr("existing converter");
        vm.prank(_owner);
        ICoWSwapConverter(market.appAdapter).setConverters(original);
        vm.setEnv("TESTNET_ACTIVITY_MIDNIGHT", "");
        address account = IMerkleAdapter(market.merkle.adapter).account();
        uint256 accountCash = IERC20(market.asset).balanceOf(account);
        uint256 aaveDebt = _aaveDebt(market, _owner);
        uint256 eulerDebt = IUpstreamEVault(market.euler).debtOf(_owner);
        uint256 morphoDebt = uint256(0);
        uint256 beforeNested = IERC20(market.vault).balanceOf(market.restakingAdapter);
        vm.recordLogs();
        uint256[13] memory counts =
            MarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 75, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fillIndex = logs.length;
        uint256 recipeIndex = logs.length;
        uint256 fundedReward;
        uint256 solverPayment;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == _deployed.cowSettlement
                    && logs[i].topics[0] == keccak256("Trade(address,address,address,uint256,uint256,uint256,bytes)")
            ) {
                fillIndex = i;
                (,,, solverPayment,,) = abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, bytes));
            }
            if (logs[i].emitter == market.executor && recipeIndex == logs.length) recipeIndex = i;
            if (
                logs[i].emitter == market.asset && logs[i].topics.length == 3
                    && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && address(uint160(uint256(logs[i].topics[1]))) == _owner
                    && address(uint160(uint256(logs[i].topics[2]))) == market.appAdapter
            ) fundedReward += abi.decode(logs[i].data, (uint256));
        }
        // A serial public-chain replay may take longer than the converter's maximum order lifetime.
        assertLt(fillIndex, recipeIndex);
        assertLt(recipeIndex, logs.length);
        for (uint256 i; i < counts.length; ++i) {
            assertGt(counts[i], 0);
        }
        assertEq(counts[0], 2);
        assertEq(counts[1], 7);
        assertEq(counts[2], 8);
        assertEq(counts[3], 2);
        assertEq(counts[4], 2);
        assertEq(counts[5], 8);
        assertEq(counts[6], 4);
        assertEq(counts[7], 2);
        assertEq(counts[8], 8);
        assertEq(counts[9], 1);
        assertEq(counts[10], 2);
        assertEq(counts[11], 3);
        assertEq(counts[12], 5);
        assertEq(MarketActivityScript(helper).lastAmount(), 100 * 10 ** IERC20Metadata(market.asset).decimals());
        assertGe(IERC20(market.asset).balanceOf(account), accountCash);
        assertEq(IERC20(market.asset).allowance(account, market.aave), 0);
        assertEq(_aaveDebt(market, _owner), aaveDebt);
        assertApproxEqAbs(IUpstreamEVault(market.euler).debtOf(_owner), eulerDebt, 1);
        assertApproxEqAbs(uint256(0), morphoDebt, 1);
        // Later vault withdrawals may distribute those funded rewards to account-owned positions.
        assertEq(fundedReward, MarketActivityScript(helper).lastAmount() / 20 + solverPayment);
        assertGt(IERC20(market.vault).balanceOf(market.restakingAdapter), beforeNested);
        assertEq(ICoWSwapConverter(market.appAdapter).converters(0), original[0]);
        assertFalse(MarketActivityScript(helper).midnightWaiting());
        bytes memory uid = MarketActivityScript(helper).cowUid();
        assertEq(uid.length, 56);
        uint32 validTo = uint32(bytes4(LibBytes.load(uid, 52)));
        assertEq(uint256(validTo), block.timestamp + 30 minutes);
        assertGt(TestnetCowSettlement(_deployed.cowSettlement).preSignature(uid), 0);
        assertGt(TestnetCowSettlement(_deployed.cowSettlement).filledAmount(uid), 0);
        assertEq(IERC20(market.vault).balanceOf(market.appAdapter), 0);
        assertGt(TestnetMerklDistributor(_deployed.merkl).claimed(_owner, market.asset), 0);
    }

    function test_ActivityRepeatsWithCumulativeRewardsAndDistinctFundedOrders() public {
        address helper = address(new MarketActivityScript());
        vm.setEnv("TESTNET_ACTIVITY_MIDNIGHT", "");
        string memory json = _humanManifest(0);
        MarketActivityScript(helper).runBase(json, ".markets[0]", _owner, 74, false);
        bytes memory firstUid = MarketActivityScript(helper).cowUid();
        uint256 firstClaim = TestnetMerklDistributor(_deployed.merkl).claimed(_owner, _deployed.markets[0].asset);
        MarketActivityScript(helper).runBase(json, ".markets[0]", _owner, 75, false);
        bytes memory secondUid = MarketActivityScript(helper).cowUid();
        assertTrue(keccak256(firstUid) != keccak256(secondUid));
        assertGt(TestnetCowSettlement(_deployed.cowSettlement).filledAmount(firstUid), 0);
        assertGt(TestnetCowSettlement(_deployed.cowSettlement).filledAmount(secondUid), 0);
        assertGt(TestnetMerklDistributor(_deployed.merkl).claimed(_owner, _deployed.markets[0].asset), firstClaim);
    }

    function test_ActivityUsesBitcoinAndEtherDenominations() public {
        address helper = address(new MarketActivityScript());
        vm.setEnv("TESTNET_ACTIVITY_MIDNIGHT", "");
        uint256[13] memory counts =
            MarketActivityScript(helper).runBase(_humanManifest(2), ".markets[0]", _owner, 75, false);
        assertEq(
            MarketActivityScript(helper).lastAmount(),
            100_000 * 10 ** IERC20Metadata(_deployed.markets[2].asset).decimals() / 60_000 / 1000
        );
        assertGt(counts[12], 0);
        counts = MarketActivityScript(helper).runBase(_humanManifest(5), ".markets[0]", _owner, 75, false);
        assertEq(
            MarketActivityScript(helper).lastAmount(),
            100_000 * 10 ** IERC20Metadata(_deployed.markets[5].asset).decimals() / 3000 / 1000
        );
        assertGt(counts[12], 0);
    }

    function test_ActivityWaitsWithoutChangingStateWhenOwnerCannotFundMinimumUnit() public {
        address helper = address(new MarketActivityScript());
        address asset = _deployed.markets[0].asset;
        uint256 cash = IERC20(asset).balanceOf(_owner);
        address custodian = makeAddr("asset custodian");
        vm.prank(_owner);
        IERC20(asset).transfer(custodian, cash - 19);
        uint256[13] memory counts =
            MarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 75, false);
        for (uint256 i; i < counts.length; ++i) {
            assertEq(counts[i], 0);
        }
        assertEq(MarketActivityScript(helper).lastAmount(), 0);
        assertEq(IERC20(asset).balanceOf(_owner), 19);
    }

    function test_ActivityReservesLowOwnerCashForAllFundedServicesAfterAccountPrograms() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address helper = address(new MarketActivityScript());
        uint256 cash = IERC20(market.asset).balanceOf(_owner);
        address custodian = makeAddr("service funding custodian");
        vm.prank(_owner);
        IERC20(market.asset).transfer(custodian, cash - 100e6);
        uint256 restakingShares = IERC20(market.vault).balanceOf(market.restakingAdapter);
        uint256 claimed = TestnetMerklDistributor(_deployed.merkl).claimed(_owner, market.asset);
        uint256[13] memory counts =
            MarketActivityScript(helper).runBase(_humanManifest(0), ".markets[0]", _owner, 75, false);
        for (uint256 i; i < counts.length; ++i) {
            assertGt(counts[i], 0);
        }
        uint256 amount = MarketActivityScript(helper).lastAmount();
        assertGt(amount, 0);
        assertLt(amount, 100e6);
        uint256 reward = amount / 20;
        assertEq(IERC20(market.asset).allowance(_owner, market.appAdapter), 0);
        assertGt(IERC20(market.vault).balanceOf(market.restakingAdapter), restakingShares);
        assertEq(TestnetMerklDistributor(_deployed.merkl).claimed(_owner, market.asset), claimed + reward);
        bytes memory uid = MarketActivityScript(helper).cowUid();
        assertEq(uid.length, 56);
        assertGt(TestnetCowSettlement(_deployed.cowSettlement).filledAmount(uid), 0);
        assertGt(IERC20(market.asset).balanceOf(_owner), 0);
        assertEq(IERC20(market.vault).balanceOf(market.appAdapter), 0);
    }

    function test_ActivityRejectsMismatchedManifestOwnerBeforeProtocolMutations() public {
        address helper = address(new MarketActivityScript());
        string memory json = _humanManifest(0);
        vm.expectRevert(ActivityManifestScript.InvalidActivity.selector);
        MarketActivityScript(helper).runBase(json, ".markets[0]", makeAddr("unexpected signer"), 75, false);
    }

    function _humanManifest(uint256 index) internal returns (string memory json) {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[index];
        string memory key = "activity-test-market";
        vm.serializeJson(key, "{}");
        vm.serializeAddress(key, "asset", market.asset);
        vm.serializeAddress(key, "rootRegistry", market.merkle.rootRegistry);
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
        vm.serializeUint(key, "aaveV4ReserveId", market.aaveV4ReserveId);
        vm.serializeAddress(key, "eulerEVC", market.eulerEVC);
        vm.serializeAddress(key, "eulerCollateralVault", market.eulerCollateralVault);
        vm.serializeAddress(key, "account", IMerkleAdapter(market.merkle.adapter).account());
        vm.serializeAddress(key, "executor", market.executor);
        vm.serializeBytes(key, "merkleActions", abi.encode(market.actions));
        vm.serializeBytes(key, "recipeSteps", abi.encode(market.recipe));
        vm.serializeAddress(key, "appAdapter", market.appAdapter);
        string memory row = vm.serializeAddress(key, "restakingAdapter", market.restakingAdapter);
        json = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"owner":"',
            vm.toString(_owner),
            '","collateral":"',
            vm.toString(_deployed.collateral),
            '","seedAssets":100000,"merklDistributor":"',
            vm.toString(_deployed.merkl),
            '","cowSettlement":"',
            vm.toString(_deployed.cowSettlement),
            '","markets":[',
            row,
            "]}"
        );
    }
}

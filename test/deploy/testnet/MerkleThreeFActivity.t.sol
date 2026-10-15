// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {RealisticDeployHarness, RealisticReportHarness, RealisticTestnetTest} from "./RealisticTestnet.t.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IRootRegistry} from "src/interfaces/merkle-adapter/IRootRegistry.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFRequestName} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ActivityManifestScript} from "script/deploy/testnet/activity/ActivityManifest.sol";
import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {MerkleProgram} from "script/deploy/testnet/activity/MerkleProgram.sol";
import {MerkleThreeFActivityScript} from "script/deploy/testnet/activity/MerkleThreeFActivity.s.sol";
import {SepoliaInfrastructure} from "script/deploy/testnet/SepoliaInfrastructure.sol";
import {TestnetPhaseScript} from "script/deploy/testnet/base/TestnetPhase.s.sol";
import {TestnetThreeFFacility, TestnetThreeFRequest} from "script/deploy/testnet/protocols/TestnetThreeF.sol";

contract MerkleThreeFActivityHarness is MerkleThreeFActivityScript {
    function mintBase(ThreeFContext memory context, address request, uint256 amount, uint256 yieldAssets) public {
        _start(context.program.owner, false);
        _mint(context, request, amount, yieldAssets);
        _stop(false);
    }

    function redeemBase(ThreeFContext memory context, address request) public {
        _start(context.program.owner, false);
        _validateRequest(context, request);
        _redeem(context, request);
        _stop(false);
    }

    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

/// @title MerkleThreeFActivityTest
/// @notice Verifies genuine account-owned 3F positions, atomic policy checks and restored strategy authorization.
contract MerkleThreeFActivityTest is RealisticTestnetTest {
    using Strings for uint256;

    function test_FundedAccountMintAndMatureBurnRestorePermissions() public {
        (address helper, string memory path, string memory result) = _configure("funded-mint");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        uint256 accountBefore = IERC20(context.asset).balanceOf(context.program.account);
        uint256 ownerBefore = IERC20(context.asset).balanceOf(_owner);
        uint256 limitBefore = IThreeFPolicy(context.policy).remainingAssets(_deployed.collateral);
        bytes32 root = IMerkleAccount(context.program.account).root();
        bytes32 recipe = IRecipeExecutor(context.program.executor).recipeHash();
        MerkleThreeFActivityHarness(helper).run();
        address request = MerkleThreeFActivityHarness(helper).lastRequest();
        uint256 amount = MerkleThreeFActivityHarness(helper).lastAmount();
        uint256 yieldAssets = MerkleThreeFActivityHarness(helper).lastYield();
        assertNotEq(request, address(0));
        assertGt(amount, 0);
        assertGt(yieldAssets, 0);
        assertTrue(IThreeFRequestFactory(context.requestsFactory).isRequest(request));
        assertEq(IERC20(context.asset).balanceOf(request), amount + yieldAssets);
        (uint256 pt, uint256 yt) = IThreeFVaultController(request).balancesOf(context.program.account);
        assertEq(pt, amount);
        assertEq(yt, yieldAssets);
        (pt, yt) = IThreeFVaultController(request).balancesOf(_owner);
        assertEq(pt, 0);
        assertEq(yt, 0);
        assertEq(IERC20(context.asset).balanceOf(context.program.account), accountBefore - amount);
        assertEq(IERC20(context.asset).balanceOf(_owner), ownerBefore - yieldAssets);
        assertEq(IERC20(context.asset).allowance(context.program.account, request), 0);
        assertEq(IThreeFPolicy(context.policy).remainingAssets(_deployed.collateral), limitBefore - amount);
        assertEq(IMerkleAccount(context.program.account).root(), root);
        assertEq(IRootRegistry(context.program.rootRegistry).roots(context.program.account), root);
        assertEq(IRecipeExecutor(context.program.executor).recipeHash(), recipe);
        vm.warp(TestnetThreeFRequest(request).maturity() - 1);
        vm.expectRevert(TestnetThreeFRequest.NotReady.selector);
        MerkleThreeFActivityHarness(helper).redeemBase(context, request);
        vm.stopPrank();
        vm.warp(TestnetThreeFRequest(request).maturity());
        vm.mockCall(
            context.whitelist,
            abi.encodeCall(IThreeFWhitelist.isWhitelisted, (request)),
            abi.encode(IThreeFWhitelist.WhitelistStatus.PausedWhitelisted)
        );
        MerkleThreeFActivityHarness(helper).redeemBase(context, request);
        (pt, yt) = IThreeFVaultController(request).balancesOf(context.program.account);
        assertEq(pt, 0);
        assertEq(yt, 0);
        assertEq(IERC20(context.asset).balanceOf(request), 0);
        assertEq(IERC20(context.asset).balanceOf(context.program.account), accountBefore + yieldAssets);
        assertEq(IERC20(context.asset).balanceOf(_owner), ownerBefore - yieldAssets);
        assertEq(MerkleThreeFActivityHarness(helper).withdrawn(), amount + yieldAssets);
        assertEq(IMerkleAccount(context.program.account).root(), root);
        assertEq(IRecipeExecutor(context.program.executor).recipeHash(), recipe);
        vm.removeFile(path);
        vm.removeFile(result);
    }

    function test_AccountMintAcceptsAnyEightBytePrefixForTheRegisteredDecimalIntent() public {
        (address helper, string memory path,) = _configure("alternate-prefix");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        address request = _authorized(context, 100e6, 1e6);
        uint256 intent = TestnetThreeFFacility(context.facility).intents();
        vm.mockCall(
            request,
            abi.encodeCall(IThreeFRequestName.name, ()),
            abi.encode(string.concat("custom--", intent.toString()))
        );
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        (uint256 principal, uint256 yieldAssets) = IThreeFVaultController(request).balancesOf(context.program.account);
        assertEq(principal, 100e6);
        assertEq(yieldAssets, 1e6);
        assertEq(IERC20(context.asset).allowance(context.program.account, request), 0);
        vm.removeFile(path);
    }

    function test_AccountMintRejectsAnEmptyOrNonDecimalIntentTail() public {
        (address helper, string memory path,) = _configure("invalid-intent-tail");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        address request = _authorized(context, 100e6, 1e6);
        vm.mockCall(request, abi.encodeCall(IThreeFRequestName.name, ()), abi.encode("custom--"));
        vm.expectRevert(ActivityManifestScript.InvalidActivity.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        vm.stopPrank();
        vm.mockCall(request, abi.encodeCall(IThreeFRequestName.name, ()), abi.encode("custom--bad"));
        vm.expectRevert(Strings.StringsInvalidChar.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        vm.stopPrank();
        vm.removeFile(path);
    }

    function test_QuietNoopMintCannotConsumePolicyOrCountAsInvestment() public {
        (address helper, string memory path, string memory result) = _configure("no-op");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        address request = _authorized(context, 100e6, 1e6);
        uint256 cash = IERC20(context.asset).balanceOf(context.program.account);
        uint256 remaining = IThreeFPolicy(context.policy).remainingAssets(_deployed.collateral);
        bytes32 root = IMerkleAccount(context.program.account).root();
        bytes32 recipe = IRecipeExecutor(context.program.executor).recipeHash();
        vm.mockCall(request, abi.encodeCall(IThreeFPushRequest.mint, (uint128(100e6), uint128(1e6))), "");
        vm.expectRevert(IRecipes.CheckFailed.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        vm.stopPrank();
        assertEq(IERC20(context.asset).balanceOf(context.program.account), cash);
        assertEq(IERC20(context.asset).allowance(context.program.account, request), 0);
        assertEq(IThreeFPolicy(context.policy).remainingAssets(_deployed.collateral), remaining);
        assertEq(IMerkleAccount(context.program.account).root(), root);
        assertEq(IRootRegistry(context.program.rootRegistry).roots(context.program.account), root);
        assertEq(IRecipeExecutor(context.program.executor).recipeHash(), recipe);
        assertEq(MerkleThreeFActivityHarness(helper).lastRequest(), address(0));
        vm.removeFile(path);
    }

    function test_RejectsUnknownRequestWrongAssetAndPausedMint() public {
        (address helper, string memory path,) = _configure("identity");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        address unknown =
            address(new TestnetThreeFRequest(_owner, context.asset, uint48(block.timestamp + 7 days), 999));
        vm.expectRevert(ActivityManifestScript.InvalidActivity.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, unknown, 100e6, 1e6);
        vm.stopPrank();
        address wrongAsset = _deployed.markets[1].request;
        vm.mockCall(
            context.requestsFactory, abi.encodeCall(IThreeFRequestFactory.isRequest, (wrongAsset)), abi.encode(true)
        );
        vm.expectRevert(ActivityManifestScript.InvalidActivity.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, wrongAsset, 100e6, 1e6);
        vm.stopPrank();
        address request = _authorized(context, 100e6, 1e6);
        vm.mockCall(
            context.whitelist,
            abi.encodeCall(IThreeFWhitelist.isWhitelisted, (request)),
            abi.encode(IThreeFWhitelist.WhitelistStatus.PausedWhitelisted)
        );
        vm.expectRevert(ActivityManifestScript.InvalidActivity.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        vm.stopPrank();
        vm.removeFile(path);
    }

    function test_MissingAuthorizationAndInsufficientPolicyDoNotPublishPermissions() public {
        (address helper, string memory path,) = _configure("authorization");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        vm.prank(_owner);
        address request = TestnetThreeFFacility(context.facility).createRequest(uint48(block.timestamp + 7 days));
        bytes32 root = IMerkleAccount(context.program.account).root();
        vm.expectRevert(ActivityManifestScript.InvalidActivity.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        vm.stopPrank();
        request = _authorized(context, 100e6, 1e6);
        vm.prank(_owner);
        IThreeFPolicy(context.policy).setMaxAssetsPerDuration(_deployed.collateral, 99e6, 1 days);
        vm.expectRevert(ActivityManifestScript.InvalidActivity.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        vm.stopPrank();
        assertEq(IMerkleAccount(context.program.account).root(), root);
        assertEq(IRootRegistry(context.program.rootRegistry).roots(context.program.account), root);
        assertEq(IERC20(context.asset).allowance(context.program.account, request), 0);
        vm.removeFile(path);
    }

    function test_ProductionPolicyMinimumYieldRevertsAccountMintAtomically() public {
        (address helper, string memory path,) = _configure("minimum-yield");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        address request = _authorized(context, 100e6, 1e6);
        uint256 cash = IERC20(context.asset).balanceOf(context.program.account);
        uint256 remaining = IThreeFPolicy(context.policy).remainingAssets(_deployed.collateral);
        bytes32 root = IMerkleAccount(context.program.account).root();
        vm.prank(_owner);
        IThreeFPolicy(context.policy).setMinYieldPerRequest(_deployed.collateral, 2_000_000);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        MerkleThreeFActivityHarness(helper).mintBase(context, request, 100e6, 1e6);
        vm.stopPrank();
        assertEq(IERC20(context.asset).balanceOf(context.program.account), cash);
        assertEq(IERC20(context.asset).allowance(context.program.account, request), 0);
        assertEq(IThreeFPolicy(context.policy).remainingAssets(_deployed.collateral), remaining);
        assertEq(IMerkleAccount(context.program.account).root(), root);
        (uint128 principal, uint128 yieldAssets) =
            IThreeFPushRequest(request).mintAuthorization(context.program.account);
        assertEq(principal, 100e6);
        assertEq(yieldAssets, 1e6);
        vm.removeFile(path);
    }

    function test_ExhaustedPolicyWaitsWithoutCreatingAnUnfundedIssuerRequest() public {
        (address helper, string memory path, string memory result) = _configure("exhausted-policy");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        uint256 issuerRequests = TestnetThreeFFacility(context.facility).intents();
        vm.prank(_owner);
        IThreeFPolicy(context.policy).setMaxAssetsPerDuration(_deployed.collateral, 0, 1 days);
        MerkleThreeFActivityHarness(helper).run();
        assertEq(TestnetThreeFFacility(context.facility).intents(), issuerRequests);
        assertEq(MerkleThreeFActivityHarness(helper).lastRequest(), address(0));
        assertFalse(vm.parseJsonBool(vm.readFile(result), ".executed"));
        vm.removeFile(path);
        vm.removeFile(result);
    }

    function test_NAVTracksNewAccountPrincipalMatureYieldAndRedemptionWithoutDoubleCounting() public {
        (address helper, string memory path, string memory result) = _configure("nav");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        uint256 navBefore = RealisticReportHarness(_report).nav(_deployed.markets[0]);
        MerkleThreeFActivityHarness(helper).run();
        address request = MerkleThreeFActivityHarness(helper).lastRequest();
        uint256 amount = MerkleThreeFActivityHarness(helper).lastAmount();
        uint256 yieldAssets = MerkleThreeFActivityHarness(helper).lastYield();
        address[] memory requests = new address[](1);
        requests[0] = request;
        assertEq(RealisticReportHarness(_report).nav(_deployed.markets[0]), navBefore - amount);
        assertEq(RealisticReportHarness(_report).navWithRequests(_deployed.markets[0], requests), navBefore);
        address[] memory withSeeded = new address[](2);
        withSeeded[0] = request;
        withSeeded[1] = _deployed.markets[0].request;
        assertEq(RealisticReportHarness(_report).navWithRequests(_deployed.markets[0], withSeeded), navBefore);
        withSeeded[1] = request;
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        RealisticReportHarness(_report).navWithRequests(_deployed.markets[0], withSeeded);
        requests[0] = _deployed.markets[1].request;
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        RealisticReportHarness(_report).navWithRequests(_deployed.markets[0], requests);
        vm.mockCall(
            context.requestsFactory,
            abi.encodeCall(IThreeFRequestFactory.isRequest, (_deployed.markets[1].request)),
            abi.encode(true)
        );
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        RealisticReportHarness(_report).navWithRequests(_deployed.markets[0], requests);
        requests[0] = request;
        vm.warp(TestnetThreeFRequest(request).maturity());
        uint256 liveBase = RealisticReportHarness(_report).nav(_deployed.markets[0]);
        uint256 matureNav = RealisticReportHarness(_report).navWithRequests(_deployed.markets[0], requests);
        assertEq(matureNav, liveBase + amount + yieldAssets);
        MerkleThreeFActivityHarness(helper).redeemBase(context, request);
        assertEq(RealisticReportHarness(_report).navWithRequests(_deployed.markets[0], requests), matureNav);
        vm.removeFile(path);
        vm.removeFile(result);
    }

    function test_RecordedRequestsRotateAtMostEightAndRetainNativeMaturity() public {
        (address helper, string memory path, string memory result) = _configure("cursor");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        address[] memory requests = new address[](10);
        string memory recorded;
        for (uint256 i; i < requests.length; ++i) {
            requests[i] = _authorized(context, 1000, 10);
            MerkleThreeFActivityHarness(helper).mintBase(context, requests[i], 1000, 10);
            recorded = i == 0 ? vm.toString(requests[i]) : string.concat(recorded, ",", vm.toString(requests[i]));
        }
        vm.setEnv("TESTNET_MERKLE_THREEF_REQUESTS", recorded);
        vm.setEnv("TESTNET_ACTIVITY_CURSOR", "2");
        MerkleThreeFActivityHarness(helper).run();
        assertEq(vm.parseJsonUint(vm.readFile(result), ".settled"), 0);
        assertEq(MerkleThreeFActivityHarness(helper).nextCursor(), 10);
        vm.warp(TestnetThreeFRequest(requests[0]).maturity());
        vm.setEnv("TESTNET_ACTIVITY_CURSOR", "2");
        MerkleThreeFActivityHarness(helper).run();
        assertEq(vm.parseJsonUint(vm.readFile(result), ".settled"), 8);
        for (uint256 i = 2; i < requests.length; ++i) {
            (uint256 pt, uint256 yt) = IThreeFVaultController(requests[i]).balancesOf(context.program.account);
            assertEq(pt, 0);
            assertEq(yt, 0);
        }
        (uint256 pt,) = IThreeFVaultController(requests[0]).balancesOf(context.program.account);
        assertEq(pt, 1000);
        assertEq(MerkleThreeFActivityHarness(helper).nextCursor(), 10);
        vm.setEnv("TESTNET_ACTIVITY_CURSOR", "10");
        MerkleThreeFActivityHarness(helper).run();
        (pt,) = IThreeFVaultController(requests[0]).balancesOf(context.program.account);
        assertEq(pt, 0);
        (pt,) = IThreeFVaultController(requests[1]).balancesOf(context.program.account);
        assertEq(pt, 0);
        vm.removeFile(path);
        vm.removeFile(result);
    }

    function testFuzz_MintUsesAccountCashAndConsumesActualPrincipal(uint256 seed) public {
        (address helper, string memory path, string memory result) = _configure("funding-fuzz");
        vm.setEnv("TESTNET_ACTIVITY_SEED", vm.toString(seed));
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        uint256 accountCash = IERC20(context.asset).balanceOf(context.program.account);
        uint256 ownerCash = IERC20(context.asset).balanceOf(_owner);
        MerkleThreeFActivityHarness(helper).run();
        uint256 amount = MerkleThreeFActivityHarness(helper).lastAmount();
        uint256 yieldAssets = MerkleThreeFActivityHarness(helper).lastYield();
        assertEq(amount, 100e6 * (25 + seed % 76) / 100);
        assertEq(IERC20(context.asset).balanceOf(context.program.account), accountCash - amount);
        assertEq(IERC20(context.asset).balanceOf(_owner), ownerCash - yieldAssets);
        assertEq(
            IERC20(context.asset).allowance(context.program.account, MerkleThreeFActivityHarness(helper).lastRequest()),
            0
        );
        vm.removeFile(path);
        vm.removeFile(result);
    }

    function test_SepoliaWaitsForGenuineAuthorizationWithoutIssuerAdministration() public {
        (address helper, string memory path, string memory result) = _configure("official-waiting");
        MerkleThreeFActivityScript.ThreeFContext memory context = _context();
        uint256 issuerRequests = TestnetThreeFFacility(context.facility).intents();
        uint256 accountCash = IERC20(context.asset).balanceOf(context.program.account);
        uint256 ownerCash = IERC20(context.asset).balanceOf(_owner);
        _officialManifest(path);
        vm.setEnv("TESTNET_MERKLE_THREEF_REQUEST_0", "0x0000000000000000000000000000000000000000");
        MerkleThreeFActivityHarness(helper).run();
        assertEq(MerkleThreeFActivityHarness(helper).lastRequest(), address(0));
        assertEq(TestnetThreeFFacility(context.facility).intents(), issuerRequests);
        assertEq(IERC20(context.asset).balanceOf(context.program.account), accountCash);
        assertEq(IERC20(context.asset).balanceOf(_owner), ownerCash);
        assertFalse(vm.parseJsonBool(vm.readFile(result), ".executed"));
        assertGt(bytes(vm.parseJsonString(vm.readFile(result), ".waiting")).length, 0);
        vm.removeFile(path);
        vm.removeFile(result);
    }

    function test_SepoliaMintInputsDoNotCrossMarketBoundaries() public {
        (address helper, string memory path, string memory result) = _configure("official-market-inputs");
        _officialManifest(path);
        vm.setEnv("TESTNET_MERKLE_THREEF_REQUEST_0", vm.toString(_deployed.markets[0].request));
        vm.setEnv("TESTNET_MERKLE_THREEF_AMOUNT_0", "100000000");
        vm.setEnv("TESTNET_MERKLE_THREEF_YIELD_0", "1000000");
        // A previously exported global request must not become another market's investor instruction.
        vm.setEnv("TESTNET_MERKLE_THREEF_REQUEST", vm.toString(_deployed.markets[0].request));
        vm.setEnv("TESTNET_MERKLE_THREEF_AMOUNT", "100000000");
        vm.setEnv("TESTNET_MERKLE_THREEF_YIELD", "1000000");
        for (uint256 i = 1; i < _deployed.markets.length; ++i) {
            vm.setEnv("TESTNET_ACTIVITY_MARKET", i.toString());
            address account = IMerkleAdapter(_deployed.markets[i].merkle.adapter).account();
            uint256 accountCash = IERC20(_deployed.markets[i].asset).balanceOf(account);
            uint256 ownerCash = IERC20(_deployed.markets[i].asset).balanceOf(_owner);
            uint256 issuerRequests = TestnetThreeFFacility(_deployed.markets[i].threeF).intents();
            bytes32 root = IMerkleAccount(account).root();
            bytes32 recipe = IRecipeExecutor(_deployed.markets[i].executor).recipeHash();
            MerkleThreeFActivityHarness(helper).run();
            assertEq(MerkleThreeFActivityHarness(helper).lastRequest(), address(0));
            assertFalse(vm.parseJsonBool(vm.readFile(result), ".executed"));
            assertEq(IERC20(_deployed.markets[i].asset).balanceOf(account), accountCash);
            assertEq(IERC20(_deployed.markets[i].asset).balanceOf(_owner), ownerCash);
            assertEq(TestnetThreeFFacility(_deployed.markets[i].threeF).intents(), issuerRequests);
            assertEq(IMerkleAccount(account).root(), root);
            assertEq(IRootRegistry(_deployed.markets[i].merkle.rootRegistry).roots(account), root);
            assertEq(IRecipeExecutor(_deployed.markets[i].executor).recipeHash(), recipe);
        }
        vm.removeFile(path);
        vm.removeFile(result);
    }

    /* INTERNAL FUNCTIONS */

    function _configure(string memory label)
        internal
        returns (address helper, string memory path, string memory result)
    {
        path = string.concat("script/deploy/testnet/manifests/merkle-threef-", label, ".json");
        result = string.concat("script/deploy/testnet/manifests/merkle-threef-", label, "-result.json");
        RealisticDeployHarness(_deploy).writeManifest(_deployed, path);
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.setEnv("TESTNET_ACTIVITY_MARKET", "0");
        vm.setEnv("TESTNET_ACTIVITY_SEED", "75");
        vm.setEnv("TESTNET_ACTIVITY_CURSOR", "0");
        vm.setEnv("TESTNET_ACTIVITY_RESULT", result);
        vm.setEnv("TESTNET_MERKLE_THREEF_REQUESTS", "");
        for (uint256 i; i < _deployed.markets.length; ++i) {
            vm.setEnv(
                string.concat("TESTNET_MERKLE_THREEF_REQUEST_", i.toString()),
                "0x0000000000000000000000000000000000000000"
            );
        }
        helper = address(new MerkleThreeFActivityHarness());
    }

    function _officialManifest(string memory path) internal {
        // This unit-test branch binds the official identities without claiming live issuer authorization.
        vm.etch(SepoliaInfrastructure.REQUESTS_FACTORY, _deployed.markets[0].threeF.code);
        vm.etch(SepoliaInfrastructure.FACILITY, _deployed.markets[0].threeF.code);
        vm.etch(SepoliaInfrastructure.WHITELIST, _deployed.markets[0].threeF.code);
        DeployRealisticTestnetScript.Deployment memory deployed = _deployed;
        deployed.chainId = SepoliaInfrastructure.CHAIN_ID;
        for (uint256 i; i < deployed.markets.length; ++i) {
            deployed.markets[i].threeF = SepoliaInfrastructure.FACILITY;
            deployed.markets[i].request = address(0);
            vm.mockCall(
                deployed.markets[i].policy,
                abi.encodeCall(IThreeFPolicy.REQUESTS_FACTORY, ()),
                abi.encode(SepoliaInfrastructure.REQUESTS_FACTORY)
            );
            vm.mockCall(
                deployed.markets[i].policy,
                abi.encodeCall(IThreeFPolicy.FACILITY, ()),
                abi.encode(SepoliaInfrastructure.FACILITY)
            );
        }
        RealisticDeployHarness(_deploy).writeManifest(deployed, path);
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        assertEq(vm.parseJsonUint(vm.readFile(path), ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(vm.readFile(path), ".threeFWhitelist"), SepoliaInfrastructure.WHITELIST);
    }

    function _context() internal view returns (MerkleThreeFActivityScript.ThreeFContext memory context) {
        context = MerkleThreeFActivityScript.ThreeFContext({
            program: MerkleProgram.Context({
                owner: _owner,
                account: IMerkleAdapter(_deployed.markets[0].merkle.adapter).account(),
                rootRegistry: _deployed.markets[0].merkle.rootRegistry,
                executor: _deployed.markets[0].executor,
                baseActions: _deployed.markets[0].actions,
                baseRecipe: _deployed.markets[0].recipe
            }),
            asset: _deployed.markets[0].asset,
            policy: _deployed.markets[0].policy,
            requestsFactory: _deployed.markets[0].threeF,
            facility: _deployed.markets[0].threeF,
            whitelist: _deployed.markets[0].threeF
        });
    }

    function _authorized(MerkleThreeFActivityScript.ThreeFContext memory context, uint128 amount, uint128 yieldAssets)
        internal
        returns (address request)
    {
        vm.startPrank(_owner);
        request = TestnetThreeFFacility(context.facility).createRequest(uint48(block.timestamp + 7 days));
        IERC20(context.asset).transfer(request, yieldAssets);
        TestnetThreeFRequest(request).authorizeMinting(context.program.account, amount, yieldAssets);
        vm.stopPrank();
    }
}

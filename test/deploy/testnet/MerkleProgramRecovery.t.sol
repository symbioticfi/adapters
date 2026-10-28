// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IUpstreamAavePool, IUpstreamSpoke} from "script/deploy/testnet/protocols/UpstreamAave.sol";
import {IUpstreamEVault, IUpstreamEVC} from "script/deploy/testnet/protocols/UpstreamEuler.sol";

import {IMidnight} from "morpho-midnight/src/interfaces/IMidnight.sol";

import {RealisticDeployHarness, RealisticTestnetTest} from "./RealisticTestnet.t.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {MerkleProgram} from "script/deploy/testnet/activity/MerkleProgram.sol";
import {RecoverMerkleProgramScript} from "script/deploy/testnet/RecoverMerkleProgram.s.sol";
import {TestnetMidnightLender} from "script/deploy/testnet/protocols/TestnetNativeLending.sol";

contract RecoverMerkleProgramHarness is RecoverMerkleProgramScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

/// @title MerkleProgramRecoveryTest
/// @notice Verifies explicit idempotent authorization repair after any partially broadcast strategy program.
contract MerkleProgramRecoveryTest is RealisticTestnetTest {
    function testFuzz_RecoveryRestoresAnyInterruptedRootAndRecipeCombination(uint8 progress) public {
        MerkleProgram.Context memory context = _context();
        address helper = address(new RecoverMerkleProgramHarness());
        bytes32 baseRoot = IMerkleAccount(context.account).root();
        bytes32 baseRecipe = RecipeExecutor(context.executor).recipeHash();
        address spender = makeAddr("outstanding interrupted approval");
        vm.prank(context.account);
        IERC20(_deployed.markets[0].asset).approve(spender, 77);
        uint256 cash = IERC20(_deployed.markets[0].asset).balanceOf(context.account);
        uint256 shares = IERC20(
                IUpstreamAavePool(_deployed.markets[0].aave).getReserveAToken(_deployed.markets[0].asset)
            )
            .balanceOf(context.account);
        bytes32 temporaryRoot = keccak256("interrupted program root");
        vm.startPrank(_owner);
        RootRegistry(context.rootRegistry).setRoot(context.account, temporaryRoot);
        IMerkleAccount(context.account).acceptRoot(temporaryRoot);
        if ((progress & 1) == 0) {
            RootRegistry(context.rootRegistry).setRoot(context.account, baseRoot);
            IMerkleAccount(context.account).acceptRoot(baseRoot);
            RootRegistry(context.rootRegistry).setRoot(context.account, temporaryRoot);
        }
        if ((progress & 2) == 0) RootRegistry(context.rootRegistry).setRoot(context.account, baseRoot);
        if ((progress & 4) > 0) {
            bytes[] memory temporaryRecipe = new bytes[](1);
            temporaryRecipe[0] = hex"0102";
            RecipeExecutor(context.executor).setRecipe(new bytes[](0), temporaryRecipe);
        }
        vm.stopPrank();
        RecoverMerkleProgramScript(helper).runBase(context, false);
        assertEq(IMerkleAccount(context.account).root(), baseRoot);
        assertEq(RootRegistry(context.rootRegistry).roots(context.account), baseRoot);
        assertEq(RecipeExecutor(context.executor).recipeHash(), baseRecipe);
        assertEq(IERC20(_deployed.markets[0].asset).balanceOf(context.account), cash);
        assertEq(
            IERC20(IUpstreamAavePool(_deployed.markets[0].aave).getReserveAToken(_deployed.markets[0].asset))
                .balanceOf(context.account),
            shares
        );
        // Economic cleanup is an explicit separate decision; restoring authorization does not spend or revoke it.
        assertEq(IERC20(_deployed.markets[0].asset).allowance(context.account, spender), 77);
        vm.recordLogs();
        RecoverMerkleProgramScript(helper).runBase(context, false);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_RecoveryReadsTheExistingManifestWithoutActivitySeedOrResult() public {
        address helper = address(new RecoverMerkleProgramHarness());
        MerkleProgram.Context memory context = _context();
        bytes32 baseRoot = IMerkleAccount(context.account).root();
        string memory path = "script/deploy/testnet/manifests/merkle-recovery-test.json";
        RealisticDeployHarness(_deploy).writeManifest(_deployed, path);
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.setEnv("TESTNET_ACTIVITY_MARKET", "0");
        vm.startPrank(_owner);
        RootRegistry(context.rootRegistry).setRoot(context.account, keccak256("interrupted proposed root"));
        IMerkleAccount(context.account).acceptRoot(bytes32(0));
        RecipeExecutor(context.executor).setRecipe(new bytes[](0), new bytes[](0));
        vm.stopPrank();
        RecoverMerkleProgramScript(helper).run();
        assertEq(IMerkleAccount(context.account).root(), baseRoot);
        assertEq(RootRegistry(context.rootRegistry).roots(context.account), baseRoot);
        assertEq(
            RecipeExecutor(context.executor).recipeHash(), keccak256(abi.encode(new bytes[](0), context.baseRecipe))
        );
        vm.removeFile(path);
    }

    function test_ClearApprovalUsesTheAccountAndLeavesOtherAllowancesAndCashUntouched() public {
        (address helper, string memory path) = _configure("allowance");
        MerkleProgram.Context memory context = _context();
        address token = _deployed.markets[0].asset;
        address spender = makeAddr("selected interrupted spender");
        address other = makeAddr("unrelated spender");
        vm.startPrank(context.account);
        IERC20(token).approve(spender, 77);
        IERC20(token).approve(other, 88);
        vm.stopPrank();
        uint256 cash = IERC20(token).balanceOf(context.account);
        bytes32 baseRoot = IMerkleAccount(context.account).root();
        vm.startPrank(_owner);
        RootRegistry(context.rootRegistry).setRoot(context.account, keccak256("interrupted root"));
        IMerkleAccount(context.account).acceptRoot(bytes32(0));
        RecipeExecutor(context.executor).setRecipe(new bytes[](0), new bytes[](0));
        vm.stopPrank();
        RecoverMerkleProgramScript(helper).clearApproval(token, spender);
        assertEq(IERC20(token).allowance(context.account, spender), 0);
        assertEq(IERC20(token).allowance(context.account, other), 88);
        assertEq(IERC20(token).balanceOf(context.account), cash);
        assertEq(IMerkleAccount(context.account).root(), baseRoot);
        assertEq(RootRegistry(context.rootRegistry).roots(context.account), baseRoot);
        assertEq(
            RecipeExecutor(context.executor).recipeHash(), keccak256(abi.encode(new bytes[](0), context.baseRecipe))
        );
        vm.recordLogs();
        RecoverMerkleProgramScript(helper).clearApproval(token, spender);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.removeFile(path);
    }

    function test_ClearApprovalRejectsAQuietNoopToken() public {
        (address helper, string memory path) = _configure("noop-allowance");
        MerkleProgram.Context memory context = _context();
        address token = _deployed.markets[0].asset;
        address spender = makeAddr("selected interrupted spender");
        vm.prank(context.account);
        IERC20(token).approve(spender, 77);
        vm.mockCall(token, abi.encodeCall(IERC20.approve, (spender, uint256(0))), abi.encode(true));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        RecoverMerkleProgramScript(helper).clearApproval(token, spender);
        vm.stopPrank();
        assertEq(IERC20(token).allowance(context.account, spender), 77);
        vm.removeFile(path);
    }

    function test_RevokeSignatureRemovesOnlyTheSelectedDigestAndRestoresAuthorization() public {
        (address helper, string memory path) = _configure("signature");
        MerkleProgram.Context memory context = _context();
        bytes32 domain = keccak256("interrupted order domain");
        bytes memory buffer = abi.encode(uint256(77));
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](1);
        plan[0] = IMerkleAccount.Hash({offset: 0, length: 32, destination: 0});
        vm.prank(context.account);
        IMerkleAccount(context.account).sign(domain, buffer, plan);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, keccak256(buffer)));
        buffer = abi.encode(uint256(88));
        vm.prank(context.account);
        IMerkleAccount(context.account).sign(domain, buffer, plan);
        bytes32 other = keccak256(abi.encodePacked("\x19\x01", domain, keccak256(buffer)));
        assertTrue(IMerkleAccount(context.account).signatures(digest));
        assertTrue(IMerkleAccount(context.account).signatures(other));
        bytes32 baseRoot = IMerkleAccount(context.account).root();
        vm.startPrank(_owner);
        RootRegistry(context.rootRegistry).setRoot(context.account, keccak256("interrupted root"));
        IMerkleAccount(context.account).acceptRoot(bytes32(0));
        vm.stopPrank();
        RecoverMerkleProgramScript(helper).revokeSignature(digest);
        assertFalse(IMerkleAccount(context.account).signatures(digest));
        assertTrue(IMerkleAccount(context.account).signatures(other));
        assertEq(IMerkleAccount(context.account).root(), baseRoot);
        vm.recordLogs();
        RecoverMerkleProgramScript(helper).revokeSignature(digest);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.removeFile(path);
    }

    function test_ClearMidnightOfferDisablesLenderPermissionWithoutWithdrawingExistingCredit() public {
        (address helper, string memory path) = _configure("midnight-offer");
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address lender = market.nativeLending.midnightLender;
        uint256 cash = IERC20(market.asset).balanceOf(lender);
        uint256 credit = IMidnight(market.nativeLending.midnight).credit(market.nativeLending.midnightId, lender);
        uint256 debt = IMidnight(market.nativeLending.midnight).debt(market.nativeLending.midnightId, _owner);
        RecoverMerkleProgramScript(helper).clearMidnightOffer();
        assertEq(TestnetMidnightLender(lender).taker(), address(0));
        assertEq(IERC20(market.asset).allowance(lender, market.nativeLending.midnight), 0);
        assertEq(IERC20(market.asset).balanceOf(lender), cash);
        assertEq(IMidnight(market.nativeLending.midnight).credit(market.nativeLending.midnightId, lender), credit);
        assertEq(IMidnight(market.nativeLending.midnight).debt(market.nativeLending.midnightId, _owner), debt);
        RecoverMerkleProgramScript(helper).clearMidnightOffer();
        assertEq(TestnetMidnightLender(lender).taker(), address(0));
        vm.removeFile(path);
    }

    function testFuzz_RecoveryRejectsAnyUnexpectedOwnerBeforeChangingTheRoot(uint8 which) public {
        address helper = address(new RecoverMerkleProgramHarness());
        MerkleProgram.Context memory context = _context();
        bytes32 temporaryRoot = keccak256("interrupted proposed root");
        vm.startPrank(_owner);
        RootRegistry(context.rootRegistry).setRoot(context.account, temporaryRoot);
        address[3] memory authorities = [context.account, context.rootRegistry, context.executor];
        Ownable(authorities[which % authorities.length]).transferOwnership(makeAddr("new authority owner"));
        vm.stopPrank();
        vm.expectRevert(MerkleProgram.InvalidProgram.selector);
        RecoverMerkleProgramScript(helper).runBase(context, false);
        assertEq(RootRegistry(context.rootRegistry).roots(context.account), temporaryRoot);
    }

    function test_RecoveryRejectsAnUnexpectedCallerAndMismatchedRegistry() public {
        address helper = address(new RecoverMerkleProgramHarness());
        MerkleProgram.Context memory context = _context();
        bytes32 root = IMerkleAccount(context.account).root();
        vm.prank(_owner);
        RecipeExecutor(context.executor).setCaller(makeAddr("unexpected caller"));
        vm.expectRevert(MerkleProgram.InvalidProgram.selector);
        RecoverMerkleProgramScript(helper).runBase(context, false);
        vm.prank(_owner);
        RecipeExecutor(context.executor).setCaller(_owner);
        context.rootRegistry = _deployed.markets[1].merkle.rootRegistry;
        vm.expectRevert(MerkleProgram.InvalidProgram.selector);
        RecoverMerkleProgramScript(helper).runBase(context, false);
        assertEq(IMerkleAccount(context.account).root(), root);
    }

    function test_RecoveryRejectsUnsupportedChains() public {
        address helper = address(new RecoverMerkleProgramHarness());
        MerkleProgram.Context memory context = _context();
        vm.chainId(1);
        vm.expectRevert(RecoverMerkleProgramScript.InvalidRecovery.selector);
        RecoverMerkleProgramScript(helper).runBase(context, false);
    }

    function _configure(string memory label) internal returns (address helper, string memory path) {
        helper = address(new RecoverMerkleProgramHarness());
        path = string.concat("script/deploy/testnet/manifests/merkle-recovery-", label, ".json");
        RealisticDeployHarness(_deploy).writeManifest(_deployed, path);
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.setEnv("TESTNET_ACTIVITY_MARKET", "0");
    }

    function _context() internal view returns (MerkleProgram.Context memory context) {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        context = MerkleProgram.Context({
            owner: _owner,
            account: IMerkleAdapter(market.merkle.adapter).account(),
            rootRegistry: market.merkle.rootRegistry,
            executor: market.executor,
            baseActions: market.actions,
            baseRecipe: market.recipe
        });
    }
}

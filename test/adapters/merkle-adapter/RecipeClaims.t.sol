// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_SUB,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimRecipe} from "script/recipes/ClaimRecipe.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";

/// @dev Real executor and Merkle routing with local settlement fixtures, not live protocol coverage.
contract RecipeClaimsTest is CapabilityTestBase {
    address internal _asset;
    address internal _redeemVault;
    address internal _withdrawVault;
    address internal _mintVault;
    address internal _rewards;
    address internal _rewardA;
    address internal _rewardB;
    address internal _executor;
    IMerkleAccount.Action[] internal _actions;
    ExecutingRecipe.Recipe internal _recipe;

    function setUp() public {
        _asset = address(new AsyncClaimTokenMock(6));
        _rewardA = address(new AsyncClaimTokenMock(18));
        _rewardB = address(new AsyncClaimTokenMock(18));
        _redeemVault = address(new AsyncClaimVaultMock(_asset));
        _withdrawVault = address(new AsyncClaimVaultMock(_asset));
        _mintVault = address(new AsyncClaimVaultMock(_asset));
        _rewards = address(new AsyncRewardsMock(_rewardA, _rewardB));
        _deployAdapter(_asset);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));

        AsyncClaimTokenMock(_asset).mint(account, 117e6);
        AsyncClaimVaultMock(_redeemVault).seedShares(account, 100e18);
        AsyncClaimVaultMock(_withdrawVault).seedShares(account, 100e18);
        AsyncClaimTokenMock(_asset).mint(_redeemVault, 100e6);
        AsyncClaimTokenMock(_asset).mint(_withdrawVault, 100e6);
        // Requests execute through the custody account in earlier transactions. Claims spend neither
        // these assets nor these shares again, and require no leftover allowance.
        _manage(_asset, abi.encodeCall(IERC20.approve, (_mintVault, 100e6)));
        _manage(_mintVault, abi.encodeCall(AsyncClaimVaultMock.requestDeposit, (100e6, account, account)));
        _manage(_asset, abi.encodeCall(IERC20.approve, (_mintVault, 0)));
        _manage(_redeemVault, abi.encodeCall(AsyncClaimVaultMock.requestRedeem, (100e18, account, account)));
        _manage(_withdrawVault, abi.encodeCall(AsyncClaimVaultMock.requestRedeem, (100e18, account, account)));
        vm.roll(block.number + 1);
        _configurePermissions();
        _install(_claims());
    }

    function test_PartialRedemptionAndMintClaimWhileWithdrawalAndRewardsArePending() public {
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, 20e6);
        bytes[] memory runtime = _runtime();
        runtime[1] = hex"deadbeef";
        runtime[3] = hex"deadbeef";
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 57e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 20e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).pendingRedeem(account), 60e18);
        assertEq(AsyncClaimVaultMock(_mintVault).pendingDeposit(account), 80e6);
        assertEq(AsyncClaimVaultMock(_withdrawVault).pendingRedeem(account), 100e18);
        assertEq(IERC20(_asset).allowance(account, _mintVault), 0);

        // The same committed recipe claims subsequent settlements in later transactions.
        vm.roll(block.number + 10);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 60e18);
        AsyncClaimVaultMock(_withdrawVault).settleRedeem(account, 100e18);
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, 80e6);
        AsyncRewardsMock(_rewards).accrue(account, 7e18);
        _execute(_runtime());
        assertEq(IERC20(_asset).balanceOf(account), 217e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 100e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 7e18);
        assertEq(IERC20(_rewardB).balanceOf(account), 14e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).pendingRedeem(account), 0);
        assertEq(AsyncClaimVaultMock(_withdrawVault).pendingRedeem(account), 0);
        assertEq(AsyncClaimVaultMock(_mintVault).pendingDeposit(account), 0);

        bytes[] memory emptyRuntime = _runtime();
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(emptyRuntime);
    }

    /// forge-config: default.isolate = true
    function test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens() public {
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 100e18);
        AsyncClaimVaultMock(_withdrawVault).settleRedeem(account, 100e18);
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, 100e6);
        AsyncRewardsMock(_rewards).accrue(account, 5e18);
        _execute(_runtime());
        vm.snapshotGasLastCall("RecipeClaims", "claimRedemptionWithdrawalMintRewards");
        assertEq(IERC20(_asset).balanceOf(account), 217e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 100e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 5e18);
        assertEq(IERC20(_rewardB).balanceOf(account), 10e18);
        assertEq(IERC20(_asset).allowance(account, _mintVault), 0);
    }

    function test_AllPendingClaimsRevertWithoutSpendingOldBalances() public {
        AsyncClaimTokenMock(_rewardA).mint(account, 100e18);
        bytes[] memory runtime = new bytes[](4);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_rewardA).balanceOf(account), 100e18);
        assertEq(AsyncClaimVaultMock(_mintVault).pendingDeposit(account), 100e6);
    }

    function test_UnreadyClaimStillRequiresRetiredTokenOutputReads() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[3].outputs[0].token = address(0xDEAD);
        _install(claims);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        bytes[] memory runtime = _runtime();
        runtime[3] = hex"deadbeef";
        vm.expectRevert(abi.encodeWithSignature("AddressEmptyCode(address)", address(0xDEAD)));
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 0);
    }

    function test_UnreadyClaimStillRequiresRevertingTokenOutputReads() public {
        vm.mockCallRevert(
            _rewardA,
            abi.encodeCall(IERC20.balanceOf, (account)),
            abi.encodeWithSelector(AsyncClaimBalanceLensMock.OutputUnavailable.selector)
        );
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        bytes[] memory runtime = _runtime();
        runtime[3] = hex"deadbeef";
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimBalanceLensMock.OutputUnavailable.selector));
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
    }

    function test_UnreadyClaimStillRequiresRevertingCustomBalanceOutputReads() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[3].outputs[0].token = address(0);
        claims[3].outputs[0].balance = ExecutingRecipe.Read({
            target: address(new AsyncClaimBalanceLensMock()),
            data: abi.encodeCall(AsyncClaimBalanceLensMock.getBalance, (account)),
            offset: 0
        });
        _install(claims);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        bytes[] memory runtime = _runtime();
        runtime[3] = hex"deadbeef";
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimBalanceLensMock.OutputUnavailable.selector));
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
    }

    function test_AllUnreadyClaimsWithUnavailableOutputsStillRevertForNoProgress() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        for (uint256 i; i < claims.length; ++i) {
            claims[i].maxAmount = 1;
        }
        claims[3].outputs[0].token = address(0xDEAD);
        claims[3].outputs[1].token = address(0);
        claims[3].outputs[1].balance = ExecutingRecipe.Read({
            target: address(new AsyncClaimBalanceLensMock()),
            data: abi.encodeCall(AsyncClaimBalanceLensMock.getBalance, (account)),
            offset: 0
        });
        _install(claims);
        bytes[] memory runtime = new bytes[](4);
        vm.expectRevert(abi.encodeWithSignature("AddressEmptyCode(address)", address(0xDEAD)));
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(AsyncClaimVaultMock(_redeemVault).pendingRedeem(account), 100e18);
    }

    function test_BoundedPartiallyReadyClaimsUseAvailableAmountsBelowCaps() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[0].maxAmount = 60e18;
        claims[1].maxAmount = 60e6;
        claims[2].maxAmount = 60e18;
        claims[3].maxAmount = 6e18;
        _install(claims);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        AsyncClaimVaultMock(_withdrawVault).settleRedeem(account, 20e18);
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, 30e6);
        AsyncRewardsMock(_rewards).accrue(account, 3e18);
        _execute(_runtime());
        assertEq(IERC20(_asset).balanceOf(account), 77e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 30e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 3e18);
        assertEq(IERC20(_rewardB).balanceOf(account), 6e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 0);
        assertEq(AsyncClaimVaultMock(_withdrawVault).maxWithdraw(account), 0);
        assertEq(AsyncClaimVaultMock(_mintVault).maxMint(account), 0);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 0);
        assertEq(AsyncClaimVaultMock(_redeemVault).pendingRedeem(account), 60e18);
        assertEq(AsyncClaimVaultMock(_withdrawVault).pendingRedeem(account), 80e18);
        assertEq(AsyncClaimVaultMock(_mintVault).pendingDeposit(account), 70e6);
    }

    function test_BoundedFullyReadyClaimsLeaveRemaindersForRepeatedExecutions() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[0].maxAmount = 30e18;
        claims[1].maxAmount = 40e6;
        claims[2].maxAmount = 25e18;
        claims[3].maxAmount = 3e18;
        _install(claims);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 100e18);
        AsyncClaimVaultMock(_withdrawVault).settleRedeem(account, 100e18);
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, 100e6);
        AsyncRewardsMock(_rewards).accrue(account, 7e18);

        _execute(_runtime());
        assertEq(IERC20(_asset).balanceOf(account), 87e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 25e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 3e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 70e18);
        assertEq(AsyncClaimVaultMock(_withdrawVault).maxWithdraw(account), 60e6);
        assertEq(AsyncClaimVaultMock(_mintVault).maxMint(account), 75e18);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 4e18);

        vm.roll(block.number + 1);
        _execute(_runtime());
        assertEq(IERC20(_asset).balanceOf(account), 157e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 50e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 6e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
        assertEq(AsyncClaimVaultMock(_withdrawVault).maxWithdraw(account), 20e6);
        assertEq(AsyncClaimVaultMock(_mintVault).maxMint(account), 50e18);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 1e18);

        vm.roll(block.number + 1);
        _execute(_runtime());
        assertEq(IERC20(_asset).balanceOf(account), 207e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 75e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 7e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 10e18);
        assertEq(AsyncClaimVaultMock(_withdrawVault).maxWithdraw(account), 0);
        assertEq(AsyncClaimVaultMock(_mintVault).maxMint(account), 25e18);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 0);

        vm.roll(block.number + 1);
        _execute(_runtime());
        assertEq(IERC20(_asset).balanceOf(account), 217e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 100e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 7e18);
        assertEq(IERC20(_rewardB).balanceOf(account), 14e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 0);
        assertEq(AsyncClaimVaultMock(_withdrawVault).maxWithdraw(account), 0);
        assertEq(AsyncClaimVaultMock(_mintVault).maxMint(account), 0);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 0);
        assertEq(IERC20(_asset).allowance(account, _mintVault), 0);

        bytes[] memory emptyRuntime = new bytes[](4);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(emptyRuntime);
    }

    function test_BoundedClaimWithRoundedZeroOutputCannotMakeProgress() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[0].maxAmount = 1;
        _install(claims);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        bytes[] memory runtime = _runtime();
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
    }

    function test_OptionalRewardTokenMayHaveZeroOutput() public {
        AsyncRewardsMock(_rewards).setSecondReward(false);
        AsyncRewardsMock(_rewards).accrue(account, 3e18);
        _execute(_runtime());
        assertEq(IERC20(_rewardA).balanceOf(account), 3e18);
        assertEq(IERC20(_rewardB).balanceOf(account), 0);
    }

    function test_RewardClaimWithoutAmountParameterUsesReadinessOnlyAsGate() public {
        ClaimRecipe.Claim memory claim = _claims()[3];
        claim.amountOffsets[0] = new uint256[](0);
        bytes[] memory runtime = _singleClaim(claim, _rewards, abi.encodeCall(AsyncRewardsMock.getReward, (account)));
        AsyncRewardsMock(_rewards).accrue(account, 5e18);
        _execute(runtime);
        assertEq(IERC20(_rewardA).balanceOf(account), 5e18);
        assertEq(IERC20(_rewardB).balanceOf(account), 10e18);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
    }

    function test_BoundedRewardClaimWithoutAmountParameterRejectsOverclaim() public {
        ClaimRecipe.Claim memory claim = _claims()[3];
        claim.maxAmount = 40e18;
        claim.amountOffsets[0] = new uint256[](0);
        bytes[] memory runtime = _singleClaim(claim, _rewards, abi.encodeCall(AsyncRewardsMock.getReward, (account)));
        AsyncRewardsMock(_rewards).accrue(account, 100e18);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 100e18);
        assertEq(IERC20(_rewardA).balanceOf(account), 0);
        assertEq(IERC20(_rewardB).balanceOf(account), 0);
    }

    function test_BoundedRewardClaimWithoutAmountParameterCanCollectBelowCap() public {
        ClaimRecipe.Claim memory claim = _claims()[3];
        claim.maxAmount = 40e18;
        claim.amountOffsets[0] = new uint256[](0);
        bytes[] memory runtime = _singleClaim(claim, _rewards, abi.encodeCall(AsyncRewardsMock.getReward, (account)));
        AsyncRewardsMock(_rewards).accrue(account, 30e18);
        _execute(runtime);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 0);
        assertEq(IERC20(_rewardA).balanceOf(account), 30e18);
        assertEq(IERC20(_rewardB).balanceOf(account), 60e18);
    }

    function test_AsyncDepositClaimsMintedSharesWithoutSpendingAssetsTwice() public {
        ClaimRecipe.Claim memory claim = _claims()[2];
        claim.claimable.data = abi.encodeCall(AsyncClaimVaultMock.maxDeposit, (account));
        claim.outputs[0].minNumerator = 1e12;
        bytes[] memory runtime =
            _singleClaim(claim, _mintVault, abi.encodeCall(AsyncClaimVaultMock.deposit, (0, account)));
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, 20e6);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 20e18);
        assertEq(IERC20(_asset).allowance(account, _mintVault), 0);
        assertEq(AsyncClaimVaultMock(_mintVault).pendingDeposit(account), 80e6);
    }

    function test_PartialNativeWithdrawalClaimsUseNewEthNotOldBalance() public {
        address queue = address(new AsyncNativeClaimMock());
        vm.deal(queue, 2 ether);
        vm.deal(account, 7 ether);
        AsyncNativeClaimMock(queue).seedPending(account, 2 ether);
        ClaimRecipe.Claim memory claim = _claims()[0];
        claim.claimable = ExecutingRecipe.query(
            ExecutingRecipe.Read({
                target: queue, data: abi.encodeWithSignature("claimable(address)", account), offset: 0
            })
        );
        claim.outputs[0].token = address(0);
        claim.outputs[0].balance = ExecutingRecipe.Read({
            target: queue, data: abi.encodeCall(AsyncNativeClaimMock.getEthBalance, (account)), offset: 0
        });
        claim.outputs[0].denominator = 1;
        bytes[] memory runtime = _singleClaim(claim, queue, abi.encodeCall(AsyncNativeClaimMock.claim, (0, account)));
        AsyncNativeClaimMock(queue).settle(account, 1 ether);
        _execute(runtime);
        assertEq(account.balance, 8 ether);
        assertEq(AsyncNativeClaimMock(queue).pending(account), 1 ether);

        vm.roll(block.number + 1);
        AsyncNativeClaimMock(queue).settle(account, 1 ether);
        AsyncNativeClaimMock(queue).setNoPayout(true);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(account.balance, 8 ether);
        assertEq(AsyncNativeClaimMock(queue).claimable(account), 1 ether);

        AsyncNativeClaimMock(queue).setNoPayout(false);
        _execute(runtime);
        assertEq(account.balance, 9 ether);
        assertEq(AsyncNativeClaimMock(queue).pending(account), 0);
    }

    function test_OutputlessClaimCannotHideBehindAnotherSuccessfulClaimOrOldBalances() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[3].outputs[0].minNumerator = 0;
        _install(claims);
        AsyncClaimTokenMock(_rewardA).mint(account, 100e18);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        AsyncRewardsMock(_rewards).accrue(account, 3e18);
        AsyncRewardsMock(_rewards).setNoPayout(true);
        bytes[] memory runtime = _runtime();
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_rewardA).balanceOf(account), 100e18);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 3e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
    }

    function test_InsufficientClaimOutputRollsBackEarlierClaims() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[2].outputs[0].minNumerator = 2;
        _install(claims);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, 20e6);
        bytes[] memory runtime = _runtime();
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_mintVault).balanceOf(account), 0);
        assertEq(AsyncClaimVaultMock(_mintVault).maxMint(account), 20e18);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
    }

    function test_ClaimRecipientRemainsPinnedToCustodyAccount() public {
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        bytes[] memory runtime = _runtime();
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[0], (IMerkleAccount.Action[]));
        actions[0].data = abi.encodeCall(AsyncClaimVaultMock.redeem, (0, address(0xBAD), account));
        runtime[0] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(address(0xBAD)), 0);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
    }

    function testFuzz_PartialMintCanBeClaimedWithoutAnotherAssetTransfer(uint256 assets) public {
        assets = bound(assets, 1, 100e6 - 1);
        AsyncClaimVaultMock(_mintVault).settleDeposit(account, assets);
        _execute(_runtime());
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_mintVault).balanceOf(account), assets * 1e12);
        assertEq(AsyncClaimVaultMock(_mintVault).pendingDeposit(account), 100e6 - assets);
        assertEq(IERC20(_asset).allowance(account, _mintVault), 0);
    }

    function testFuzz_BoundedRedemptionSelectsAvailableAmountOrCap(uint256 ready, uint256 cap) public {
        ready = bound(ready, 1e12, 100e18);
        cap = bound(cap, 1e12, 100e18);
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[0].maxAmount = cap;
        _install(claims);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, ready);
        _execute(_runtime());
        uint256 selected = ready < cap ? ready : cap;
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + selected / 1e12);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), ready - selected);
        assertEq(AsyncClaimVaultMock(_redeemVault).pendingRedeem(account), 100e18 - ready);
    }

    function testFuzz_InvalidClaimConfigurationIsRejected(uint8 field) public {
        field = uint8(bound(field, 0, 7));
        ClaimRecipe.Claim[] memory claims = _claims();
        address custody = account;
        if (field == 0) custody = address(0);
        else if (field == 1) claims = new ClaimRecipe.Claim[](0);
        else if (field == 2) claims[0].claimable.target = address(0);
        else if (field == 3) claims[0].leaves = new bytes32[](0);
        else if (field == 4) claims[0].outputs = new ClaimRecipe.Output[](0);
        else if (field == 5) claims[0].outputs[0].denominator = 0;
        else if (field == 6) claims[0].outputs[0].token = address(0);
        else claims[0].outputs[0].balance = ExecutingRecipe.Read({target: _asset, data: "", offset: 0});
        vm.expectRevert(ClaimRecipe.InvalidConfiguration.selector);
        this.build(custody, claims);
    }

    function build(address custody, ClaimRecipe.Claim[] memory claims) public pure {
        ClaimRecipe.build(custody, claims);
    }

    /// forge-config: default.isolate = true
    function test_GasO09BoundedIdentityClaim() public {
        ClaimRecipe.Claim memory claim = _claims()[1];
        claim.maxAmount = 40e6;
        claim.outputs[0].minNumerator = 1e18;
        claim.outputs[0].denominator = 1e18;
        bytes[] memory runtime =
            _singleClaim(claim, _withdrawVault, abi.encodeCall(AsyncClaimVaultMock.withdraw, (0, account, account)));
        AsyncClaimVaultMock(_withdrawVault).settleRedeem(account, 100e18);
        _execute(runtime);
        vm.snapshotGasLastCall("RecipeClaims", "O09BoundedIdentityClaim");
        assertEq(IERC20(_asset).balanceOf(account), 57e6);
        assertEq(AsyncClaimVaultMock(_withdrawVault).maxWithdraw(account), 60e6);
        assertEq(AsyncClaimVaultMock(_withdrawVault).maxRedeem(account), 60e18);
        assertEq(AsyncClaimVaultMock(_withdrawVault).pendingRedeem(account), 0);
    }

    function test_O09SemanticIdentitySelectionBoundariesAndFullWidthReads() public {
        uint256[4] memory factors = [uint256(1), 2, 1e18, type(uint216).max];
        uint256[5] memory ready = [uint256(0), 1, 3, 4, type(uint256).max];
        for (uint256 i; i < factors.length; ++i) {
            for (uint256 j; j < ready.length; ++j) {
                _o09Lens(ready[j], 3, factors[i], false);
            }
        }
    }

    function testFuzz_O09SemanticFullWidthReadiness(uint256 ready, uint64 cap, uint8 factor) public {
        uint256[4] memory factors = [uint256(1), 2, 1e18, type(uint216).max];
        _o09Lens(ready, bound(cap, 1, 1000), factors[factor % 4], false);
    }

    function test_O09SemanticThresholdRetainsCheckedOverflow() public {
        uint256[2] memory factors = [uint256(1e18), type(uint216).max];
        for (uint256 i; i < factors.length; ++i) {
            uint256 threshold = type(uint256).max / factors[i];
            _o09Lens(type(uint256).max, threshold, factors[i], false);
            _o09Lens(threshold, threshold + 1, factors[i], false);
            _o09Lens(threshold + 1, threshold + 1, factors[i], true);
            _o09Lens(threshold + 1, 0, factors[i], true);
            _o09Lens(1, 0, factors[i], false);
        }
    }

    function test_O09SemanticLiteralWidthsAndFailureOrder() public {
        ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](1);
        claims[0] = _claims()[1];
        uint256 invalid = uint256(type(uint216).max) + 1;
        claims[0].maxAmount = invalid;
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", uint8(216), invalid));
        this.build(account, claims);
        claims[0].outputs[0].denominator = 0;
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", uint8(216), invalid));
        this.build(account, claims);
        vm.expectRevert(ClaimRecipe.InvalidConfiguration.selector);
        this.build(address(0), claims);
        claims[0].maxAmount = 1;
        vm.expectRevert(ClaimRecipe.InvalidConfiguration.selector);
        this.build(account, claims);
        claims[0].outputs[0].minNumerator = invalid;
        claims[0].outputs[0].denominator = invalid;
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", uint8(216), invalid));
        this.build(account, claims);
        for (uint256 d = 1; d <= 2; ++d) {
            uint256 threshold = type(uint256).max / d;
            claims[0].outputs[0].minNumerator = d;
            claims[0].outputs[0].denominator = d;
            claims[0].maxAmount = threshold;
            vm.expectRevert(
                abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", uint8(216), threshold)
            );
            this.build(account, claims);
            if (threshold < type(uint256).max) {
                claims[0].maxAmount = threshold + 1;
                vm.expectRevert(
                    abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", uint8(216), threshold + 1)
                );
                this.build(account, claims);
            }
        }
    }

    function test_O09SemanticUnequalFractionalAndZeroNumeratorsKeepBehavior() public {
        for (uint256 n; n < 3; ++n) {
            ClaimRecipe.Claim memory claim = _claims()[1];
            claim.maxAmount = 3;
            claim.outputs[0].minNumerator = n;
            claim.outputs[0].denominator = 2;
            bytes[] memory runtime = _singleClaim(
                claim, _withdrawVault, abi.encodeCall(AsyncClaimVaultMock.withdraw, (0, account, account))
            );
            AsyncClaimVaultMock(_withdrawVault).settleRedeem(account, 3e12);
            _execute(runtime);
            assertEq(AsyncClaimVaultMock(_withdrawVault).maxWithdraw(account), 0);
        }
    }

    function test_O09SemanticDebitAndPayoutFailuresRollBack() public {
        for (uint256 mode; mode < 4; ++mode) {
            address lens = address(new ClaimO09Lens(10));
            ClaimRecipe.Claim memory claim = _o09LensClaim(lens, 3, 1e18);
            bytes[] memory runtime = _singleClaim(claim, lens, abi.encodeCall(ClaimO09Lens.claim, (0, account)));
            ClaimO09Lens(lens).setEffects(mode);
            vm.expectRevert(IRecipes.CheckFailed.selector);
            _execute(runtime);
            assertEq(ClaimO09Lens(lens).ready(), 10);
            assertEq(ClaimO09Lens(lens).cash(), 0);
        }
    }

    function test_O09SemanticRepeatedMultiOutputClaimsPreserveOldBalancesAndWitness() public {
        address lens = address(new ClaimO09Lens(10));
        ClaimRecipe.Claim memory claim = _o09LensClaim(lens, 3, 1e18);
        ClaimRecipe.Output memory required = claim.outputs[0];
        claim.outputs = new ClaimRecipe.Output[](2);
        claim.outputs[0] = required;
        claim.outputs[1] = required;
        claim.outputs[1].minNumerator = 2;
        claim.outputs[1].denominator = 2;
        bytes[] memory runtime = _singleClaim(claim, lens, abi.encodeCall(ClaimO09Lens.claim, (0, account)));
        _execute(runtime);
        _execute(runtime);
        assertEq(ClaimO09Lens(lens).ready(), 4);
        assertEq(ClaimO09Lens(lens).cash(), 6);
        ClaimO09Lens(lens).setEffects(2);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(ClaimO09Lens(lens).ready(), 4);
        assertEq(ClaimO09Lens(lens).cash(), 6);
    }

    function test_O09SemanticQueryAndActiveRuntimeFailuresRemainOrdered() public {
        address lens = address(new ClaimO09Lens(3));
        bytes[] memory runtime =
            _singleClaim(_o09LensClaim(lens, 3, 1e18), lens, abi.encodeCall(ClaimO09Lens.claim, (0, account)));
        ClaimO09Lens(lens).setQueryFailure(true);
        vm.expectRevert(ClaimO09Lens.QueryFailed.selector);
        _execute(runtime);
        ClaimO09Lens(lens).setQueryFailure(false);
        runtime[0] = hex"deadbeef";
        vm.expectRevert(bytes(""));
        _execute(runtime);
        assertEq(ClaimO09Lens(lens).ready(), 3);
        assertEq(ClaimO09Lens(lens).cash(), 0);
    }

    function _o09MulDivCount(ExecutingRecipe.Recipe memory recipe) internal pure returns (uint256 count) {
        for (uint256 i; i < recipe.steps.length; ++i) {
            if (uint8(recipe.steps[i][0]) == OP_MUL_DIV) ++count;
        }
    }

    function _o09LensClaim(address lens, uint256 cap, uint256 factor)
        internal
        view
        returns (ClaimRecipe.Claim memory claim)
    {
        claim = _claims()[1];
        claim.maxAmount = cap;
        claim.claimable = ExecutingRecipe.query(
            ExecutingRecipe.Read({target: lens, data: abi.encodeCall(ClaimO09Lens.readiness, (account)), offset: 0})
        );
        claim.outputs[0] = ClaimRecipe.Output({
            token: address(0),
            balance: ExecutingRecipe.Read({
                target: lens, data: abi.encodeCall(ClaimO09Lens.balance, (account)), offset: 0
            }),
            minNumerator: factor,
            denominator: factor
        });
    }

    function _o09Lens(uint256 ready, uint256 cap, uint256 factor, bool overflow) internal {
        address lens = address(new ClaimO09Lens(ready));
        bytes[] memory runtime =
            _singleClaim(_o09LensClaim(lens, cap, factor), lens, abi.encodeCall(ClaimO09Lens.claim, (0, account)));
        uint256 selected = cap > 0 && cap < ready ? cap : ready;
        uint256 operand = _stepWord(_recipe.steps[ExecutingRecipe.runtimeSteps(_recipe)[0]], 1);
        if (overflow) {
            assertGe(_o09MulDivCount(_recipe), 1, "unsafe or uncapped multiplication must remain");
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
            _execute(runtime);
            assertEq(ClaimO09Lens(lens).ready(), ready);
            assertEq(ClaimO09Lens(lens).cash(), 0);
            return;
        }
        if (selected == 0) {
            vm.expectRevert(IRecipes.CheckFailed.selector);
            _execute(runtime);
        }
        // Keep the genuine production prefix; at zero omit only its final no-progress check.
        uint256 prefix = _recipe.steps.length - (selected == 0 ? 1 : 0);
        bytes[] memory steps = new bytes[](prefix + 1);
        for (uint256 i; i < prefix; ++i) {
            steps[i] = _recipe.steps[i];
        }
        // Retained original checked arithmetic is a same-execution differential control.
        steps[prefix] = bytes.concat(bytes1(OP_MUL_DIV), abi.encode(operand, factor, factor));
        RecipeExecutor(_executor).setRecipe(_recipe.queries, steps);
        uint256[] memory values = RecipeExecutor(_executor).execute(_recipe.queries, steps, new uint256[](0), runtime);
        assertEq(values[prefix], selected);
        assertEq(values[uint216(operand)], selected);
        assertEq(ClaimO09Lens(lens).cash(), selected);
        assertEq(ClaimO09Lens(lens).ready(), ready - selected);
    }

    function test_O08SemanticReadinessBoundariesAndOptionalZeroOutput() public {
        uint256[5] memory readiness = [uint256(0), 1, 1, 4, 4];
        uint256[5] memory caps = [uint256(0), 0, 1, 0, 1];
        uint256[5] memory selected = [uint256(0), 1, 1, 4, 1];
        for (uint256 i; i < readiness.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _assertO08RewardSelection(readiness[i], caps[i], selected[i], 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testFuzz_O08SemanticQualifyingFractionalAndOptionalSelection(uint64 ready, uint64 cap, uint8 mode) public {
        mode = uint8(bound(mode, 0, 2));
        _assertO08RewardSelection(ready, cap, cap > 0 && cap < ready ? cap : ready, mode);
    }

    function test_O08SemanticFullWidthReadinessRetainsRequiredAndOptionalOutputs() public {
        _assertO08RewardSelection(type(uint256).max, 0, type(uint256).max, 0);
    }

    function test_O08SemanticMissingLaterQualifyingOutputRollsBackEarlierSuccess() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[3].maxAmount = 1;
        _install(claims);
        AsyncClaimTokenMock(_rewardA).mint(account, 100);
        AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
        AsyncRewardsMock(_rewards).accrue(account, 4);
        AsyncRewardsMock(_rewards).setNoPayout(true);
        bytes[] memory runtime = _runtime();
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_rewardA).balanceOf(account), 100);
        assertEq(IERC20(_rewardB).balanceOf(account), 0);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 4);
        assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
    }

    function test_O08SemanticFractionalAndOptionalOnlyGroupsCannotHideMissingOutput() public {
        for (uint256 mode = 1; mode <= 2; ++mode) {
            uint256 snapshot = vm.snapshotState();
            ClaimRecipe.Claim[] memory claims = _claims();
            claims[3].maxAmount = 1;
            claims[3].outputs[0].minNumerator = mode == 1 ? 1 : 0;
            claims[3].outputs[0].denominator = 2;
            _install(claims);
            AsyncClaimTokenMock(_rewardA).mint(account, 100);
            AsyncClaimVaultMock(_redeemVault).settleRedeem(account, 40e18);
            AsyncRewardsMock(_rewards).accrue(account, 4);
            AsyncRewardsMock(_rewards).setNoPayout(true);
            bytes[] memory runtime = _runtime();
            vm.expectRevert(IRecipes.CheckFailed.selector);
            _execute(runtime);
            assertEq(IERC20(_asset).balanceOf(account), 17e6);
            assertEq(IERC20(_rewardA).balanceOf(account), 100);
            assertEq(AsyncRewardsMock(_rewards).earned(account), 4);
            assertEq(AsyncClaimVaultMock(_redeemVault).maxRedeem(account), 40e18);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_O08SemanticQualifyingNativeAndCustomSnapshotsRejectMissingPayout() public {
        address queue = address(new AsyncNativeClaimMock());
        vm.deal(queue, 2 ether);
        vm.deal(account, 7 ether);
        AsyncNativeClaimMock(queue).seedPending(account, 2 ether);
        ClaimRecipe.Claim memory claim = _claims()[3];
        claim.maxAmount = 1 ether;
        claim.claimable = ExecutingRecipe.query(
            ExecutingRecipe.Read({
                target: queue, data: abi.encodeWithSignature("claimable(address)", account), offset: 0
            })
        );
        claim.outputs[0].token = address(0);
        claim.outputs[0].balance = ExecutingRecipe.Read({
            target: queue, data: abi.encodeCall(AsyncNativeClaimMock.getEthBalance, (account)), offset: 0
        });
        claim.outputs[1].token = address(0);
        claim.outputs[1].balance =
            ExecutingRecipe.Read({target: _rewardA, data: abi.encodeCall(IERC20.balanceOf, (account)), offset: 0});
        AsyncClaimTokenMock(_rewardA).mint(account, 100);
        bytes[] memory runtime = _singleClaim(claim, queue, abi.encodeCall(AsyncNativeClaimMock.claim, (0, account)));
        AsyncNativeClaimMock(queue).settle(account, 2 ether);
        _execute(runtime);
        assertEq(account.balance, 8 ether);
        assertEq(IERC20(_rewardA).balanceOf(account), 100);
        assertEq(AsyncNativeClaimMock(queue).claimable(account), 1 ether);
        AsyncNativeClaimMock(queue).setNoPayout(true);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(account.balance, 8 ether);
        assertEq(IERC20(_rewardA).balanceOf(account), 100);
        assertEq(AsyncNativeClaimMock(queue).claimable(account), 1 ether);
    }

    function test_O03FractionalCappedClaimCannotSucceedWithoutOutput() public {
        ClaimRecipe.Claim memory claim = _claims()[3];
        claim.maxAmount = 1;
        claim.outputs[0].minNumerator = 1;
        claim.outputs[0].denominator = 2;
        AsyncRewardsMock(_rewards).setNoPayout(true);
        bytes[] memory runtime = _singleClaim(claim, _rewards, abi.encodeCall(AsyncRewardsMock.claim, (0, account)));
        AsyncRewardsMock(_rewards).accrue(account, 4);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 4);
        assertEq(IERC20(_rewardA).balanceOf(account), 0);
    }

    function test_O02OneUnitOptionalOutputMakesProgress() public {
        ClaimRecipe.Claim memory claim = _claims()[3];
        claim.outputs[0].minNumerator = 0;
        AsyncRewardsMock(_rewards).setSecondReward(false);
        bytes[] memory runtime = _singleClaim(claim, _rewards, abi.encodeCall(AsyncRewardsMock.claim, (0, account)));
        AsyncRewardsMock(_rewards).accrue(account, 1);
        _execute(runtime);
        assertEq(IERC20(_rewardA).balanceOf(account), 1);
        assertEq(IERC20(_rewardB).balanceOf(account), 0);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 0);
    }

    function test_O02FullWidthOutputsAcrossGroupsDoNotOverflowProgress() public {
        address rewards = address(new AsyncRewardsMock(_rewardB, _rewardA));
        AsyncRewardsMock(_rewards).setSecondReward(false);
        AsyncRewardsMock(rewards).setSecondReward(false);
        AsyncRewardsMock(_rewards).accrue(account, type(uint256).max);
        AsyncRewardsMock(rewards).accrue(account, type(uint256).max);
        ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](2);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        bytes32[] memory leaves = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            address target = i == 0 ? _rewards : rewards;
            claims[i] = _claims()[3];
            claims[i].claimable.target = target;
            claims[i].outputs = new ClaimRecipe.Output[](1);
            claims[i].outputs[0] = ClaimRecipe.Output({
                token: i == 0 ? _rewardA : _rewardB,
                balance: ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
                minNumerator: 0,
                denominator: 1
            });
            actions[i] = _action(target, abi.encodeCall(AsyncRewardsMock.claim, (0, account)));
            leaves[i] = ActionMasker.mask(target, 0, actions[i].data, actions[i].dataMask);
            claims[i].leaves[0] = leaves[i];
            MerkleAccount(payable(account)).grantRole(leaves[i], _executor);
        }
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        bytes[] memory runtime = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            actions[i].proof = new bytes32[](1);
            actions[i].proof[0] = leaves[1 - i];
            IMerkleAccount.Action[] memory one = new IMerkleAccount.Action[](1);
            one[0] = actions[i];
            runtime[i] = abi.encode(one);
        }
        _install(claims);
        _execute(runtime);
        assertEq(IERC20(_rewardA).balanceOf(account), type(uint256).max);
        assertEq(IERC20(_rewardB).balanceOf(account), type(uint256).max);
        assertEq(AsyncRewardsMock(_rewards).earned(account), 0);
        assertEq(AsyncRewardsMock(rewards).earned(account), 0);
    }

    function test_O02MinimumMultiplicationStillOverflows() public {
        ClaimRecipe.Claim memory claim = _claims()[3];
        claim.outputs[0].minNumerator = 1e18;
        claim.outputs[0].denominator = 1e18;
        AsyncRewardsMock(_rewards).setSecondReward(false);
        bytes[] memory runtime = _singleClaim(claim, _rewards, abi.encodeCall(AsyncRewardsMock.claim, (0, account)));
        AsyncRewardsMock(_rewards).accrue(account, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        _execute(runtime);
        assertEq(AsyncRewardsMock(_rewards).earned(account), type(uint256).max);
        assertEq(IERC20(_rewardA).balanceOf(account), 0);
    }

    function test_ManyRewardOutputsFitBuilderCapacity() public view {
        ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](1);
        claims[0] = _claims()[3];
        claims[0].outputs = new ClaimRecipe.Output[](8);
        for (uint256 i; i < claims[0].outputs.length; ++i) {
            claims[0].outputs[i] = ClaimRecipe.Output({
                token: address(uint160(0x1000 + i)),
                balance: ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
                minNumerator: 3 + i,
                denominator: 2
            });
        }
        (ExecutingRecipe.Recipe memory recipe, uint256[] memory calls) = ClaimRecipe.build(account, claims);
        assertEq(calls.length, 1);
        assertEq(recipe.queries.length, 9);
    }

    function _stepWord(bytes memory step, uint256 offset) internal pure returns (uint256 word) {
        assembly ("memory-safe") { word := mload(add(add(step, 32), offset)) }
    }

    function _assertO08RewardSelection(uint256 ready, uint256 cap, uint256 selected, uint8 mode) internal {
        ClaimRecipe.Claim[] memory claims = _claims();
        claims[3].maxAmount = cap;
        if (mode == 1) claims[3].outputs[0].denominator = 2;
        if (mode == 2) claims[3].outputs[0].minNumerator = 0;
        _install(claims);
        AsyncRewardsMock(_rewards).setSecondReward(false);
        AsyncRewardsMock(_rewards).accrue(account, ready);
        bytes[] memory runtime = _runtime();
        for (uint256 i; i < 3; ++i) {
            runtime[i] = hex"deadbeef";
        }
        if (selected == 0) vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_rewardA).balanceOf(account), selected);
        assertEq(IERC20(_rewardB).balanceOf(account), 0);
        assertEq(AsyncRewardsMock(_rewards).earned(account), ready - selected);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(AsyncClaimVaultMock(_redeemVault).pendingRedeem(account), 100e18);
        assertEq(AsyncClaimVaultMock(_withdrawVault).pendingRedeem(account), 100e18);
        assertEq(AsyncClaimVaultMock(_mintVault).pendingDeposit(account), 100e6);
    }

    function _claims() internal view returns (ClaimRecipe.Claim[] memory claims) {
        claims = new ClaimRecipe.Claim[](4);
        address[4] memory targets = [_redeemVault, _withdrawVault, _mintVault, _rewards];
        bytes4[4] memory selectors = [
            AsyncClaimVaultMock.maxRedeem.selector,
            AsyncClaimVaultMock.maxWithdraw.selector,
            AsyncClaimVaultMock.maxMint.selector,
            bytes4(keccak256("earned(address)"))
        ];
        address[4] memory tokens = [_asset, _asset, _mintVault, _rewardA];
        for (uint256 i; i < claims.length; ++i) {
            claims[i].claimable = ExecutingRecipe.query(
                ExecutingRecipe.Read({
                    target: targets[i], data: abi.encodeWithSelector(selectors[i], account), offset: 0
                })
            );
            claims[i].leaves = new bytes32[](1);
            claims[i].leaves[0] = _leaf(i);
            claims[i].amountOffsets = new uint256[][](1);
            claims[i].amountOffsets[0] = new uint256[](1);
            claims[i].amountOffsets[0][0] = 4;
            claims[i].outputs = new ClaimRecipe.Output[](i == 3 ? 2 : 1);
            claims[i].outputs[0] = ClaimRecipe.Output({
                token: tokens[i],
                balance: ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
                minNumerator: 1,
                denominator: i == 0 ? 1e12 : 1
            });
        }
        claims[3].outputs[1] = ClaimRecipe.Output({
            token: _rewardB,
            balance: ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
            minNumerator: 0,
            denominator: 1
        });
    }

    function _install(ClaimRecipe.Claim[] memory claims) internal {
        (ExecutingRecipe.Recipe memory recipe,) = ClaimRecipe.build(account, claims);
        _recipe = recipe;
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
    }

    function _singleClaim(ClaimRecipe.Claim memory claim, address target, bytes memory data)
        internal
        returns (bytes[] memory runtime)
    {
        IMerkleAccount.Action[] memory actions = _publishCall(target, data);
        if (claim.amountOffsets[0].length > 0) {
            for (uint256 i = 4; i < 36; ++i) {
                actions[0].dataMask[i] = 0xff;
            }
        }
        claim.leaves[0] = ActionMasker.mask(target, 0, data, actions[0].dataMask);
        roots.setRoot(account, claim.leaves[0]);
        MerkleAccount(payable(account)).acceptRoot(claim.leaves[0]);
        MerkleAccount(payable(account)).grantRole(claim.leaves[0], _executor);
        ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](1);
        claims[0] = claim;
        _install(claims);
        runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
    }

    function _configurePermissions() internal {
        _actions.push(_action(_redeemVault, abi.encodeCall(AsyncClaimVaultMock.redeem, (0, account, account))));
        _actions.push(_action(_withdrawVault, abi.encodeCall(AsyncClaimVaultMock.withdraw, (0, account, account))));
        _actions.push(_action(_mintVault, abi.encodeCall(AsyncClaimVaultMock.mint, (0, account))));
        _actions.push(_action(_rewards, abi.encodeCall(AsyncRewardsMock.claim, (0, account))));
        bytes32[] memory nodes = new bytes32[](7);
        for (uint256 i; i < _actions.length; ++i) {
            nodes[3 + i] = _leaf(i);
            MerkleAccount(payable(account)).grantRole(nodes[3 + i], _executor);
        }
        for (uint256 i = 3; i > 0;) {
            --i;
            bytes32 left = nodes[i * 2 + 1];
            bytes32 right = nodes[i * 2 + 2];
            nodes[i] =
                left < right ? keccak256(abi.encodePacked(left, right)) : keccak256(abi.encodePacked(right, left));
        }
        for (uint256 i; i < _actions.length; ++i) {
            uint256 cursor = 3 + i;
            while (cursor > 0) {
                _actions[i].proof.push(nodes[cursor % 2 == 1 ? cursor + 1 : cursor - 1]);
                cursor = (cursor - 1) / 2;
            }
        }
        roots.setRoot(account, nodes[0]);
        MerkleAccount(payable(account)).acceptRoot(nodes[0]);
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAccount.Action memory) {
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 4; i < 36; ++i) {
            mask[i] = 0xff;
        }
        return IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _leaf(uint256 index) internal view returns (bytes32) {
        return ActionMasker.mask(_actions[index].target, 0, _actions[index].data, _actions[index].dataMask);
    }

    function _runtime() internal view returns (bytes[] memory runtime) {
        runtime = new bytes[](4);
        for (uint256 i; i < runtime.length; ++i) {
            IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
            actions[0] = _actions[i];
            // Deliberately incorrect: the recipe binds the freshly read claimable amount.
            bytes memory data = actions[0].data;
            assembly ("memory-safe") { mstore(add(data, 36), 999) }
            runtime[i] = abi.encode(actions);
        }
    }

    function _execute(bytes[] memory runtime) internal {
        RecipeExecutor(_executor).execute(_recipe.queries, _recipe.steps, new uint256[](0), runtime);
    }
}

contract AsyncClaimTokenMock is ERC20 {
    uint8 internal immutable _decimals;

    constructor(uint8 newDecimals) ERC20("Fixture asset", "ASSET") {
        _decimals = newDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address receiver, uint256 amount) public {
        _mint(receiver, amount);
    }
}

contract AsyncClaimBalanceLensMock {
    error OutputUnavailable();

    function getBalance(address) public pure returns (uint256) {
        revert OutputUnavailable();
    }
}

/// @dev ERC-7540-style local fixture: pending excludes claimable, and claims never transfer inputs twice.
contract AsyncClaimVaultMock is ERC20 {
    error AsyncPreview();
    address public immutable asset;
    mapping(address => uint256) public pendingDeposit;
    mapping(address => uint256) public pendingRedeem;
    mapping(address => uint256) internal _claimableMint;
    mapping(address => uint256) internal _claimableRedeem;

    constructor(address newAsset) ERC20("Fixture shares", "SHARE") {
        asset = newAsset;
    }

    function seedShares(address receiver, uint256 shares) public {
        _mint(receiver, shares);
    }

    function requestDeposit(uint256 assets, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender);
        IERC20(asset).transferFrom(owner, address(this), assets);
        pendingDeposit[controller] += assets;
        return 0;
    }

    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender);
        _burn(owner, shares);
        pendingRedeem[controller] += shares;
        return 0;
    }

    function settleDeposit(address controller, uint256 assets) public {
        pendingDeposit[controller] -= assets;
        _claimableMint[controller] += assets * 1e12;
    }

    function settleRedeem(address controller, uint256 shares) public {
        pendingRedeem[controller] -= shares;
        _claimableRedeem[controller] += shares;
    }

    function maxMint(address controller) public view returns (uint256) {
        return _claimableMint[controller];
    }

    function maxDeposit(address controller) public view returns (uint256) {
        return _claimableMint[controller] / 1e12;
    }

    function maxRedeem(address controller) public view returns (uint256) {
        return _claimableRedeem[controller];
    }

    function maxWithdraw(address controller) public view returns (uint256) {
        return _claimableRedeem[controller] / 1e12;
    }

    function previewMint(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function previewWithdraw(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function previewRedeem(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        _claimableMint[msg.sender] -= shares;
        _mint(receiver, shares);
        return shares / 1e12;
    }

    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = assets * 1e12;
        _claimableMint[msg.sender] -= shares;
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        require(controller == msg.sender);
        _claimableRedeem[controller] -= shares;
        assets = shares / 1e12;
        IERC20(asset).transfer(receiver, assets);
    }

    function withdraw(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        require(controller == msg.sender);
        shares = assets * 1e12;
        _claimableRedeem[controller] -= shares;
        IERC20(asset).transfer(receiver, assets);
    }
}

contract AsyncRewardsMock {
    address public immutable rewardA;
    address public immutable rewardB;
    mapping(address => uint256) public earned;
    bool internal _secondReward = true;
    bool internal _noPayout;

    constructor(address newRewardA, address newRewardB) {
        rewardA = newRewardA;
        rewardB = newRewardB;
    }

    function accrue(address controller, uint256 amount) public {
        earned[controller] += amount;
    }

    function setSecondReward(bool enabled) public {
        _secondReward = enabled;
    }

    function setNoPayout(bool enabled) public {
        _noPayout = enabled;
    }

    function getReward(address receiver) public {
        claim(earned[msg.sender], receiver);
    }

    function claim(uint256 amount, address receiver) public {
        earned[msg.sender] -= amount;
        if (_noPayout) return;
        AsyncClaimTokenMock(rewardA).mint(receiver, amount);
        if (_secondReward) AsyncClaimTokenMock(rewardB).mint(receiver, 2 * amount);
    }
}

/// @dev Local ETH settlement fixture and balance lens; no live issuer behavior is claimed.
contract AsyncNativeClaimMock {
    mapping(address => uint256) public pending;
    mapping(address => uint256) public claimable;
    bool internal _noPayout;

    function seedPending(address controller, uint256 amount) public {
        pending[controller] += amount;
    }

    function settle(address controller, uint256 amount) public {
        pending[controller] -= amount;
        claimable[controller] += amount;
    }

    function getEthBalance(address controller) public view returns (uint256) {
        return controller.balance;
    }

    function setNoPayout(bool enabled) public {
        _noPayout = enabled;
    }

    function claim(uint256 amount, address receiver) public {
        claimable[msg.sender] -= amount;
        if (_noPayout) return;
        (bool success,) = receiver.call{value: amount}("");
        require(success);
    }
}

/// @dev Raw readiness/output units avoid unrelated token supply or decimal conversion arithmetic.
contract ClaimO09Lens {
    error QueryFailed();
    uint256 public ready;
    uint256 public cash;
    uint256 internal _effects;
    bool internal _queryFailure;

    constructor(uint256 newReady) {
        ready = newReady;
    }

    function setEffects(uint256 mode) public {
        _effects = mode + 1;
    }

    function setQueryFailure(bool value) public {
        _queryFailure = value;
    }

    function readiness(address) public view returns (uint256) {
        if (_queryFailure) revert QueryFailed();
        return ready;
    }

    function balance(address) public view returns (uint256) {
        return cash;
    }

    function claim(uint256 amount, address recipient) public {
        require(recipient == msg.sender);
        ready -= _effects == 1 ? amount - 1 : _effects == 2 ? amount + 1 : amount;
        cash += _effects == 3 ? amount - 1 : _effects == 4 ? 0 : amount;
    }
}

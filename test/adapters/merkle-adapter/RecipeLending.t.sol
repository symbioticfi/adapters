// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LendingRecipe} from "script/recipes/LendingRecipe.sol";

/// @dev Local protocol-effects fixture; this suite does not claim a live Aave or issuer execution.
contract RecipeLendingTest is CapabilityTestBase {
    bytes internal _recipe;

    address internal _lbtc;
    address internal _usdc;
    address internal _rwa;
    address internal _receipt;
    address internal _debt;
    address internal _pool;
    address internal _issuer;
    address internal _health;
    address internal _executor;
    LendingRecipe.Config internal _config;
    LendingRecipe.Layout internal _layout;
    IMerkleAccount.Action[] internal _actions;

    function setUp() public {
        _lbtc = address(new RecipeLendingTokenMock("LBTC", 8));
        _usdc = address(new RecipeLendingTokenMock("USDC", 6));
        _rwa = address(new RecipeLendingTokenMock("RWA", 18));
        _receipt = address(new RecipeLendingTokenMock("aLBTC", 8));
        _debt = address(new RecipeLendingTokenMock("variableDebtUSDC", 6));
        _pool = address(new RecipeAavePoolMock(_lbtc, _usdc, _receipt, _debt));
        _issuer = address(new RecipeIssuerMock(_usdc, _rwa));
        _health = address(new AaveHealthFactor());
        _deployAdapter(_lbtc);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        _minimum = 1.2e18;
        _executor = new ImmutableFactory(type(RecipeExecutor).creationCode).create(abi.encode(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _configurePermissions();
        (ExecutingRecipe.Recipe memory recipe, LendingRecipe.Layout memory layout) = LendingRecipe.build(
            _config, LendingRecipe.Limits({maxSupplyLbtc: 2e8, maxTotalDebtUsdc: 40_000e6, minRwaPerUsdcWad: 0.99e18})
        );
        _layout = layout;
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);

        RecipeLendingTokenMock(_lbtc).mint(account, 5e8);
        RecipeLendingTokenMock(_usdc).mint(account, 17e6);
        RecipeLendingTokenMock(_rwa).mint(account, 3e18);
        RecipeLendingTokenMock(_usdc).mint(_pool, 1_000_000e6);
    }

    function test_RecipeSuppliesBorrowsAndPurchasesThroughRealAdapterAndCapability() public {
        vm.prank(account);
        IERC20(_lbtc).approve(_pool, 7);
        vm.prank(account);
        IERC20(_usdc).approve(_issuer, 9);

        uint256[] memory values = _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));

        assertEq(IERC20(_lbtc).balanceOf(account), 4e8);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 1e8);
        assertEq(IERC20(_receipt).balanceOf(account), 1e8);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 20_000e6);
        assertEq(IERC20(_rwa).balanceOf(account), 20_003e18);
        assertEq(values[uint216(_layout.borrowedUsdc)], 20_000e6);
        assertEq(values[uint216(_layout.minimumRwa)], 19_800e18);
        assertEq(RecipeLendingTokenMock(_lbtc).allowanceAtLastPull(), 1e8);
        assertEq(RecipeLendingTokenMock(_usdc).allowanceAtLastPull(), 20_000e6);
        assertEq(IERC20(_lbtc).allowance(account, _pool), 0);
        assertEq(IERC20(_usdc).allowance(account, _issuer), 0);
        assertEq(IERC20(_usdc).balanceOf(_executor), 0);
        assertEq(AaveHealthFactor(_health).getHealthFactor(_pool, account), 2.4e18);
    }

    function test_OrdinaryCleanupRequiresBothProofsAndPreservesBalances() public {
        _config.skipZeroApprovals = true;
        (ExecutingRecipe.Recipe memory recipe, LendingRecipe.Layout memory layout) = LendingRecipe.build(
            _config, LendingRecipe.Limits({maxSupplyLbtc: 2e8, maxTotalDebtUsdc: 40_000e6, minRwaPerUsdcWad: 0.99e18})
        );
        _layout = layout;
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        runtime[uint256(LendingRecipe.Action.ClearLbtcApproval)] = hex"deadbeef";
        vm.expectRevert();
        _execute(1e8, 20_000e6, runtime);
        runtime = _runtime(1e8, 20_000e6, 20_000e6);
        runtime[uint256(LendingRecipe.Action.ClearUsdcApproval)] = hex"deadbeef";
        vm.expectRevert();
        _execute(1e8, 20_000e6, runtime);
        runtime = _runtime(1e8, 20_000e6, 20_000e6);
        _execute(1e8, 20_000e6, runtime);
        assertEq(IERC20(_lbtc).allowance(account, _pool), 0);
        assertEq(IERC20(_usdc).allowance(account, _issuer), 0);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6);
        assertEq(IERC20(_rwa).balanceOf(account), 20_003e18);
    }

    function test_AsyncPurchaseRequestsThenClaimsAfterSeparateSettlement() public {
        RecipeIssuerMock(_issuer).setAsynchronous(true);
        _config.purchaseReceipt = ExecutingRecipe.Read({
            target: _issuer, data: abi.encodeWithSignature("pendingShares(address)", account), offset: 0
        });
        (ExecutingRecipe.Recipe memory recipe, LendingRecipe.Layout memory layout) = LendingRecipe.build(
            _config, LendingRecipe.Limits({maxSupplyLbtc: 2e8, maxTotalDebtUsdc: 40_000e6, minRwaPerUsdcWad: 0.99e18})
        );
        _layout = layout;
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        uint256[] memory values = _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        assertEq(values[uint216(layout.rwaReceived)], 20_000e18);
        assertEq(IERC20(_rwa).balanceOf(account), 3e18);
        assertEq(RecipeIssuerMock(_issuer).pendingShares(account), 20_000e18);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_usdc).allowance(account, _issuer), 0);
        vm.roll(block.number + 1);
        RecipeIssuerMock(_issuer).settle(account, 8000e18);
        _manage(_issuer, abi.encodeCall(RecipeIssuerMock.claim, (8000e18, account)));
        assertEq(IERC20(_rwa).balanceOf(account), 8003e18);
        assertEq(RecipeIssuerMock(_issuer).pendingShares(account), 12_000e18);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        vm.roll(block.number + 1);
        RecipeIssuerMock(_issuer).settle(account, 12_000e18);
        _manage(_issuer, abi.encodeCall(RecipeIssuerMock.claim, (12_000e18, account)));
        assertEq(IERC20(_rwa).balanceOf(account), 20_003e18);
        assertEq(RecipeIssuerMock(_issuer).pendingShares(account), 0);
        assertEq(RecipeIssuerMock(_issuer).claimableShares(account), 0);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
    }

    function test_AsyncPurchaseWithoutReceiptQueryRollsBackBorrow() public {
        RecipeIssuerMock(_issuer).setAsynchronous(true);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
        assertEq(RecipeIssuerMock(_issuer).pendingShares(account), 0);
    }

    function testFuzz_AmountsPreserveExistingFundsAndPriceFloor(uint256 supply, uint256 borrowAmount) public {
        supply = bound(supply, 1e8, 2e8);
        borrowAmount = bound(borrowAmount, 1e6, 20_000e6);
        RecipeIssuerMock(_issuer).setOutputRate(0.99e18);

        uint256[] memory values = _execute(supply, borrowAmount, _runtime(supply, borrowAmount, borrowAmount));

        assertEq(IERC20(_lbtc).balanceOf(account), 5e8 - supply);
        assertEq(IERC20(_receipt).balanceOf(account), supply);
        assertEq(IERC20(_debt).balanceOf(account), borrowAmount);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_rwa).balanceOf(account), 3e18 + borrowAmount * 0.99e18 / 1e6);
        assertEq(values[uint216(_layout.rwaReceived)], values[uint216(_layout.minimumRwa)]);
    }

    function test_RepeatedExecutionStopsAtTotalDebtCap() public {
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        bytes[] memory runtime = _runtime(1e8, 1e6, 1e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 1e6, runtime);
        assertEq(IERC20(_debt).balanceOf(account), 40_000e6);
        assertEq(IERC20(_lbtc).balanceOf(account), 3e8);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_rwa).balanceOf(account), 40_003e18);
    }

    function test_RecipeCapabilityHealthFailureRollsBackSupply() public {
        bytes[] memory runtime = _runtime(1e8, 40_000e6, 40_000e6);
        RecipeAavePoolMock(_pool).setLiquidationThreshold(7000);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 40_000e6, runtime);
        _assertPristine();
    }

    function test_SupplyAmountIsInsertedFromInput() public {
        bytes[] memory runtime = _runtime(1e8 - 1, 20_000e6, 20_000e6);
        _execute(1e8, 20_000e6, runtime);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 20_000e6);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 1e8);
    }

    function test_BorrowAmountIsInsertedIntoNestedGuardedCall() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6 + 1, 20_000e6);
        _execute(1e8, 20_000e6, runtime);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 20_000e6);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 1e8);
    }

    function test_PurchaseAmountUsesMeasuredBorrowedCash() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6 - 1);
        _execute(1e8, 20_000e6, runtime);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 20_000e6);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 1e8);
    }

    function test_RuntimeCannotMakePurchaseSpendPreexistingUsdc() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_001e6);
        _execute(1e8, 20_000e6, runtime);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 20_000e6);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 1e8);
    }

    function test_RevertWhenPoolSpendsLessCollateral() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(-1, 0);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenSupplyConsumesExistingUsdc() public {
        RecipeAavePoolMock(_pool).setSupplyUsdcSpent(1e6);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function testFuzz_RevertWhenReceiptDiffersByMoreThanRounding(uint256 shortfall) public {
        shortfall = bound(shortfall, 2, 1e8);
        RecipeAavePoolMock(_pool).setSupplyEffects(0, -int256(shortfall));
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function testFuzz_RevertWhenDebtExceedsBorrowedBeyondRounding(uint256 additionalDebt) public {
        additionalDebt = bound(additionalDebt, 2, 10_000e6);
        RecipeAavePoolMock(_pool).setBorrowEffects(0, int256(additionalDebt));
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_IndexedTokenRoundingAllowsOnlyOneBaseUnit() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(0, -1);
        RecipeAavePoolMock(_pool).setBorrowEffects(0, 1);
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        assertEq(IERC20(_receipt).balanceOf(account), 1e8 - 1);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6 + 1);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
    }

    function test_DebtRoundingCannotExceedAbsoluteDebtCap() public {
        RecipeAavePoolMock(_pool).setBorrowEffects(0, 1);
        bytes[] memory runtime = _runtime(2e8, 40_000e6, 40_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(2e8, 40_000e6, runtime);
        _assertPristine();
    }

    function test_ReverseIndexedTokenRoundingAlsoAllowsOneBaseUnit() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(0, 1);
        RecipeAavePoolMock(_pool).setBorrowEffects(0, -1);
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        assertEq(IERC20(_receipt).balanceOf(account), 1e8 + 1);
        assertEq(IERC20(_debt).balanceOf(account), 20_000e6 - 1);
    }

    function test_RevertWhenReceiptExceedsPrincipalBeyondRounding() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(0, 2);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenDebtIsBelowBorrowedBeyondRounding() public {
        RecipeAavePoolMock(_pool).setBorrowEffects(0, -2);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenBorrowedCashDoesNotMatchDebt() public {
        RecipeAavePoolMock(_pool).setBorrowEffects(-1, 0);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenNewOutputIsBelowRateDespiteExistingRwa() public {
        RecipeLendingTokenMock(_rwa).mint(account, 1_000_000e18);
        RecipeIssuerMock(_issuer).setOutputRate(0.989e18);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        assertEq(IERC20(_rwa).balanceOf(account), 1_000_003e18);
        assertEq(IERC20(_debt).balanceOf(account), 0);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
    }

    function test_RevertWhenProofIsInvalidRollsBackEarlierSupply() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        IMerkleAccount.Action[] memory calls =
            abi.decode(runtime[uint256(LendingRecipe.Action.BorrowCall)], (IMerkleAccount.Action[]));
        calls[0].proof[0] ^= bytes32(uint256(1));
        runtime[uint256(LendingRecipe.Action.BorrowCall)] = abi.encode(calls);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenBorrowLeafRoleRevokedRollsBackEarlierSupply() public {
        MerkleAccount(payable(account)).revokeRole(_config.borrowLeaf, _executor);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert();
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenSupplyExceedsCuratorLimit() public {
        bytes[] memory runtime = _runtime(2e8 + 1, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(2e8 + 1, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenRuntimeChangesRecipient() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        IMerkleAccount.Action[] memory calls =
            abi.decode(runtime[uint256(LendingRecipe.Action.PurchaseCall)], (IMerkleAccount.Action[]));
        calls[0].data = abi.encodeCall(RecipeIssuerMock.purchase, (20_000e6, address(0xbad)));
        runtime[uint256(LendingRecipe.Action.PurchaseCall)] = abi.encode(calls);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function _configurePermissions() internal {
        _actions.push(_action(_lbtc, abi.encodeCall(IERC20.approve, (_pool, 0)), 36));
        _actions.push(_action(_pool, abi.encodeCall(RecipeAavePoolMock.supply, (_lbtc, 0, account, 0)), 36));
        _actions.push(_action(account, _borrowData(0), _borrowAmountOffset()));
        _actions.push(_action(_usdc, abi.encodeCall(IERC20.approve, (_issuer, 0)), 36));
        _actions.push(_action(_issuer, abi.encodeCall(RecipeIssuerMock.purchase, (0, account)), 4));
        bytes32[] memory nodes = new bytes32[](15);
        for (uint256 i; i < 5; ++i) {
            nodes[7 + i] = MerkleAdapterVerifier.leaf(_actions[i].target, 0, _actions[i].data, _actions[i].dataMask);
            MerkleAccount(payable(account)).grantRole(nodes[7 + i], _executor);
        }
        for (uint256 i = 7; i > 0;) {
            --i;
            bytes32 left = nodes[i * 2 + 1];
            bytes32 right = nodes[i * 2 + 2];
            nodes[i] =
                left < right ? keccak256(abi.encodePacked(left, right)) : keccak256(abi.encodePacked(right, left));
        }
        for (uint256 i; i < 5; ++i) {
            uint256 cursor = 7 + i;
            while (cursor > 0) {
                _actions[i].proof.push(nodes[cursor % 2 == 1 ? cursor + 1 : cursor - 1]);
                cursor = (cursor - 1) / 2;
            }
        }
        roots.setRoot(account, nodes[0]);
        MerkleAccount(payable(account)).acceptRoot(nodes[0]);
        _config = LendingRecipe.Config({
            account: account,
            lbtc: _lbtc,
            usdc: _usdc,
            rwa: _rwa,
            collateralReceipt: _receipt,
            variableDebt: _debt,
            pool: _pool,
            issuer: _issuer,
            purchaseReceipt: ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
            skipZeroApprovals: false,
            collateralApprovalLeaf: nodes[7],
            supplyLeaf: nodes[8],
            borrowLeaf: nodes[9],
            purchaseApprovalLeaf: nodes[10],
            purchaseLeaf: nodes[11],
            supplyAmountOffsets: new uint256[](1),
            borrowAmountOffsets: new uint256[](1),
            purchaseAmountOffsets: new uint256[](1)
        });
        _config.supplyAmountOffsets[0] = 36;
        _config.borrowAmountOffsets[0] = _borrowAmountOffset();
        _config.purchaseAmountOffsets[0] = 4;
    }

    function _action(address target, bytes memory data, uint256 amountOffset)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < 32; ++i) {
            mask[amountOffset + i] = 0xff;
        }
        return IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _runtime(uint256 supply, uint256 borrowAmount, uint256 purchase)
        internal
        view
        returns (bytes[] memory runtime)
    {
        runtime = new bytes[](uint256(LendingRecipe.Action.Length));
        runtime[uint256(LendingRecipe.Action.ApproveLbtc)] = abi.encode(_actions[0].dataMask, _actions[0].proof);
        runtime[uint256(LendingRecipe.Action.ClearLbtcApproval)] = runtime[uint256(LendingRecipe.Action.ApproveLbtc)];
        runtime[uint256(LendingRecipe.Action.ApproveUsdc)] = abi.encode(_actions[3].dataMask, _actions[3].proof);
        runtime[uint256(LendingRecipe.Action.ClearUsdcApproval)] = runtime[uint256(LendingRecipe.Action.ApproveUsdc)];
        IMerkleAccount.Action[] memory call = new IMerkleAccount.Action[](1);
        call[0] = _actions[1];
        call[0].data = abi.encodeCall(RecipeAavePoolMock.supply, (_lbtc, supply, account, 0));
        runtime[uint256(LendingRecipe.Action.SupplyCall)] = abi.encode(call);
        call[0] = _actions[2];
        call[0].data = _borrowData(borrowAmount);
        runtime[uint256(LendingRecipe.Action.BorrowCall)] = abi.encode(call);
        call[0] = _actions[4];
        call[0].data = abi.encodeCall(RecipeIssuerMock.purchase, (purchase, account));
        runtime[uint256(LendingRecipe.Action.PurchaseCall)] = abi.encode(call);
    }

    function _borrowAmountOffset() internal view returns (uint256) {
        return _changedWord(_borrowData(0), _borrowData(type(uint256).max));
    }

    function _borrowData(uint256 amount) internal view returns (bytes memory) {
        return _checkedCallData(
            _pool,
            _health,
            abi.encodeCall(RecipeAavePoolMock.borrow, (_usdc, amount, 2, 0, account)),
            abi.encodeCall(AaveHealthFactor.getHealthFactor, (_pool, account))
        );
    }

    function _execute(uint256 supply, uint256 borrowAmount, bytes[] memory runtime)
        internal
        returns (uint256[] memory values)
    {
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = supply;
        inputs[1] = borrowAmount;
        return RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
    }

    function _assertPristine() internal view {
        assertEq(IERC20(_lbtc).balanceOf(account), 5e8);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 0);
        assertEq(IERC20(_receipt).balanceOf(account), 0);
        assertEq(IERC20(_debt).balanceOf(account), 0);
        assertEq(IERC20(_usdc).balanceOf(account), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 0);
        assertEq(IERC20(_rwa).balanceOf(account), 3e18);
        assertEq(IERC20(_lbtc).allowance(account, _pool), 0);
        assertEq(IERC20(_usdc).allowance(account, _issuer), 0);
    }
}

/// @dev Unrestricted minting and effect controls are deliberate local test-fixture behavior.
contract RecipeLendingTokenMock is ERC20 {
    error NonzeroApproval();

    uint8 internal immutable _tokenDecimals;
    uint256 public allowanceAtLastPull;

    constructor(string memory symbol, uint8 tokenDecimals) ERC20(symbol, symbol) {
        _tokenDecimals = tokenDecimals;
    }

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public {
        _burn(account, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (amount > 0 && allowance(msg.sender, spender) > 0) revert NonzeroApproval();
        return super.approve(spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        allowanceAtLastPull = allowance(from, msg.sender);
        return super.transferFrom(from, to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }
}

/// @dev Aave-compatible supply/borrow/account-data ABI with explicit collateral, cash and debt effects.
contract RecipeAavePoolMock {
    address public immutable lbtc;
    address public immutable usdc;
    address public immutable receipt;
    address public immutable debt;
    int256 internal _collateralSpentAdjustment;
    int256 internal _receiptAdjustment;
    int256 internal _borrowTransferAdjustment;
    int256 internal _debtAdjustment;
    uint256 internal _supplyUsdcSpent;
    uint256 public liquidationThreshold = 8000;

    constructor(address newLbtc, address newUsdc, address newReceipt, address newDebt) {
        lbtc = newLbtc;
        usdc = newUsdc;
        receipt = newReceipt;
        debt = newDebt;
    }

    function setSupplyEffects(int256 spentAdjustment, int256 receiptAdjustment) public {
        _collateralSpentAdjustment = spentAdjustment;
        _receiptAdjustment = receiptAdjustment;
    }

    function setBorrowEffects(int256 transferAdjustment, int256 debtAdjustment) public {
        _borrowTransferAdjustment = transferAdjustment;
        _debtAdjustment = debtAdjustment;
    }

    function setSupplyUsdcSpent(uint256 amount) public {
        _supplyUsdcSpent = amount;
    }

    function setLiquidationThreshold(uint256 newLiquidationThreshold) public {
        liquidationThreshold = newLiquidationThreshold;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) public {
        require(asset == lbtc && referralCode == 0 && onBehalfOf == msg.sender);
        IERC20(lbtc).transferFrom(msg.sender, address(this), _adjust(amount, _collateralSpentAdjustment));
        RecipeLendingTokenMock(receipt).mint(onBehalfOf, _adjust(amount, _receiptAdjustment));
        RecipeLendingTokenMock(usdc).burn(onBehalfOf, _supplyUsdcSpent);
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        public
    {
        require(asset == usdc && interestRateMode == 2 && referralCode == 0 && onBehalfOf == msg.sender);
        RecipeLendingTokenMock(debt).mint(onBehalfOf, _adjust(amount, _debtAdjustment));
        IERC20(usdc).transfer(msg.sender, _adjust(amount, _borrowTransferAdjustment));
    }

    function getUserAccountData(address account)
        public
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        uint256 collateralValue = IERC20(receipt).balanceOf(account) * 60_000e6 / 1e8;
        uint256 borrowed = IERC20(debt).balanceOf(account);
        uint256 health = borrowed == 0 ? type(uint256).max : collateralValue * liquidationThreshold * 1e14 / borrowed;
        return (collateralValue, borrowed, 0, liquidationThreshold, 7500, health);
    }

    function _adjust(uint256 amount, int256 adjustment) internal pure returns (uint256) {
        return adjustment < 0 ? amount - uint256(-adjustment) : amount + uint256(adjustment);
    }
}

/// @dev Issuer fixture with immediate delivery or separate subscription, settlement and claim phases.
contract RecipeIssuerMock {
    address public immutable usdc;
    address public immutable rwa;
    uint256 public outputRate = 1e18;
    bool public asynchronous;
    mapping(address => uint256) public pendingShares;
    mapping(address => uint256) public claimableShares;

    constructor(address newUsdc, address newRwa) {
        usdc = newUsdc;
        rwa = newRwa;
    }

    function setOutputRate(uint256 newOutputRate) public {
        outputRate = newOutputRate;
    }

    function setAsynchronous(bool value) public {
        asynchronous = value;
    }

    function settle(address account, uint256 amount) public {
        pendingShares[account] -= amount;
        claimableShares[account] += amount;
    }

    function claim(uint256 amount, address recipient) public {
        claimableShares[msg.sender] -= amount;
        RecipeLendingTokenMock(rwa).mint(recipient, amount);
    }

    function purchase(uint256 amount, address recipient) public returns (uint256 output) {
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        output = amount * outputRate / 1e6;
        if (asynchronous) pendingShares[recipient] += output;
        else RecipeLendingTokenMock(rwa).mint(recipient, output);
    }
}

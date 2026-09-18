// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/capabilities/borrow-capability/AaveHealthFactor.sol";
import {BorrowCapability} from "src/contracts/merkle-adapter/capabilities/BorrowCapability.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {RecipeExecutor} from "src/contracts/periphery/RecipeExecutor.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IBorrowCapability} from "src/interfaces/merkle-adapter/capabilities/IBorrowCapability.sol";
import {IExecutor} from "src/interfaces/periphery/IExecutor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingRecipe} from "script/recipes/LendingRecipe.sol";

/// @dev Local protocol-effects fixture; this suite does not claim a live Aave or issuer execution.
contract RecipeLendingTest is CapabilityTestBase {
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
    IMerkleAdapter.Action[] internal _actions;

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
        _installCapability(adapter, address(new BorrowCapability()), _borrowSelectors());
        _setHealthFactor(
            keccak256(abi.encode(_health, abi.encodeCall(AaveHealthFactor.getHealthFactor, (_pool, address(adapter))))),
            1.2e18
        );
        _executor =
            new ImmutableFactory(type(RecipeExecutor).creationCode).create(abi.encode(address(this), address(adapter)));
        RecipeExecutor(_executor).setCaller(address(this));
        _configurePermissions();
        RecipeExecutor(_executor).setRecipe(LendingRecipe.build(_config, LendingRecipe.Limits(2e8, 40_000e6, 0.99e18)));

        RecipeLendingTokenMock(_lbtc).mint(address(adapter), 5e8);
        RecipeLendingTokenMock(_usdc).mint(address(adapter), 17e6);
        RecipeLendingTokenMock(_rwa).mint(address(adapter), 3e18);
        RecipeLendingTokenMock(_usdc).mint(_pool, 1_000_000e6);
    }

    function test_RecipeSuppliesBorrowsAndPurchasesThroughRealAdapterAndCapability() public {
        vm.prank(address(adapter));
        IERC20(_lbtc).approve(_pool, 7);
        vm.prank(address(adapter));
        IERC20(_usdc).approve(_issuer, 9);

        uint256[] memory values = _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));

        assertEq(IERC20(_lbtc).balanceOf(address(adapter)), 4e8);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 1e8);
        assertEq(IERC20(_receipt).balanceOf(address(adapter)), 1e8);
        assertEq(IERC20(_debt).balanceOf(address(adapter)), 20_000e6);
        assertEq(IERC20(_usdc).balanceOf(address(adapter)), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 20_000e6);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 20_003e18);
        assertEq(values[uint256(LendingRecipe.Register.BorrowedUsdc)], 20_000e6);
        assertEq(values[uint256(LendingRecipe.Register.MinimumRwa)], 19_800e18);
        assertEq(RecipeLendingTokenMock(_lbtc).allowanceAtLastPull(), 1e8);
        assertEq(RecipeLendingTokenMock(_usdc).allowanceAtLastPull(), 20_000e6);
        assertEq(IERC20(_lbtc).allowance(address(adapter), _pool), 0);
        assertEq(IERC20(_usdc).allowance(address(adapter), _issuer), 0);
        assertEq(IERC20(_usdc).balanceOf(_executor), 0);
        assertEq(AaveHealthFactor(_health).getHealthFactor(_pool, address(adapter)), 2.4e18);
    }

    function testFuzz_AmountsPreserveExistingFundsAndPriceFloor(uint256 supply, uint256 borrowAmount) public {
        supply = bound(supply, 1e8, 2e8);
        borrowAmount = bound(borrowAmount, 1e6, 20_000e6);
        RecipeIssuerMock(_issuer).setOutputRate(0.99e18);

        uint256[] memory values = _execute(supply, borrowAmount, _runtime(supply, borrowAmount, borrowAmount));

        assertEq(IERC20(_lbtc).balanceOf(address(adapter)), 5e8 - supply);
        assertEq(IERC20(_receipt).balanceOf(address(adapter)), supply);
        assertEq(IERC20(_debt).balanceOf(address(adapter)), borrowAmount);
        assertEq(IERC20(_usdc).balanceOf(address(adapter)), 17e6);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 3e18 + borrowAmount * 0.99e18 / 1e6);
        assertEq(
            values[uint256(LendingRecipe.Register.RwaReceived)], values[uint256(LendingRecipe.Register.MinimumRwa)]
        );
    }

    function test_RepeatedExecutionStopsAtTotalDebtCap() public {
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        bytes[] memory runtime = _runtime(1e8, 1e6, 1e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 1e6, runtime);
        assertEq(IERC20(_debt).balanceOf(address(adapter)), 40_000e6);
        assertEq(IERC20(_lbtc).balanceOf(address(adapter)), 3e8);
        assertEq(IERC20(_usdc).balanceOf(address(adapter)), 17e6);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 40_003e18);
    }

    function test_BorrowCapabilityHealthFailureRollsBackSupply() public {
        bytes[] memory runtime = _runtime(1e8, 40_000e6, 40_000e6);
        RecipeAavePoolMock(_pool).setLiquidationThreshold(7000);
        vm.expectRevert(IBorrowCapability.HealthFactorTooLow.selector);
        _execute(1e8, 40_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenRuntimeSupplyAmountDiffers() public {
        bytes[] memory runtime = _runtime(1e8 - 1, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenRuntimeBorrowAmountDiffers() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6 + 1, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenRuntimePurchaseSpendsLessThanBorrowed() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6 - 1);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenRuntimePurchaseTriesToSpendExistingUsdc() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_001e6);
        vm.expectRevert();
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenPoolSpendsLessCollateral() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(-1, 0);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function testFuzz_RevertWhenReceiptDiffersByMoreThanRounding(uint256 shortfall) public {
        shortfall = bound(shortfall, 2, 1e8);
        RecipeAavePoolMock(_pool).setSupplyEffects(0, -int256(shortfall));
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function testFuzz_RevertWhenDebtExceedsBorrowedBeyondRounding(uint256 additionalDebt) public {
        additionalDebt = bound(additionalDebt, 2, 10_000e6);
        RecipeAavePoolMock(_pool).setBorrowEffects(0, int256(additionalDebt));
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_IndexedTokenRoundingAllowsOnlyOneBaseUnit() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(0, -1);
        RecipeAavePoolMock(_pool).setBorrowEffects(0, 1);
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        assertEq(IERC20(_receipt).balanceOf(address(adapter)), 1e8 - 1);
        assertEq(IERC20(_debt).balanceOf(address(adapter)), 20_000e6 + 1);
        assertEq(IERC20(_usdc).balanceOf(address(adapter)), 17e6);
    }

    function test_DebtRoundingCannotExceedAbsoluteDebtCap() public {
        RecipeAavePoolMock(_pool).setBorrowEffects(0, 1);
        bytes[] memory runtime = _runtime(2e8, 40_000e6, 40_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(2e8, 40_000e6, runtime);
        _assertPristine();
    }

    function test_ReverseIndexedTokenRoundingAlsoAllowsOneBaseUnit() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(0, 1);
        RecipeAavePoolMock(_pool).setBorrowEffects(0, -1);
        _execute(1e8, 20_000e6, _runtime(1e8, 20_000e6, 20_000e6));
        assertEq(IERC20(_receipt).balanceOf(address(adapter)), 1e8 + 1);
        assertEq(IERC20(_debt).balanceOf(address(adapter)), 20_000e6 - 1);
    }

    function test_RevertWhenReceiptExceedsPrincipalBeyondRounding() public {
        RecipeAavePoolMock(_pool).setSupplyEffects(0, 2);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenDebtIsBelowBorrowedBeyondRounding() public {
        RecipeAavePoolMock(_pool).setBorrowEffects(0, -2);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenBorrowedCashDoesNotMatchDebt() public {
        RecipeAavePoolMock(_pool).setBorrowEffects(-1, 0);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenNewOutputIsBelowRateDespiteExistingRwa() public {
        RecipeLendingTokenMock(_rwa).mint(address(adapter), 1_000_000e18);
        RecipeIssuerMock(_issuer).setOutputRate(0.989e18);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(1e8, 20_000e6, runtime);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 1_000_003e18);
        assertEq(IERC20(_debt).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_usdc).balanceOf(address(adapter)), 17e6);
    }

    function test_RevertWhenProofIsInvalidRollsBackEarlierSupply() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        IMerkleAdapter.Action[] memory calls =
            abi.decode(runtime[uint256(LendingRecipe.Register.BorrowCall)], (IMerkleAdapter.Action[]));
        calls[0].proof[0] ^= bytes32(uint256(1));
        runtime[uint256(LendingRecipe.Register.BorrowCall)] = abi.encode(calls);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenBorrowLeafRoleRevokedRollsBackEarlierSupply() public {
        adapter.revokeRole(_config.borrowLeaf, _executor);
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        vm.expectRevert();
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenSupplyExceedsCuratorLimit() public {
        bytes[] memory runtime = _runtime(2e8 + 1, 20_000e6, 20_000e6);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(2e8 + 1, 20_000e6, runtime);
        _assertPristine();
    }

    function test_RevertWhenRuntimeChangesRecipient() public {
        bytes[] memory runtime = _runtime(1e8, 20_000e6, 20_000e6);
        IMerkleAdapter.Action[] memory calls =
            abi.decode(runtime[uint256(LendingRecipe.Register.PurchaseCall)], (IMerkleAdapter.Action[]));
        calls[0].data = abi.encodeCall(RecipeIssuerMock.purchase, (20_000e6, address(0xbad)));
        runtime[uint256(LendingRecipe.Register.PurchaseCall)] = abi.encode(calls);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(1e8, 20_000e6, runtime);
        _assertPristine();
    }

    function _configurePermissions() internal {
        _actions.push(_action(_lbtc, abi.encodeCall(IERC20.approve, (_pool, 0)), 36));
        _actions.push(_action(_pool, abi.encodeCall(RecipeAavePoolMock.supply, (_lbtc, 0, address(adapter), 0)), 36));
        _actions.push(_action(address(adapter), _borrowData(0), 200));
        _actions.push(_action(_usdc, abi.encodeCall(IERC20.approve, (_issuer, 0)), 36));
        _actions.push(_action(_issuer, abi.encodeCall(RecipeIssuerMock.purchase, (0, address(adapter))), 4));
        bytes32[] memory nodes = new bytes32[](15);
        for (uint256 i; i < 5; ++i) {
            nodes[7 + i] = MerkleAdapterVerifier.leaf(_actions[i].target, 0, _actions[i].data, _actions[i].dataMask);
            adapter.grantRole(nodes[7 + i], _executor);
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
        roots.setRoot(address(adapter), nodes[0]);
        adapter.acceptRoot(nodes[0]);
        _config = LendingRecipe.Config(
            address(adapter),
            _lbtc,
            _usdc,
            _rwa,
            _receipt,
            _debt,
            _pool,
            _issuer,
            nodes[7],
            nodes[8],
            nodes[9],
            nodes[10],
            nodes[11]
        );
    }

    function _action(address target, bytes memory data, uint256 amountOffset)
        internal
        pure
        returns (IMerkleAdapter.Action memory action)
    {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < 32; ++i) {
            mask[amountOffset + i] = 0xff;
        }
        return IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }

    function _runtime(uint256 supply, uint256 borrowAmount, uint256 purchase)
        internal
        view
        returns (bytes[] memory runtime)
    {
        runtime = new bytes[](uint256(LendingRecipe.Register.Length));
        runtime[uint256(LendingRecipe.Register.ApproveLbtc)] =
            abi.encode(IExecutor.Permission(_actions[0].dataMask, _actions[0].proof));
        runtime[uint256(LendingRecipe.Register.ClearLbtcApproval)] =
            runtime[uint256(LendingRecipe.Register.ApproveLbtc)];
        runtime[uint256(LendingRecipe.Register.ApproveUsdc)] =
            abi.encode(IExecutor.Permission(_actions[3].dataMask, _actions[3].proof));
        runtime[uint256(LendingRecipe.Register.ClearUsdcApproval)] =
            runtime[uint256(LendingRecipe.Register.ApproveUsdc)];
        IMerkleAdapter.Action[] memory call = new IMerkleAdapter.Action[](1);
        call[0] = _actions[1];
        call[0].data = abi.encodeCall(RecipeAavePoolMock.supply, (_lbtc, supply, address(adapter), 0));
        runtime[uint256(LendingRecipe.Register.SupplyCall)] = abi.encode(call);
        call[0] = _actions[2];
        call[0].data = _borrowData(borrowAmount);
        runtime[uint256(LendingRecipe.Register.BorrowCall)] = abi.encode(call);
        call[0] = _actions[4];
        call[0].data = abi.encodeCall(RecipeIssuerMock.purchase, (purchase, address(adapter)));
        runtime[uint256(LendingRecipe.Register.PurchaseCall)] = abi.encode(call);
    }

    function _borrowData(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(
            IBorrowCapability.borrow,
            (
                _pool,
                _health,
                abi.encodeCall(RecipeAavePoolMock.borrow, (_usdc, amount, 2, 0, address(adapter))),
                abi.encodeCall(AaveHealthFactor.getHealthFactor, (_pool, address(adapter)))
            )
        );
    }

    function _execute(uint256 supply, uint256 borrowAmount, bytes[] memory runtime)
        internal
        returns (uint256[] memory values)
    {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = supply;
        inputs[1] = borrowAmount;
        return RecipeExecutor(_executor)
            .execute(LendingRecipe.build(_config, LendingRecipe.Limits(2e8, 40_000e6, 0.99e18)), inputs, runtime);
    }

    function _assertPristine() internal view {
        assertEq(IERC20(_lbtc).balanceOf(address(adapter)), 5e8);
        assertEq(IERC20(_lbtc).balanceOf(_pool), 0);
        assertEq(IERC20(_receipt).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_debt).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_usdc).balanceOf(address(adapter)), 17e6);
        assertEq(IERC20(_usdc).balanceOf(_issuer), 0);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 3e18);
        assertEq(IERC20(_lbtc).allowance(address(adapter), _pool), 0);
        assertEq(IERC20(_usdc).allowance(address(adapter), _issuer), 0);
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

    function setLiquidationThreshold(uint256 newLiquidationThreshold) public {
        liquidationThreshold = newLiquidationThreshold;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) public {
        require(asset == lbtc && referralCode == 0 && onBehalfOf == msg.sender);
        IERC20(lbtc).transferFrom(msg.sender, address(this), _adjust(amount, _collateralSpentAdjustment));
        RecipeLendingTokenMock(receipt).mint(onBehalfOf, _adjust(amount, _receiptAdjustment));
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

/// @dev Immediate issuer fixture; no claim is made about asynchronous 3F/Midas issuer ABI support.
contract RecipeIssuerMock {
    address public immutable usdc;
    address public immutable rwa;
    uint256 public outputRate = 1e18;

    constructor(address newUsdc, address newRwa) {
        usdc = newUsdc;
        rwa = newRwa;
    }

    function setOutputRate(uint256 newOutputRate) public {
        outputRate = newOutputRate;
    }

    function purchase(uint256 amount, address recipient) public returns (uint256 output) {
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        output = amount * outputRate / 1e6;
        RecipeLendingTokenMock(rwa).mint(recipient, output);
    }
}

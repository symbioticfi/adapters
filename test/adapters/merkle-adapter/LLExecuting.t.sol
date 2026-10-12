// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ActionOracleMock} from "./LiquidLaneConnector.t.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapterDelegatorMock, MerkleAdapterVaultMock} from "../MerkleAdapter.t.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/connectors/OracleRegistry.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RecipeIssuerReceipt} from "./mocks/RecipeMocks.sol";
import {RecipeLiquiditySource} from "./mocks/RecipeMocks.sol";
import {RecipeRwaToken} from "./mocks/RecipeMocks.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneConnector
} from "src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_APPROVE,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_MUL_DIV,
    OP_READ,
    OP_SUB,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LLExecuting} from "script/recipes/LLExecuting.sol";

import {Token} from "test/mocks/Token.sol";

contract LLExecutingTest is CapabilityTestBase {
    bytes internal _recipe;
    bool internal _skipUnusedReads;
    bool internal _skipZeroApprovals;
    bool internal _retainsRwa;
    uint256 internal _receiptDenominator = 1;

    struct Plan {
        uint256 amountIn;
        uint256 amountOut;
        uint256 firstAmount;
        uint256 secondAmount;
        uint256 redeemAmount;
        uint256 receiptAmount;
        uint256 minReceiptNumerator;
        uint256 preparedFirstLiquidity;
        bool skipLastCapacity;
        bool redeem;
    }

    address internal _asset;
    address internal _rwa;
    address internal _executor;
    address internal _lane;
    address internal _issuer;
    address internal _first;
    address internal _second;
    address internal _delegator;
    address internal _provider = makeAddr("provider");
    address internal _recipient = makeAddr("recipient");
    bytes32 internal _ownerDigest;
    LLExecuting.Layout internal _layout;

    function setUp() public {
        _asset = address(new Token("Funding"));
        _rwa = address(new RecipeRwaToken());
        _deployAdapter(_asset);
        _delegator = address(new MerkleAdapterDelegatorMock(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(_delegator);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(_provider);
        address registry = address(new OracleRegistry(address(this)));
        address prices = address(new MigratablesFactory(address(this)));
        MigratablesFactory(prices).whitelist(address(new ActionOracleMock(prices, 1e18)));
        address lanes = address(new MigratablesFactory(address(this)));
        MigratablesFactory(lanes)
            .whitelist(address(new LiquidLaneConnector(lanes, adapter.ACCOUNT_FACTORY(), registry)));
        _lane = MigratablesFactory(lanes).create(1, address(this), abi.encode(account, _asset));
        OracleRegistry(registry)
            .setOracle(_lane, _rwa, MigratablesFactory(prices).create(1, address(this), abi.encode(_asset, _lane)));
        _manage(
            _lane,
            abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (_rwa, OracleRegistry(registry).oracles(_lane, _rwa)))
        );
        _manage(_lane, abi.encodeCall(ILiquidLaneConnector.setMaxAssetsPerDuration, (_rwa, type(uint256).max, 1 days)));
        IERC20(_rwa).transfer(_lane, 1_000_000);
        _issuer = address(new RecipeIssuerReceipt(_rwa));
        _first = address(new RecipeLiquiditySource(IERC20(_asset), account));
        _second = address(new RecipeLiquiditySource(IERC20(_asset), account));
        IERC20(_asset).transfer(_first, 1_000_000);
        IERC20(_asset).transfer(_second, 1_000_000);
        RecipeLiquiditySource(_first).setLiquidity(30);
        RecipeLiquiditySource(_second).setLiquidity(1_000_000);
        LiquidLaneConnector(_lane).setSigner(vm.addr(0xAAA));
        LiquidLaneConnector(_lane).setMinDiscount(_rwa, 10_000_000);
    }

    function test_ConnectorRejectsAccountFromAnotherMerkleFactory() public {
        LiquidLaneConnector connector = LiquidLaneConnector(_lane);
        MigratablesFactory lanes = MigratablesFactory(connector.FACTORY());
        address acceptedFactory = connector.MERKLE_ACCOUNT_FACTORY();
        uint256 entities = lanes.totalEntities();
        assertTrue(MigratablesFactory(acceptedFactory).isEntity(account));

        _deployAdapter(_asset);
        assertNotEq(adapter.ACCOUNT_FACTORY(), acceptedFactory);
        assertTrue(MigratablesFactory(adapter.ACCOUNT_FACTORY()).isEntity(account));
        assertFalse(MigratablesFactory(acceptedFactory).isEntity(account));
        vm.expectRevert(ILiquidLaneConnector.InvalidAccount.selector);
        lanes.create(1, address(this), abi.encode(account, _asset));
        assertEq(lanes.totalEntities(), entities);
    }

    function test_FundsDiscountedSwapAndRedeemsInTwoCallsWithoutTypedExecutor() public {
        uint256[] memory values = _run(_plan(), _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(values[_layout.sourceAmounts[1]], 60);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_rwa).balanceOf(account), 0);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 100);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
    }

    function test_SwapAmountAndSourceAmountsAreInsertedBeforeExecution() public {
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = type(uint256).max;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        bytes memory data = actions[0].data;
        assembly ("memory-safe") { mstore(add(data, 132), 777) }
        runtime[_layout.operation] = abi.encode(actions);
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
    }

    function test_PreservesOldRwaAndUsesIdleFundingFirst() public {
        IERC20(_rwa).transfer(account, 50);
        IERC20(_asset).transfer(account, 20);
        Plan memory plan = _plan();
        plan.secondAmount = 40;
        _run(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(IERC20(_rwa).balanceOf(account), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 40);
    }

    function test_EmptyPostActionListRetainsAcquiredRwa() public {
        Plan memory plan = _plan();
        plan.redeem = false;
        _run(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(IERC20(_rwa).balanceOf(account), 100);
        assertEq(IERC20(_issuer).balanceOf(account), 0);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
    }

    function test_FullDiscountNeedsNoFundingAndStillReceivesAndRedeemsRwa() public {
        Plan memory plan = _plan();
        plan.amountOut = 0;
        plan.firstAmount = 0;
        plan.secondAmount = 0;
        _run(plan, _swapData(100_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
    }

    function test_RwaAmountCapFailsBeforeFunding() public {
        Plan memory plan = _plan();
        plan.amountIn = 1001;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_FundingCapFailsBeforeFunding() public {
        Plan memory plan = _plan();
        plan.amountOut = 1001;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ERC1271OwnerCanSignAlongsideDelegatedSigner() public {
        _run(_plan(), _swapData(10_000_000, type(uint48).max, type(uint48).max, true));
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
    }

    function test_ReusableDiscountCanFillAgainUntilInvalidated() public {
        bytes memory swapData = _swapData(10_000_000, type(uint48).max, type(uint48).max, false);
        _run(_plan(), swapData);
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = 90;
        _run(plan, swapData);
        assertEq(IERC20(_asset).balanceOf(_recipient), 180);
        assertEq(IERC20(_issuer).balanceOf(account), 200);
        assertFalse(ILiquidLaneConnector(_lane).isUsedNonce(_rwa, 7));
    }

    function test_RefreshesSignedQuoteWithoutChangingStoredRecipeRootOrProofs() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        bytes32 curRoot = MerkleAccount(payable(account)).root();
        _execute(plan, runtime);

        (ILiquidLaneConnector.DiscountSwap memory quote,) =
            _quote(20_000_000, uint48(block.timestamp + 1 days), uint48(block.timestamp + 10 minutes), false);
        quote.discount.nonce = 8;
        quote.signerSignature = _sign(
            0xAAA,
            keccak256(abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount))))
        );
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        bytes32 leaf = _leaf(actions[0]);
        actions[0].data = _encodeSwap(quote, _protocolSignature(quote));
        assertEq(_leaf(actions[0]), leaf);
        runtime[_layout.operation] = abi.encode(actions);
        actions = abi.decode(runtime[_layout.sourceCalls[1]], (IMerkleAccount.Action[]));
        actions[0].data = abi.encodeCall(RecipeLiquiditySource.withdraw, (account, 80));
        runtime[_layout.sourceCalls[1]] = abi.encode(actions);
        plan.amountOut = 80;

        _execute(plan, runtime);
        assertEq(MerkleAccount(payable(account)).root(), curRoot);
        assertEq(IERC20(_asset).balanceOf(_recipient), 170);
        assertEq(IERC20(_issuer).balanceOf(account), 200);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 140);
    }

    function testFuzz_ReusableSignedLeafPinsPolicyAndDynamicStructure(uint8 field) public {
        field = uint8(bound(field, 0, 8));
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        uint256 tuple = 4 + _word(actions[0].data, 4);
        uint256 signerSignature = tuple + _word(actions[0].data, tuple + 192);
        uint256 protocolSignature = 4 + _word(actions[0].data, 36);
        // Recipient, tuple/protocol offsets, RWA, nested offset, signature lengths and signers.
        uint256[9] memory offsets = [
            uint256(99),
            35,
            67,
            tuple + 31,
            tuple + 223,
            signerSignature + 31,
            protocolSignature + 31,
            tuple + 95,
            tuple + 127
        ];
        actions[0].data[offsets[field]] ^= 0x01;
        runtime[_layout.operation] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_MaskedRecipientStillRequiresConfiguredPayoutAndRollsBack() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), true);
        bytes memory validSwap = runtime[_layout.operation];
        IMerkleAccount.Action[] memory actions = abi.decode(validSwap, (IMerkleAccount.Action[]));
        bytes32 leaf = _leaf(actions[0]);
        address alternate = makeAddr("alternate recipient");
        bytes memory data = actions[0].data;
        // Recipient is the third argument, at calldata offset 68.
        assembly ("memory-safe") { mstore(add(data, 100), alternate) }
        assertEq(_leaf(actions[0]), leaf);
        runtime[_layout.operation] = abi.encode(actions);

        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
        assertEq(IERC20(_asset).balanceOf(alternate), 0);
        assertEq(ILiquidLaneConnector(_lane).remainingAssets(_rwa), type(uint256).max);
        assertFalse(ILiquidLaneConnector(_lane).isUsedNonce(_rwa, 7));

        runtime[_layout.operation] = validSwap;
        _execute(plan, runtime);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
        assertEq(ILiquidLaneConnector(_lane).remainingAssets(_rwa), type(uint256).max - 90);
        assertFalse(ILiquidLaneConnector(_lane).isUsedNonce(_rwa, 7));
    }

    function test_SwapRequiresAdapterEvenFromOwner() public {
        (ILiquidLaneConnector.DiscountSwap memory quote, bytes memory signature) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        ILiquidLaneConnector(_lane).swap(quote, signature, _recipient, 100);
    }

    function test_ValidSignatureFromUnapprovedSignerCannotExecute() public {
        (ILiquidLaneConnector.DiscountSwap memory quote,) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        quote.discount.signer = vm.addr(0xCCC);
        quote.signerSignature = _sign(
            0xCCC,
            keccak256(abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount))))
        );
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _encodeSwap(quote, _protocolSignature(quote)));
        vm.expectRevert(ILiquidLaneConnector.InvalidSigner.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_InvalidatedDiscountCannotRunAndFundingRollsBack() public {
        LiquidLaneConnector(_lane).invalidateNonce(_rwa, 7);
        assertTrue(ILiquidLaneConnector(_lane).isUsedNonce(_rwa, 7));
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(bytes4(keccak256("AlreadyUsedNonce()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ExpiredDiscountRollsBackFundingAndApproval() public {
        Plan memory plan = _plan();
        bytes[] memory runtime =
            _prepare(plan, _swapData(10_000_000, uint48(block.timestamp - 1), type(uint48).max, false));
        vm.expectRevert(bytes4(keccak256("ExpiredSwap()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ExpiredProtocolAuthorizationRollsBackFunding() public {
        Plan memory plan = _plan();
        bytes[] memory runtime =
            _prepare(plan, _swapData(10_000_000, type(uint48).max, uint48(block.timestamp - 1), false));
        vm.expectRevert(bytes4(keccak256("ExpiredSwap()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_DiscountBelowPinnedMinimumCannotExecute() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(9_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(bytes4(keccak256("InvalidSwapRate()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_InvalidProtocolSignatureCannotExecute() public {
        (ILiquidLaneConnector.DiscountSwap memory quote, bytes memory protocolSignature) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        protocolSignature[0] ^= 0x01;
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _encodeSwap(quote, protocolSignature));
        vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_InvalidSignerSignatureCannotExecute() public {
        (ILiquidLaneConnector.DiscountSwap memory quote,) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        quote.signerSignature[0] ^= 0x01;
        bytes memory protocolSignature = _protocolSignature(quote);
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _encodeSwap(quote, protocolSignature));
        vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ValidSignaturesFromWrongDomainCannotExecute() public {
        (ILiquidLaneConnector.DiscountSwap memory quote,) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        quote.signerSignature = _sign(
            0xAAA,
            keccak256(abi.encodePacked(hex"1901", bytes32(0), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount))))
        );
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _encodeSwap(quote, _protocolSignature(quote)));
        vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_OverstatedCashInputDoesNotLeaveUnspentFunds() public {
        Plan memory plan = _plan();
        plan.amountOut = 91;
        plan.secondAmount = 61;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_InputSetsSwapSizeDespiteDifferentTemplateAmount() public {
        Plan memory plan = _plan();
        plan.amountIn = 101;
        plan.redeemAmount = 101;
        plan.receiptAmount = 101;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        assertEq(IERC20(_issuer).balanceOf(account), 101);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 101);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
    }

    function test_ReservesAreNotUsedToPayRecipient() public {
        IERC20(_asset).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        _run(_plan(), _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(adapter.pendingDeallocation(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
    }

    function test_FundingRequiresReadableUnusedCapacity() public {
        _skipUnusedReads = true;
        _skipZeroApprovals = true;
        RecipeLiquiditySource(_first).setLiquidity(90);
        Plan memory plan = _plan();
        plan.firstAmount = 90;
        plan.secondAmount = 0;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.mockCallRevert(_second, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), hex"deadbeef");
        runtime[_layout.sourceCalls[1]] = hex"deadbeef";
        vm.expectRevert(bytes4(0xdeadbeef));
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
        assertEq(IERC20(_issuer).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
    }

    function test_FundingPreparationAndQueriesRunWhenAlreadyFunded() public {
        _skipUnusedReads = true;
        IERC20(_asset).transfer(account, 90);
        Plan memory plan = _plan();
        plan.preparedFirstLiquidity = 50;
        plan.firstAmount = 0;
        plan.secondAmount = 0;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.mockCallRevert(_first, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), hex"deadbeef");
        vm.mockCallRevert(_second, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), hex"deadbeef");
        vm.expectRevert(bytes4(0xdeadbeef));
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).liquidity(), 30);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
    }

    function test_OptimizedFundingPreservesUsedCapacityFailure() public {
        _skipUnusedReads = true;
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.mockCallRevert(_second, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), hex"deadbeef");
        vm.expectRevert(bytes4(0xdeadbeef));
        _execute(plan, runtime);
        _assertRollback();
    }

    function testFuzz_OptimizedFundingPreservesExactWithdrawalDelta(bool excess) public {
        _skipUnusedReads = true;
        RecipeLiquiditySource(_second).setAdjustment(excess ? int256(1) : -int256(1));
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    /// forge-config: default.isolate = true
    function test_GasOptimizedAlreadyFundedRecipe() public {
        IERC20(_asset).transfer(account, 90);
        uint256 state = vm.snapshotState();
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = 0;
        bytes memory swapData = _swapData(10_000_000, type(uint48).max, type(uint48).max, false);
        bytes[] memory runtime = _prepare(plan, swapData);
        _execute(plan, runtime);
        uint256 originalGas = vm.snapshotGasLastCall("LLExecuting", "alreadyFundedUnconditional");
        assertTrue(vm.revertToState(state));
        _skipUnusedReads = true;
        _skipZeroApprovals = true;
        runtime = _prepare(plan, swapData);
        _execute(plan, runtime);
        uint256 optimizedGas = vm.snapshotGasLastCall("LLExecuting", "alreadyFundedConditional");
        assertEq(IERC20(_issuer).balanceOf(account), 100);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        emit log_named_uint("already-funded legacy flags gas", optimizedGas);
    }

    /// forge-config: default.isolate = true
    function test_GasOptimizedTwoActiveSources() public {
        uint256 state = vm.snapshotState();
        Plan memory plan = _plan();
        bytes memory swapData = _swapData(10_000_000, type(uint48).max, type(uint48).max, false);
        bytes[] memory runtime = _prepare(plan, swapData);
        _execute(plan, runtime);
        uint256 originalGas = vm.snapshotGasLastCall("LLExecuting", "twoActiveSourcesUnconditional");
        assertTrue(vm.revertToState(state));
        _skipUnusedReads = true;
        _skipZeroApprovals = true;
        runtime = _prepare(plan, swapData);
        _execute(plan, runtime);
        uint256 optimizedGas = vm.snapshotGasLastCall("LLExecuting", "twoActiveSourcesConditional");
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
        emit log_named_uint("two-active-sources legacy flags gas", optimizedGas);
    }

    function test_ZeroCapacitySourceIsSkipped() public {
        RecipeLiquiditySource(_first).setLiquidity(0);
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = 90;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        runtime[_layout.sourceCalls[0]] = "";
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 90);
    }

    function test_LastSourceWithoutCapacityWithdrawsFullRemainingShortfall() public {
        IERC20(_asset).transfer(account, 20);
        Plan memory plan = _plan();
        plan.skipLastCapacity = true;
        plan.secondAmount = 40;
        uint256[] memory values = _run(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(values[_layout.sourceAmounts[1]], 40);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 40);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
    }

    function test_LastSourceInsufficiencyRollsBackEarlierFunding() public {
        RecipeLiquiditySource(_first).setLiquidity(0);
        RecipeLiquiditySource(_second).setLiquidity(59);
        Plan memory plan = _plan();
        plan.preparedFirstLiquidity = 30;
        plan.skipLastCapacity = true;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert();
        _execute(plan, runtime);
        _assertRollback();
        assertEq(RecipeLiquiditySource(_first).liquidity(), 0);
        assertEq(RecipeLiquiditySource(_second).liquidity(), 59);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
    }

    function testFuzz_LastSourceWithoutCapacityStillRequiresExactBalanceIncrease(bool excess) public {
        RecipeLiquiditySource(_second).setAdjustment(excess ? int256(1) : -int256(1));
        Plan memory plan = _plan();
        plan.skipLastCapacity = true;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_LastSourceWithoutCapacitySkipsMalformedRuntimeWhenFullyFunded() public {
        IERC20(_asset).transfer(account, 90);
        Plan memory plan = _plan();
        plan.skipLastCapacity = true;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        runtime[_layout.sourceCalls[0]] = "";
        runtime[_layout.sourceCalls[1]] = "";
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
    }

    function test_SourcePreparationRunsBeforeCapacityRead() public {
        RecipeLiquiditySource(_first).setLiquidity(0);
        Plan memory plan = _plan();
        plan.preparedFirstLiquidity = 30;
        uint256[] memory values = _run(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
    }

    function test_SourcePreparationRunsWhenFullyFunded() public {
        RecipeLiquiditySource(_first).setLiquidity(0);
        IERC20(_asset).transfer(account, 90);
        Plan memory plan = _plan();
        plan.preparedFirstLiquidity = 37;
        plan.skipLastCapacity = true;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        runtime[_layout.sourceCalls[0]] = "";
        runtime[_layout.sourceCalls[1]] = "";
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).liquidity(), 37);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
    }

    function test_MissingRedemptionActionRollsBackSwapAndSources() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        runtime[_layout.redeem] = abi.encode(new IMerkleAccount.Action[](0));
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_CooldownRequestRetainsNewRwaAndCreatesFreshReceipt() public {
        _retainsRwa = true;
        RecipeIssuerReceipt(_issuer).setRetainsRwa(true);
        IERC20(_rwa).transfer(account, 7);
        vm.prank(account);
        RecipeIssuerReceipt(_issuer).redeem(0, 13);
        _run(_plan(), _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(IERC20(_rwa).balanceOf(account), 107);
        assertEq(IERC20(_issuer).balanceOf(account), 113);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
    }

    function test_RetainedCooldownMustMeetFreshReceiptMinimum() public {
        _retainsRwa = true;
        RecipeIssuerReceipt(_issuer).setRetainsRwa(true);
        Plan memory plan = _plan();
        plan.receiptAmount = 99;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_RetainedCooldownRejectsRwaConsumption() public {
        _retainsRwa = true;
        bytes[] memory runtime = _prepare(_plan(), _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(_plan(), runtime);
        _assertRollback();
    }

    function test_ConsumingRedemptionRejectsRetainedCooldown() public {
        RecipeIssuerReceipt(_issuer).setRetainsRwa(true);
        bytes[] memory runtime = _prepare(_plan(), _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(_plan(), runtime);
        _assertRollback();
    }

    function test_ExactRwaDisposalIsRequiredEvenWithEnoughReceipts() public {
        Plan memory plan = _plan();
        plan.redeemAmount = 99;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_TooFewRedemptionReceiptsRollsBackEntirePlan() public {
        Plan memory plan = _plan();
        plan.receiptAmount = 99;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    /// forge-config: default.isolate = true
    function test_GasO03LLPositiveMinimum() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        vm.snapshotGasLastCall("LLExecuting", "O03LLPositiveMinimum");
        assertEq(IERC20(_issuer).balanceOf(account), 100);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_rwa).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
    }

    function test_O03ImpliedPositivityReducesInstructions() public {
        (uint256 qualifying, uint256 qualifyingBytes) = this.prepareO03(1e18);
        (uint256 fractional, uint256 fractionalBytes) = this.prepareO03(1e18 + 1);
        assertEq(qualifying + 1, fractional);
        assertEq(qualifyingBytes + 160, fractionalBytes);
    }

    function prepareO03(uint256 denominator) public returns (uint256 length, uint256 encodedLength) {
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = denominator;
        _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        (, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        return (steps.length, _recipe.length);
    }

    function test_O03FractionalFloorStillRequiresPositiveReceipt() public {
        Plan memory plan = _plan();
        plan.amountIn = 1;
        plan.amountOut = 0;
        plan.firstAmount = 0;
        plan.secondAmount = 0;
        plan.redeemAmount = 1;
        plan.receiptAmount = 0;
        _receiptDenominator = 2;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectCall(_issuer, abi.encodeCall(RecipeIssuerReceipt.redeem, (1, 0)), uint64(1));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ZeroReceiptsAreRejectedEvenWithZeroMinimumRate() public {
        Plan memory plan = _plan();
        plan.receiptAmount = 0;
        plan.minReceiptNumerator = 0;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ZeroMinimumRecipeReusesFundingReadsAndOmitsRedundantReceiptInstructions() public {
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 0;
        _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        bytes32 balanceQuery =
            keccak256(abi.encode(_asset, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0)));
        uint256 reads;
        uint256 fundingBalanceReads;
        for (uint256 i; i < steps.length; ++i) {
            uint8 operation = uint8(steps[i][0]);
            assertNotEq(operation, OP_MUL_DIV);
            if (operation == OP_LESS_OR_EQUAL) assertGt(_word(steps[i], 1), 0);
            if (operation == OP_READ) {
                ++reads;
                if (keccak256(queries[_word(steps[i], 1)]) == balanceQuery) ++fundingBalanceReads;
            }
        }
        // The first source's post-withdrawal read also supplies the second source's starting balance.
        assertEq(fundingBalanceReads, 5);
        assertEq(reads, 15);
        assertEq(steps.length, 44);
    }

    function test_ZeroMinimumStillRequiresNewReceiptsWithExistingBalances() public {
        _seedExistingBalances();
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 0;
        plan.receiptAmount = 0;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertExistingBalancesAfterRollback();
    }

    function test_ZeroMinimumStillCapsTotalReceiptsIncludingExistingBalances() public {
        _seedExistingBalances();
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 0;
        plan.receiptAmount = 1;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(plan, runtime);
        _assertExistingBalancesAfterRollback();
    }

    /// forge-config: default.isolate = true
    function test_GasZeroMinimumRecipe() public {
        _seedExistingBalances();
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 0;
        plan.secondAmount = 40;
        plan.receiptAmount = 1;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        uint256[] memory values = _execute(plan, runtime);
        uint256 executionGas = vm.lastCallGas().gasTotalUsed;
        vm.snapshotGasLastCall("LLExecuting", "executeZeroMinimumTwoSources");

        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(values[_layout.sourceAmounts[1]], 40);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 40);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_rwa).balanceOf(account), 50);
        assertEq(IERC20(_issuer).balanceOf(account), 41);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 125);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
        (, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        emit log_named_uint("LLExecuting execution gas", executionGas);
        emit log_named_uint("LLExecuting instructions", steps.length);
        emit log_named_uint("LLExecuting recipe bytes", _recipe.length);
    }

    /// forge-config: default.isolate = true
    function test_GasSkipLastCapacityComparedWithCapacityRead() public {
        _seedExistingBalances();
        uint256 state = vm.snapshotState();
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 0;
        plan.secondAmount = 40;
        plan.receiptAmount = 1;
        bytes memory swapData = _swapData(10_000_000, type(uint48).max, type(uint48).max, false);
        bytes[] memory runtime = _prepare(plan, swapData);
        _execute(plan, runtime);
        uint256 withCapacityGas = vm.lastCallGas().gasTotalUsed;
        vm.snapshotGasLastCall("LLExecuting", "executeZeroMinimumWithLastCapacity");
        (, bytes[] memory withCapacitySteps) = abi.decode(_recipe, (bytes[], bytes[]));
        uint256 withCapacityLength = _recipe.length;

        assertTrue(vm.revertToState(state));
        plan.skipLastCapacity = true;
        runtime = _prepare(plan, swapData);
        uint256[] memory values = _execute(plan, runtime);
        uint256 withoutCapacityGas = vm.lastCallGas().gasTotalUsed;
        vm.snapshotGasLastCall("LLExecuting", "executeZeroMinimumWithoutLastCapacity");
        (, bytes[] memory withoutCapacitySteps) = abi.decode(_recipe, (bytes[], bytes[]));

        assertLt(withoutCapacityGas, withCapacityGas);
        assertEq(withoutCapacitySteps.length + 2, withCapacitySteps.length);
        assertLt(_recipe.length, withCapacityLength);
        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(values[_layout.sourceAmounts[1]], 40);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 40);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_rwa).balanceOf(account), 50);
        assertEq(IERC20(_issuer).balanceOf(account), 41);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 125);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
        emit log_named_uint("LLExecuting with last capacity gas", withCapacityGas);
        emit log_named_uint("LLExecuting without last capacity gas", withoutCapacityGas);
        emit log_named_uint("LLExecuting last capacity gas saved", withCapacityGas - withoutCapacityGas);
        emit log_named_uint("LLExecuting with last capacity instructions", withCapacitySteps.length);
        emit log_named_uint("LLExecuting without last capacity instructions", withoutCapacitySteps.length);
    }

    function test_ReceiptExposureLimitIncludesEarlierExecutions() public {
        _run(_plan(), _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = 90;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        assertEq(IERC20(_issuer).balanceOf(account), 200);
        assertEq(IERC20(_asset).balanceOf(_recipient), 180);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 150);
    }

    function test_InvalidPostActionProofRollsBackSourcesAndSwap() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.redeem], (IMerkleAccount.Action[]));
        actions[1].proof[0] ^= bytes32(uint256(1));
        runtime[_layout.redeem] = abi.encode(actions);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ProviderCannotExecuteWithoutRecipeLeafRole() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        bytes32 leaf = _leaf(actions[0]);
        MerkleAccount(payable(account)).revokeRole(leaf, _executor);
        MerkleAccount(payable(account)).grantRole(leaf, _provider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        _execute(plan, runtime);
        _assertRollback();
    }

    function isValidSignature(bytes32 digest, bytes memory) public view returns (bytes4) {
        return digest == _ownerDigest ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function buildRecipe(LLExecuting.Config memory config)
        public
        pure
        returns (ExecutingRecipe.Recipe memory recipe, LLExecuting.Layout memory layout)
    {
        return LLExecuting.build(config);
    }

    function buildReferenceRecipe(LLExecuting.Config memory config)
        public
        pure
        returns (ExecutingRecipe.Recipe memory recipe, LLExecuting.Layout memory layout)
    {
        return O13FrozenLLExecuting.build(config);
    }

    function prepareO13Fixture(Plan memory plan, bytes memory swapData, uint8 mutation)
        public
        returns (bytes[] memory)
    {
        // The outer public call makes preparation failures (including SafeCast) observable atomically.
        return _prepare(plan, swapData, mutation == 5);
    }

    function executeO13Fixture(Plan memory plan, bytes[] memory runtime, uint8 mutation)
        public
        returns (uint256[] memory)
    {
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        uint256[] memory inputs = new uint256[](mutation == 2 ? 0 : mutation == 3 ? 1 : 2);
        if (inputs.length > 0) inputs[0] = plan.amountIn;
        if (inputs.length > 1) inputs[1] = plan.amountOut;
        if (mutation == 1) runtime = new bytes[](0);
        vm.prank(_provider);
        return RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
    }

    /// forge-config: default.isolate = true
    function test_GasO13ScaledIdentityConsume() public {
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        vm.snapshotGasLastCall("LLExecuting", "O13ScaledIdentityConsume");
        _o13AssertGasEffects(false);
    }

    /// forge-config: default.isolate = true
    function test_GasO13ScaledIdentityRetain() public {
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        _retainsRwa = true;
        RecipeIssuerReceipt(_issuer).setRetainsRwa(true);
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        vm.snapshotGasLastCall("LLExecuting", "O13ScaledIdentityRetain");
        _o13AssertGasEffects(true);
    }

    /// forge-config: default.isolate = true
    function test_GasO13IdentityRetainControl() public {
        Plan memory plan = _plan();
        _retainsRwa = true;
        RecipeIssuerReceipt(_issuer).setRetainsRwa(true);
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        vm.snapshotGasLastCall("LLExecuting", "O13IdentityRetainControl");
        _o13AssertGasEffects(true);
    }

    function test_O13SemanticReferencePins() public {
        uint256 initial = vm.snapshotState();
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        bytes memory swapData = _swapData(10_000_000, type(uint48).max, type(uint48).max, false);
        _o13Reference = true;
        _prepare(plan, swapData);
        (, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        emit log_named_uint("O13 original consume instructions", steps.length);
        emit log_named_uint("O13 original consume bytes", _recipe.length);
        emit log_named_bytes32("O13 original consume hash", keccak256(_recipe));
        _o13AssertObservedReferencePins(_recipe, false);
        assertTrue(vm.revertToState(initial));
        plan = _plan();
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        _retainsRwa = true;
        RecipeIssuerReceipt(_issuer).setRetainsRwa(true);
        _o13Reference = true;
        _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        (, steps) = abi.decode(_recipe, (bytes[], bytes[]));
        emit log_named_uint("O13 original retain instructions", steps.length);
        emit log_named_uint("O13 original retain bytes", _recipe.length);
        emit log_named_bytes32("O13 original retain hash", keccak256(_recipe));
        _o13AssertObservedReferencePins(_recipe, true);
    }

    function test_O13CappedIdentityReducesInstructions() public {
        uint256 initial = vm.snapshotState();
        for (uint256 mode; mode < 2; ++mode) {
            Plan memory plan = _plan();
            plan.minReceiptNumerator = 1e18;
            _receiptDenominator = 1e18;
            _retainsRwa = mode > 0;
            RecipeIssuerReceipt(_issuer).setRetainsRwa(mode > 0);
            (O13Prepared memory original, O13Prepared memory candidate) =
                _o13PreparePair(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
            _o13AssertObservedReferencePins(original.encoded, mode > 0);
            _o13AssertConfiguredProgram(original, plan);
            _o13AssertConfiguredProgram(candidate, plan);
            (, bytes[] memory referenceSteps) = abi.decode(original.encoded, (bytes[], bytes[]));
            (, bytes[] memory candidateSteps) = abi.decode(candidate.encoded, (bytes[], bytes[]));
            assertEq(_o13CountOperation(referenceSteps, OP_MUL_DIV), 1);
            // This is the sole expected RED failure on original production.
            assertEq(_o13CountOperation(candidateSteps, OP_MUL_DIV), 0, "capped identity product remains");
            assertEq(candidateSteps.length + 1, referenceSteps.length);
            assertEq(candidate.encoded.length + 192, original.encoded.length);
            _o13AssertProgramsEquivalent(original.encoded, candidate.encoded);
            uint256 removed = _o13IdentityProduct(referenceSteps);
            bool referenceMinimum;
            bool candidateMinimum;
            for (uint256 i; i < referenceSteps.length; ++i) {
                if (
                    uint8(referenceSteps[i][0]) == OP_LESS_OR_EQUAL
                        && _word(referenceSteps[i], 1) == ExecutingRecipe.result(removed)
                ) referenceMinimum = true;
            }
            for (uint256 i; i < candidateSteps.length; ++i) {
                if (
                    i > ExecutingRecipe.runtimeSteps(_o13Decode(candidate.encoded))[candidate.layout.redeem]
                        && uint8(candidateSteps[i][0]) == OP_LESS_OR_EQUAL
                        && _word(candidateSteps[i], 1) == candidate.layout.amountIn
                ) candidateMinimum = true;
            }
            assertTrue(referenceMinimum);
            assertTrue(candidateMinimum);
            assertTrue(vm.revertToState(initial));
        }
        // Controls with no specialization must be exact, including complete runtime/action bytes.
        Plan memory control = _plan();
        _o13AssertExactControl(control);
        assertTrue(vm.revertToState(initial));
        control = _plan();
        control.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18 + 1;
        _o13AssertExactControl(control);
        assertTrue(vm.revertToState(initial));
        control = _plan();
        control.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        _o13MaxAmountIn = type(uint256).max / 1e18 + 1;
        _o13AssertExactControl(control);
        assertTrue(vm.revertToState(initial));
        control = _plan();
        control.redeem = false;
        control.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        _o13AssertExactControl(control);
    }

    function test_O13SemanticBothModesAndFlags() public {
        uint256 initial = vm.snapshotState();
        for (uint256 flags; flags < 8; ++flags) {
            _retainsRwa = flags & 1 > 0;
            _skipUnusedReads = flags & 2 > 0;
            _skipZeroApprovals = flags & 4 > 0;
            RecipeIssuerReceipt(_issuer).setRetainsRwa(_retainsRwa);
            _receiptDenominator = 1e18;
            Plan memory plan = _plan();
            plan.minReceiptNumerator = 1e18;
            (bool success, bytes memory result) =
                _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
            assertTrue(success);
            assertGt(result.length, 0);
            assertTrue(vm.revertToState(initial));
        }
    }

    function test_O13SemanticIdentityArithmeticThresholds() public {
        uint256 initial = vm.snapshotState();
        uint256[2] memory factors = [uint256(1e18), type(uint216).max];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 i; i < factors.length; ++i) {
                uint256 factor = factors[i];
                uint256 threshold = type(uint256).max / factor;
                _o13ThresholdCase(factor, threshold, threshold, mode > 0, "");
                assertTrue(vm.revertToState(initial));
                _o13ThresholdCase(
                    factor,
                    threshold + 1,
                    threshold + 1,
                    mode > 0,
                    abi.encodeWithSignature("Panic(uint256)", uint256(0x11))
                );
                assertTrue(vm.revertToState(initial));
                _o13ThresholdCase(
                    factor, threshold, threshold + 1, mode > 0, abi.encodeWithSelector(IRecipes.CheckFailed.selector)
                );
                assertTrue(vm.revertToState(initial));
            }
        }
        _o13ThresholdCase(1, type(uint216).max, type(uint216).max, false, "");
        assertTrue(vm.revertToState(initial));
        Plan memory plan = _plan();
        plan.amountIn = type(uint256).max;
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        (bool success, bytes memory result) =
            _o13Differential(plan, _swapData(100_000_000, type(uint48).max, type(uint48).max, false), 0);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
    }

    function test_O13SemanticZeroAndFractionalRates() public {
        uint256 initial = vm.snapshotState();
        uint256[5] memory numerators = [uint256(0), 0, 1, 1, 2];
        uint256[5] memory denominators = [uint256(0), 1, 0, 2, 2];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 i; i < numerators.length; ++i) {
                _retainsRwa = mode > 0;
                RecipeIssuerReceipt(_issuer).setRetainsRwa(mode > 0);
                _receiptDenominator = denominators[i];
                Plan memory plan = _plan();
                plan.minReceiptNumerator = numerators[i];
                plan.receiptAmount = i == 1 ? 1 : i == 3 ? 50 : 100;
                (bool success, bytes memory result) =
                    _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
                if (denominators[i] == 0) {
                    assertFalse(success);
                    assertEq(result, abi.encodeWithSignature("Panic(uint256)", uint256(0x12)));
                } else {
                    assertTrue(success);
                }
                assertTrue(vm.revertToState(initial));
            }
        }
        Plan memory plan = _plan();
        plan.minReceiptNumerator = 1;
        _receiptDenominator = 2;
        plan.receiptAmount = 49;
        (bool success, bytes memory result) =
            _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
    }

    function test_O13SemanticLiteralWidthAndErrorPrecedence() public {
        uint256 initial = vm.snapshotState();
        for (uint256 variant; variant < 7; ++variant) {
            Plan memory plan = _plan();
            plan.minReceiptNumerator =
                variant == 0 || variant == 2 || variant == 4 || variant == 6 ? uint256(type(uint216).max) + 1 : 1;
            _receiptDenominator = variant == 1 || variant == 2 || variant == 5 || variant == 6
                ? uint256(type(uint216).max) + 1
                : variant == 4 ? 0 : 1;
            _o13MaxAmountIn = variant >= 3 ? uint256(type(uint216).max) + 1 : 1000;
            if (variant == 5 || variant == 6) plan.amountIn = 0;
            (bool success, bytes memory result) =
                _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
            assertFalse(success);
            assertEq(bytes4(result), bytes4(keccak256("SafeCastOverflowedUintDowncast(uint8,uint256)")));
            assertTrue(vm.revertToState(initial));
        }
        Plan memory plan = _plan();
        plan.amountIn = 0;
        plan.minReceiptNumerator = 0;
        _receiptDenominator = 0;
        (bool success, bytes memory result) =
            _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        assertTrue(vm.revertToState(initial));
        plan = _plan();
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        _o13MaxAmountIn = 0;
        (success, result) = _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
    }

    function test_O13SemanticFreshReceiptsAndRwaMismatch() public {
        uint256 initial = vm.snapshotState();
        for (uint256 variant; variant < 8; ++variant) {
            Plan memory plan = _plan();
            plan.minReceiptNumerator = 1e18;
            _receiptDenominator = 1e18;
            _retainsRwa = variant & 1 > 0;
            RecipeIssuerReceipt(_issuer).setRetainsRwa(_retainsRwa);
            if (variant < 4) {
                // Old balances do not satisfy a short new receipt requirement.
                _seedExistingBalances();
                plan.secondAmount = 40;
                plan.receiptAmount = variant < 2 ? 99 : 0;
            } else if (variant < 6) {
                RecipeIssuerReceipt(_issuer).setRetainsRwa(!_retainsRwa);
            } else {
                plan.redeemAmount = 99;
            }
            (bool success, bytes memory result) =
                _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
            // A retained request's unbound redeemAmount is not an enforced disposal amount.
            if (variant == 7) {
                assertTrue(success);
            } else {
                assertFalse(success);
                assertEq(result, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            }
            assertTrue(vm.revertToState(initial));
        }
        _seedExistingBalances();
        Plan memory plan = _plan();
        plan.secondAmount = 40;
        plan.minReceiptNumerator = 1e18;
        _receiptDenominator = 1e18;
        (bool success,) = _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
        assertTrue(success);
    }

    function test_O13SemanticNativeAuthorizationAndFailures() public {
        uint256 initial = vm.snapshotState();
        for (uint256 mode; mode < 2; ++mode) {
            for (uint8 failure; failure < 18; ++failure) {
                Plan memory plan = _plan();
                plan.minReceiptNumerator = 1e18;
                _receiptDenominator = 1e18;
                _retainsRwa = mode > 0;
                RecipeIssuerReceipt(_issuer).setRetainsRwa(mode > 0);
                bytes memory swapData = _o13FailureQuote(failure);
                // 0..9 are runtime/action/callback failures; 10..17 are native authorization failures.
                uint8 mutation = failure < 10 ? failure + 1 : 0;
                if (mutation == 4) {
                    plan.firstAmount = 0;
                    plan.secondAmount = type(uint256).max;
                }
                (bool success, bytes memory result) = _o13Differential(plan, swapData, mutation);
                if (mutation == 4) {
                    assertTrue(success); // Input binding replaces the deliberately wrong amount.
                } else {
                    assertFalse(success);
                    assertGt(result.length, 0);
                }
                assertTrue(vm.revertToState(initial));
            }
        }
    }

    function test_O13SemanticCleanupAndNoRedemptionControls() public {
        uint256 initial = vm.snapshotState();
        for (uint256 flags; flags < 4; ++flags) {
            Plan memory plan = _plan();
            plan.minReceiptNumerator = 1e18;
            _receiptDenominator = 1e18;
            _skipZeroApprovals = flags & 1 > 0;
            _retainsRwa = flags & 2 > 0;
            RecipeIssuerReceipt(_issuer).setRetainsRwa(_retainsRwa);
            (bool success, bytes memory result) =
                _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 11);
            assertFalse(success);
            assertGt(result.length, 0);
            assertTrue(vm.revertToState(initial));
        }
        Plan memory plan = _plan();
        plan.redeem = false;
        plan.minReceiptNumerator = uint256(type(uint216).max) + 1;
        _receiptDenominator = 0;
        _o13AssertExactControl(plan);
        (bool success,) = _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
        assertTrue(success);
    }

    function test_O13SemanticERC1271OwnerAuthorization() public {
        uint256 initial = vm.snapshotState();
        for (uint256 mode; mode < 2; ++mode) {
            Plan memory plan = _plan();
            plan.minReceiptNumerator = 1e18;
            _receiptDenominator = 1e18;
            _retainsRwa = mode > 0;
            RecipeIssuerReceipt(_issuer).setRetainsRwa(mode > 0);
            (bool success,) = _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, true), 0);
            assertTrue(success);
            assertTrue(vm.revertToState(initial));
        }
    }

    function testFuzz_O13SemanticSafeIdentity(uint256 factorSeed, uint256 amountSeed, bool retained, uint8 flags)
        public
    {
        uint256 factor = bound(factorSeed, 1, type(uint216).max);
        uint256 safeCap = type(uint256).max / factor;
        if (safeCap > type(uint216).max) safeCap = type(uint216).max;
        uint256 amount = bound(amountSeed, 1, safeCap);
        _skipUnusedReads = flags & 1 > 0;
        _skipZeroApprovals = flags & 2 > 0;
        _o13ThresholdCase(factor, safeCap, amount, retained, "");
    }

    function testFuzz_O13SemanticUnsafeIdentity(uint256 factorSeed, bool retained, uint8 flags) public {
        uint256 factor = bound(factorSeed, (uint256(1) << 40) + 1, type(uint216).max);
        uint256 unsafeAmount = type(uint256).max / factor + 1;
        _skipUnusedReads = flags & 1 > 0;
        _skipZeroApprovals = flags & 2 > 0;
        _o13ThresholdCase(
            factor, unsafeAmount, unsafeAmount, retained, abi.encodeWithSignature("Panic(uint256)", uint256(0x11))
        );
    }

    function testFuzz_O13SemanticNonIdentity(uint256 numeratorSeed, uint256 denominatorSeed, bool retained) public {
        Plan memory plan = _plan();
        // Runtime amount stays independently fixed; arbitrary factors span all literal bits.
        plan.minReceiptNumerator = bound(numeratorSeed, 0, type(uint216).max);
        _receiptDenominator = bound(denominatorSeed, 0, type(uint216).max);
        if (plan.minReceiptNumerator == _receiptDenominator) {
            _receiptDenominator = _receiptDenominator == type(uint216).max ? 0 : _receiptDenominator + 1;
        }
        _retainsRwa = retained;
        RecipeIssuerReceipt(_issuer).setRetainsRwa(retained);
        _o13AssertExactControl(plan);
        _o13Differential(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
    }

    function _o13AssertGasEffects(bool retained) internal view {
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
        assertEq(RecipeLiquiditySource(_first).calls(), 1);
        assertEq(RecipeLiquiditySource(_second).calls(), 1);
        assertEq(RecipeLiquiditySource(_first).liquidity(), 0);
        assertEq(RecipeLiquiditySource(_second).liquidity(), 999_940);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
        assertEq(IERC20(_rwa).balanceOf(_lane), 999_900);
        assertEq(IERC20(_rwa).balanceOf(_issuer), 0);
        assertEq(IERC20(_rwa).balanceOf(account), retained ? 100 : 0);
        assertEq(RecipeRwaToken(_rwa).redeemed(), retained ? 0 : 100);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
        assertFalse(ILiquidLaneConnector(_lane).isUsedNonce(_rwa, 7));
    }

    function _o13ThresholdCase(uint256 factor, uint256 cap, uint256 amount, bool retained, bytes memory expectedError)
        internal
    {
        Plan memory plan = _plan();
        plan.amountIn = amount;
        plan.amountOut = 0;
        plan.firstAmount = 0;
        plan.secondAmount = 0;
        plan.redeemAmount = amount;
        plan.receiptAmount = amount;
        plan.minReceiptNumerator = factor;
        _receiptDenominator = factor;
        _o13MaxAmountIn = cap;
        _retainsRwa = retained;
        RecipeIssuerReceipt(_issuer).setRetainsRwa(retained);
        deal(_rwa, _lane, amount, true);
        (bool success, bytes memory result) =
            _o13Differential(plan, _swapData(100_000_000, type(uint48).max, type(uint48).max, false), 0);
        if (expectedError.length > 0) {
            assertFalse(success);
            assertEq(result, expectedError);
        } else {
            assertTrue(success);
        }
    }

    function _o13AssertObservedReferencePins(bytes memory encoded, bool retained) internal pure {
        // O13_CAPTURE_PINS_START
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(encoded, (bytes[], bytes[]));
        assertEq(queries.length, 6);
        assertEq(steps.length, retained ? 45 : 45);
        assertEq(encoded.length, retained ? 9952 : 9952);
        assertEq(
            keccak256(encoded),
            retained
                ? bytes32(0x47cb0e8529d0231299bd69492855147ad9b706bf2b9ae69d3c396e5696795379)
                : bytes32(0x339aab82f84de39a1a458644f8779c586e4846ada6e231889ea8bb43eda3a733)
        );
        // O13_CAPTURE_PINS_END
    }

    function _o13Decode(bytes memory encoded) internal pure returns (ExecutingRecipe.Recipe memory recipe) {
        (recipe.queries, recipe.steps) = abi.decode(encoded, (bytes[], bytes[]));
    }

    function _o13CountOperation(bytes[] memory steps, uint8 operation) internal pure returns (uint256 count) {
        for (uint256 i; i < steps.length; ++i) {
            if (uint8(steps[i][0]) == operation) ++count;
        }
    }

    function _o13IdentityProduct(bytes[] memory steps) internal pure returns (uint256 removed) {
        removed = type(uint256).max;
        for (uint256 i; i < steps.length; ++i) {
            if (uint8(steps[i][0]) == OP_MUL_DIV) {
                assertEq(removed, type(uint256).max, "multiple products in identity fixture");
                assertEq(_word(steps[i], 1), uint256(SRC_INPUT) << 216);
                assertGt(_word(steps[i], 33), 0);
                assertEq(_word(steps[i], 33), _word(steps[i], 65));
                removed = i;
            }
        }
        assertNotEq(removed, type(uint256).max, "missing reference identity product");
    }

    function _o13PreparePair(Plan memory plan, bytes memory swapData, uint8 mutation)
        internal
        returns (O13Prepared memory original, O13Prepared memory candidate)
    {
        uint256 state = vm.snapshotState();
        _o13Reference = true;
        original.runtime = _prepare(plan, swapData, mutation == 5);
        original.encoded = bytes.concat(_recipe);
        original.layout = _layout;
        assertTrue(vm.revertToState(state));
        _o13Reference = false;
        candidate.runtime = _prepare(plan, swapData, mutation == 5);
        candidate.encoded = bytes.concat(_recipe);
        candidate.layout = _layout;
        assertEq(abi.encode(original.layout), abi.encode(candidate.layout));
        assertEq(abi.encode(original.runtime), abi.encode(candidate.runtime));
    }

    function _o13AssertExactControl(Plan memory plan) internal {
        (O13Prepared memory original, O13Prepared memory candidate) =
            _o13PreparePair(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false), 0);
        assertEq(candidate.encoded, original.encoded);
    }

    function _o13AssertConfiguredProgram(O13Prepared memory prepared, Plan memory plan) internal view {
        ExecutingRecipe.Recipe memory recipe = _o13Decode(prepared.encoded);
        assertEq(recipe.queries.length, 6);
        assertEq(
            recipe.queries[0],
            abi.encode(_first, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), new uint256[](0), uint256(0))
        );
        assertEq(
            recipe.queries[1],
            abi.encode(_asset, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0))
        );
        assertEq(
            recipe.queries[2],
            abi.encode(_second, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), new uint256[](0), uint256(0))
        );
        assertEq(
            recipe.queries[3],
            abi.encode(_asset, abi.encodeCall(IERC20.balanceOf, (_recipient)), new uint256[](0), uint256(0))
        );
        assertEq(
            recipe.queries[4],
            abi.encode(_rwa, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0))
        );
        assertEq(
            recipe.queries[5],
            abi.encode(_issuer, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0))
        );
        assertEq(prepared.layout.amountIn, uint256(SRC_INPUT) << 216);
        assertEq(prepared.layout.amountOut, uint256(SRC_INPUT) << 216 | 1);
        assertEq(prepared.layout.sourceCalls[0], 0);
        assertEq(prepared.layout.sourceCalls[1], 1);
        assertEq(prepared.layout.approve, 2);
        assertEq(prepared.layout.operation, 3);
        assertEq(prepared.layout.clearApproval, 4);
        assertEq(prepared.layout.redeemApprove, 5);
        assertEq(prepared.layout.redeem, 6);
        assertEq(prepared.layout.redeemClearApproval, 7);
        assertEq(prepared.runtime.length, 8);
        uint256[] memory runtimeSteps = ExecutingRecipe.runtimeSteps(recipe);
        assertEq(runtimeSteps.length, 8);
        for (uint256 i; i < 2; ++i) {
            IMerkleAccount.Action[] memory actions = abi.decode(prepared.runtime[i], (IMerkleAccount.Action[]));
            assertEq(actions.length, 1);
            assertEq(actions[0].target, i == 0 ? _first : _second);
            assertEq(bytes4(actions[0].data), RecipeLiquiditySource.withdraw.selector);
            assertEq(address(uint160(_word(actions[0].data, 4))), account);
            assertEq(_word(actions[0].data, 36), i == 0 ? plan.firstAmount : plan.secondAmount);
            for (uint256 j; j < actions[0].dataMask.length; ++j) {
                assertEq(uint8(actions[0].dataMask[j]), j < 36 ? 0 : 255);
            }
            bytes memory step = recipe.steps[runtimeSteps[i]];
            assertEq(uint8(step[0]), OP_MANAGE);
            (uint256 gate, bytes32[] memory leaves, uint256[][] memory bindings) =
                abi.decode(_o13Payload(step), (uint256, bytes32[], uint256[][]));
            assertEq(gate, ExecutingRecipe.result(prepared.layout.sourceAmounts[i]));
            assertEq(leaves.length, 1);
            assertEq(leaves[0], _leaf(actions[0]));
            assertEq(bindings.length, 1);
            assertEq(bindings[0].length, 1);
            assertEq(bindings[0][0], ExecutingRecipe.binding(36, gate));
        }
        IMerkleAccount.Action[] memory swap = abi.decode(prepared.runtime[3], (IMerkleAccount.Action[]));
        assertEq(swap.length, 1);
        assertEq(swap[0].target, _lane);
        assertEq(
            bytes4(swap[0].data),
            bytes4(
                keccak256("swap(((address,uint256,address,address,uint256,uint48),bytes,uint48),bytes,address,uint256)")
            )
        );
        assertEq(address(uint160(_word(swap[0].data, 68))), _recipient);
        assertEq(_word(swap[0].data, 100), 100);
        (uint256 swapGate, bytes32[] memory swapLeaves, uint256[][] memory swapBindings) =
            abi.decode(_o13Payload(recipe.steps[runtimeSteps[3]]), (uint256, bytes32[], uint256[][]));
        assertEq(swapGate, prepared.layout.amountIn);
        assertEq(swapLeaves.length, 1);
        assertEq(swapLeaves[0], _leaf(swap[0]));
        assertEq(swapBindings.length, 1);
        assertEq(swapBindings[0].length, 1);
        assertEq(swapBindings[0][0], ExecutingRecipe.binding(100, prepared.layout.amountIn));
        assertEq(prepared.runtime[2], prepared.runtime[4]);
        assertEq(prepared.runtime[5], prepared.runtime[7]);
        _o13AssertApproval(recipe.steps[runtimeSteps[2]], prepared.runtime[2], _asset, _lane, prepared.layout.amountOut);
        _o13AssertApproval(recipe.steps[runtimeSteps[4]], prepared.runtime[4], _asset, _lane, 0);
        _o13AssertApproval(recipe.steps[runtimeSteps[5]], prepared.runtime[5], _rwa, _issuer, prepared.layout.amountIn);
        _o13AssertApproval(recipe.steps[runtimeSteps[7]], prepared.runtime[7], _rwa, _issuer, 0);
        IMerkleAccount.Action[] memory posts = abi.decode(prepared.runtime[6], (IMerkleAccount.Action[]));
        assertEq(posts.length, 2);
        for (uint256 i; i < 2; ++i) {
            assertEq(posts[i].target, _issuer);
            assertEq(bytes4(posts[i].data), RecipeIssuerReceipt.redeem.selector);
            assertEq(
                _word(posts[i].data, 4), i == 0 ? plan.redeemAmount / 2 : plan.redeemAmount - plan.redeemAmount / 2
            );
            assertEq(
                _word(posts[i].data, 36), i == 0 ? plan.receiptAmount / 2 : plan.receiptAmount - plan.receiptAmount / 2
            );
            for (uint256 j; j < posts[i].dataMask.length; ++j) {
                assertEq(uint8(posts[i].dataMask[j]), j < 4 ? 0 : 255);
            }
        }
        (uint256 redeemGate, bytes32[] memory redeemLeaves, uint256[][] memory redeemBindings) =
            abi.decode(_o13Payload(recipe.steps[runtimeSteps[6]]), (uint256, bytes32[], uint256[][]));
        assertEq(redeemGate, prepared.layout.amountIn);
        assertEq(redeemLeaves.length, 2);
        assertEq(redeemBindings.length, 2);
        assertEq(redeemLeaves[0], _leaf(posts[0]));
        assertEq(redeemLeaves[1], _leaf(posts[1]));
        assertEq(redeemBindings[0].length, 0);
        assertEq(redeemBindings[1].length, 0);
    }

    function _o13AssertApproval(
        bytes memory step,
        bytes memory runtime,
        address expectedToken,
        address expectedSpender,
        uint256 expectedAmount
    ) internal view {
        assertEq(uint8(step[0]), OP_APPROVE);
        (uint256 amount, address token, address spender, bytes32 leaf) =
            abi.decode(_o13Payload(step), (uint256, address, address, bytes32));
        assertEq(amount, expectedAmount);
        assertEq(token, expectedToken);
        assertEq(spender, expectedSpender);
        (bytes memory mask, bytes32[] memory proof) = abi.decode(runtime, (bytes, bytes32[]));
        bytes memory approvalData = abi.encodeCall(IERC20.approve, (spender, 0));
        assertEq(mask.length, approvalData.length);
        for (uint256 i; i < mask.length; ++i) {
            assertEq(uint8(mask[i]), i < 36 ? 0 : 255);
        }
        assertEq(proof.length, 3);
        assertEq(leaf, MerkleAdapterVerifier.leaf(token, 0, approvalData, mask));
        assertTrue(MerkleAccount(payable(account)).hasRole(leaf, _executor));
    }

    function _o13Payload(bytes memory step) internal pure returns (bytes memory payload) {
        payload = new bytes(step.length - 1);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = step[i + 1];
        }
    }

    function _o13RemapOperand(uint256 operand, uint256 removed) internal pure returns (uint256) {
        if (uint8(operand >> 216) != SRC_RESULT) return operand;
        uint256 producer = uint216(operand);
        if (producer == removed) return uint256(SRC_INPUT) << 216;
        return producer > removed ? ExecutingRecipe.result(producer - 1) : operand;
    }

    function _o13RemapBindings(uint256[][] memory bindings, uint256 removed)
        internal
        pure
        returns (uint256[][] memory)
    {
        for (uint256 i; i < bindings.length; ++i) {
            for (uint256 j; j < bindings[i].length; ++j) {
                uint256 binding = bindings[i][j];
                bindings[i][j] = (binding >> 224) << 224 | _o13RemapOperand(uint224(binding), removed);
            }
        }
        return bindings;
    }

    function _o13RemapStep(bytes memory step, uint256 removed) internal pure returns (bytes memory) {
        uint8 operation = uint8(step[0]);
        bytes memory payload = _o13Payload(step);
        if (operation <= OP_LESS_OR_EQUAL && operation > OP_READ && operation != OP_MUL_DIV) {
            (uint256 a, uint256 b) = abi.decode(payload, (uint256, uint256));
            return abi.encodePacked(operation, abi.encode(_o13RemapOperand(a, removed), _o13RemapOperand(b, removed)));
        }
        if (operation == OP_MANAGE) {
            (uint256 gate, bytes32[] memory leaves, uint256[][] memory bindings) =
                abi.decode(payload, (uint256, bytes32[], uint256[][]));
            return abi.encodePacked(
                operation, abi.encode(_o13RemapOperand(gate, removed), leaves, _o13RemapBindings(bindings, removed))
            );
        }
        if (operation == OP_APPROVE) {
            (uint256 amount, address token, address spender, bytes32 leaf) =
                abi.decode(payload, (uint256, address, address, bytes32));
            return abi.encodePacked(operation, abi.encode(_o13RemapOperand(amount, removed), token, spender, leaf));
        }
        return step;
    }

    function _o13AssertProgramsEquivalent(bytes memory original, bytes memory candidate) internal pure {
        ExecutingRecipe.Recipe memory oldRecipe = _o13Decode(original);
        ExecutingRecipe.Recipe memory newRecipe = _o13Decode(candidate);
        assertEq(abi.encode(oldRecipe.queries), abi.encode(newRecipe.queries));
        if (oldRecipe.steps.length == newRecipe.steps.length) {
            assertEq(original, candidate);
            return;
        }
        assertEq(newRecipe.steps.length + 1, oldRecipe.steps.length);
        assertEq(candidate.length + 192, original.length);
        uint256 removed = _o13IdentityProduct(oldRecipe.steps);
        uint256 target;
        for (uint256 i; i < oldRecipe.steps.length; ++i) {
            if (i == removed) continue;
            assertEq(newRecipe.steps[target++], _o13RemapStep(oldRecipe.steps[i], removed));
        }
    }

    function _o13Differential(Plan memory plan, bytes memory swapData, uint8 mutation)
        internal
        returns (bool success, bytes memory result)
    {
        uint256 state = vm.snapshotState();
        _o13Reference = true;
        O13Outcome memory original = _o13Capture(plan, swapData, mutation);
        assertTrue(vm.revertToState(state));
        _o13Reference = false;
        O13Outcome memory candidate = _o13Capture(plan, swapData, mutation);
        assertEq(candidate.built, original.built);
        assertEq(candidate.success, original.success);
        assertEq(candidate.runtimeHash, original.runtimeHash);
        assertEq(candidate.beforeState, original.beforeState);
        assertEq(candidate.afterState, original.afterState);
        assertEq(abi.encode(candidate.layout), abi.encode(original.layout));
        assertEq(abi.encode(candidate.logs), abi.encode(original.logs));
        if (original.built) _o13AssertProgramsEquivalent(original.encoded, candidate.encoded);
        if (original.success) {
            _o13AssertNumericalMapping(original, candidate, plan);
        } else {
            assertEq(candidate.result, original.result);
            assertEq(original.afterState, original.beforeState, "reference rollback changed state");
            assertEq(candidate.afterState, candidate.beforeState, "candidate rollback changed state");
        }
        // Leave the caller's complete configured pre-execution state intact for matrix isolation.
        assertTrue(vm.revertToState(state));
        return (candidate.success, candidate.result);
    }

    function _o13Capture(Plan memory plan, bytes memory swapData, uint8 mutation)
        internal
        returns (O13Outcome memory outcome)
    {
        bytes32 beforePreparation = _o13StateHash();
        (bool built, bytes memory prepared) =
            address(this).call(abi.encodeCall(this.prepareO13Fixture, (plan, swapData, mutation)));
        outcome.built = built;
        if (!built) {
            outcome.result = prepared;
            outcome.beforeState = beforePreparation;
            outcome.afterState = _o13StateHash();
            outcome.logs = new Vm.Log[](0);
            return outcome;
        }
        bytes[] memory runtime = abi.decode(prepared, (bytes[]));
        outcome.encoded = bytes.concat(_recipe);
        outcome.layout = _layout;
        _o13Mutate(runtime, mutation);
        outcome.runtimeHash = keccak256(abi.encode(runtime));
        outcome.beforeState = _o13StateHash();
        assertEq(RecipeExecutor(_executor).recipeHash(), keccak256(outcome.encoded));
        uint256[22] memory effects = _o13EffectValues();
        bytes32 roleState = _o13RoleState(runtime);
        vm.recordLogs();
        (outcome.success, outcome.result) =
            address(this).call(abi.encodeCall(this.executeO13Fixture, (plan, runtime, mutation)));
        outcome.logs = vm.getRecordedLogs();
        outcome.afterState = _o13StateHash();
        assertEq(_o13RoleState(runtime), roleState, "executor changed leaf permissions");
        assertEq(RecipeExecutor(_executor).recipeHash(), keccak256(outcome.encoded));
        if (outcome.success) _o13AssertSuccessEffects(plan, outcome.layout, outcome.result, effects);
    }

    function _o13AssertNumericalMapping(O13Outcome memory original, O13Outcome memory candidate, Plan memory plan)
        internal
        pure
    {
        uint256[] memory oldValues = abi.decode(original.result, (uint256[]));
        uint256[] memory newValues = abi.decode(candidate.result, (uint256[]));
        ExecutingRecipe.Recipe memory oldRecipe = _o13Decode(original.encoded);
        ExecutingRecipe.Recipe memory newRecipe = _o13Decode(candidate.encoded);
        assertEq(oldValues.length, oldRecipe.steps.length);
        assertEq(newValues.length, newRecipe.steps.length);
        uint256 removed =
            oldValues.length == newValues.length ? type(uint256).max : _o13IdentityProduct(oldRecipe.steps);
        for (uint256 i; i < oldValues.length; ++i) {
            uint8 operation = uint8(oldRecipe.steps[i][0]);
            if (operation > OP_MUL_DIV) continue;
            if (i == removed) assertEq(oldValues[i], plan.amountIn);
            else assertEq(oldValues[i], newValues[i > removed ? i - 1 : i]);
        }
        for (uint256 i; i < original.layout.sourceAmounts.length; ++i) {
            assertEq(oldValues[original.layout.sourceAmounts[i]], newValues[candidate.layout.sourceAmounts[i]]);
        }
    }

    function _o13Mutate(bytes[] memory runtime, uint8 mutation) internal {
        if (mutation == 4 || mutation == 5) {
            IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
            bytes memory data = actions[0].data;
            if (mutation == 4) {
                assembly ("memory-safe") { mstore(add(data, 132), 777) }
            } else {
                address wrongRecipient = address(this);
                assembly ("memory-safe") { mstore(add(data, 100), wrongRecipient) }
            }
            runtime[_layout.operation] = abi.encode(actions);
        } else if (mutation == 6) {
            IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.redeem], (IMerkleAccount.Action[]));
            actions[1].proof[0] ^= bytes32(uint256(1));
            runtime[_layout.redeem] = abi.encode(actions);
        } else if (mutation == 7) {
            IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
            MerkleAccount(payable(account)).revokeRole(_leaf(actions[0]), _executor);
        } else if (mutation == 8) {
            RecipeLiquiditySource(_first)
                .setCallback(_issuer, abi.encodeCall(RecipeIssuerReceipt.setRetainsRwa, (!_retainsRwa)));
        } else if (mutation == 9) {
            RecipeLiquiditySource(_first)
                .setCallback(
                    _executor,
                    abi.encodeCall(
                        RecipeExecutor.execute, (new bytes[](0), new bytes[](0), new uint256[](0), new bytes[](0))
                    )
                );
        } else if (mutation == 10 || mutation == 11) {
            uint256 slot = mutation == 10 ? _layout.approve : _layout.clearApproval;
            (bytes memory mask, bytes32[] memory proof) = abi.decode(runtime[slot], (bytes, bytes32[]));
            proof[0] ^= bytes32(uint256(1));
            runtime[slot] = abi.encode(mask, proof);
        }
    }

    function _o13FailureQuote(uint8 failure) internal returns (bytes memory) {
        if (failure < 10) return _swapData(10_000_000, type(uint48).max, type(uint48).max, false);
        (ILiquidLaneConnector.DiscountSwap memory quote, bytes memory signature) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        if (failure == 10) {
            signature[0] ^= bytes1(uint8(1));
        } else if (failure == 11) {
            quote.signerSignature[0] ^= bytes1(uint8(1));
            signature = _protocolSignature(quote);
        } else if (failure == 12) {
            quote.signerSignature = _sign(
                0xAAA,
                keccak256(
                    abi.encodePacked(hex"1901", bytes32(0), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount)))
                )
            );
            signature = _protocolSignature(quote);
        } else if (failure == 13) {
            quote.discount.deadline = uint48(block.timestamp - 1);
            quote.signerSignature = _sign(
                0xAAA,
                keccak256(
                    abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount)))
                )
            );
            signature = _protocolSignature(quote);
        } else if (failure == 14) {
            quote.protocolDeadline = uint48(block.timestamp - 1);
            signature = _protocolSignature(quote);
        } else if (failure == 15) {
            LiquidLaneConnector(_lane).invalidateNonce(_rwa, 7);
        } else if (failure == 16) {
            quote.discount.signer = vm.addr(0xCCC);
            quote.signerSignature = _sign(
                0xCCC,
                keccak256(
                    abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount)))
                )
            );
            signature = _protocolSignature(quote);
        } else {
            quote.discount.discount = 9_000_000;
            quote.signerSignature = _sign(
                0xAAA,
                keccak256(
                    abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount)))
                )
            );
            signature = _protocolSignature(quote);
        }
        return _encodeSwap(quote, signature);
    }

    function _o13EffectValues() internal view returns (uint256[22] memory values) {
        // Snapshot independent balance/call expectations, before the executor touches the fixture.
        values[0] = IERC20(_asset).balanceOf(account);
        values[1] = IERC20(_asset).balanceOf(_recipient);
        values[2] = IERC20(_rwa).balanceOf(account);
        values[3] = IERC20(_rwa).balanceOf(_lane);
        values[4] = IERC20(_rwa).balanceOf(_issuer);
        values[5] = IERC20(_issuer).balanceOf(account);
        values[6] = IERC20(_issuer).totalSupply();
        values[7] = IERC20(_rwa).totalSupply();
        values[8] = RecipeRwaToken(_rwa).redeemed();
        values[9] = RecipeLiquiditySource(_first).withdrawn();
        values[10] = RecipeLiquiditySource(_second).withdrawn();
        values[11] = RecipeLiquiditySource(_first).calls();
        values[12] = RecipeLiquiditySource(_second).calls();
        values[13] = RecipeLiquiditySource(_first).liquidity();
        values[14] = RecipeLiquiditySource(_second).liquidity();
        values[15] = IERC20(_asset).balanceOf(_first);
        values[16] = IERC20(_asset).balanceOf(_second);
        values[17] = IERC20(_asset).balanceOf(_lane);
        values[18] = IERC20(_asset).balanceOf(_issuer);
        values[19] = IERC20(_asset).totalSupply();
        (,,, values[20]) = LiquidLaneConnector(_lane).assetLimits(_rwa);
        values[21] = LiquidLaneConnector(_lane).isUsedNonce(_rwa, 7) ? 1 : 0;
    }

    function _o13RoleState(bytes[] memory runtime) internal view returns (bytes32 state) {
        // The fixture carries sources, swap and optional redemption groups in named runtime slots.
        uint256[] memory slots = new uint256[](runtime.length > 5 ? 4 : 3);
        slots[0] = _layout.sourceCalls[0];
        slots[1] = _layout.sourceCalls[1];
        slots[2] = _layout.operation;
        if (slots.length > 3) slots[3] = _layout.redeem;
        for (uint256 i; i < slots.length; ++i) {
            IMerkleAccount.Action[] memory actions = abi.decode(runtime[slots[i]], (IMerkleAccount.Action[]));
            for (uint256 j; j < actions.length; ++j) {
                bytes32 leaf = _leaf(actions[j]);
                state = keccak256(
                    abi.encode(
                        state,
                        leaf,
                        MerkleAccount(payable(account)).hasRole(leaf, _executor),
                        MerkleAccount(payable(account)).hasRole(leaf, _provider),
                        MerkleAccount(payable(account)).hasRole(leaf, address(this))
                    )
                );
            }
        }
    }

    function _o13AssertSuccessEffects(
        Plan memory plan,
        LLExecuting.Layout memory layout,
        bytes memory result,
        uint256[22] memory beforeValues
    ) internal view {
        uint256[22] memory afterValues = _o13EffectValues();
        uint256 shortfall = plan.amountOut > beforeValues[0] ? plan.amountOut - beforeValues[0] : 0;
        uint256 firstAmount = shortfall < beforeValues[13] ? shortfall : beforeValues[13];
        shortfall -= firstAmount;
        uint256 secondAmount = shortfall < beforeValues[14] ? shortfall : beforeValues[14];
        uint256[] memory values = abi.decode(result, (uint256[]));
        assertEq(values[layout.sourceAmounts[0]], firstAmount);
        assertEq(values[layout.sourceAmounts[1]], secondAmount);
        assertEq(afterValues[0], beforeValues[0] + firstAmount + secondAmount - plan.amountOut);
        assertEq(afterValues[1], beforeValues[1] + plan.amountOut);
        assertEq(afterValues[2], beforeValues[2] + (plan.redeem && !_retainsRwa ? 0 : plan.amountIn));
        assertEq(afterValues[3], beforeValues[3] - plan.amountIn);
        assertEq(afterValues[4], beforeValues[4]);
        assertEq(afterValues[5], beforeValues[5] + (plan.redeem ? plan.receiptAmount : 0));
        assertEq(afterValues[6], beforeValues[6] + (plan.redeem ? plan.receiptAmount : 0));
        uint256 consumed = plan.redeem && !_retainsRwa ? plan.redeemAmount : 0;
        assertEq(afterValues[7], beforeValues[7] - consumed);
        assertEq(afterValues[8], beforeValues[8] + consumed);
        assertEq(afterValues[9], beforeValues[9] + firstAmount);
        assertEq(afterValues[10], beforeValues[10] + secondAmount);
        assertEq(afterValues[11], beforeValues[11] + (firstAmount > 0 ? 1 : 0));
        assertEq(afterValues[12], beforeValues[12] + (secondAmount > 0 ? 1 : 0));
        assertEq(afterValues[13], beforeValues[13] - firstAmount);
        assertEq(afterValues[14], beforeValues[14] - secondAmount);
        assertEq(afterValues[15], beforeValues[15] - firstAmount);
        assertEq(afterValues[16], beforeValues[16] - secondAmount);
        assertEq(afterValues[17], beforeValues[17]);
        assertEq(afterValues[18], beforeValues[18]);
        assertEq(afterValues[19], beforeValues[19]);
        assertEq(afterValues[20], beforeValues[20] + plan.amountOut);
        assertEq(afterValues[21], beforeValues[21]);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
    }

    function _o13StateHash() internal view returns (bytes32) {
        bytes32 balances = keccak256(
            abi.encode(
                IERC20(_asset).balanceOf(account),
                IERC20(_asset).balanceOf(_recipient),
                IERC20(_asset).balanceOf(_first),
                IERC20(_asset).balanceOf(_second),
                IERC20(_asset).balanceOf(_lane),
                IERC20(_asset).balanceOf(_issuer),
                IERC20(_asset).balanceOf(address(this)),
                IERC20(_asset).totalSupply(),
                IERC20(_rwa).balanceOf(account),
                IERC20(_rwa).balanceOf(_lane),
                IERC20(_rwa).balanceOf(_issuer),
                IERC20(_rwa).balanceOf(_first),
                IERC20(_rwa).balanceOf(_second),
                IERC20(_rwa).totalSupply(),
                IERC20(_issuer).balanceOf(account),
                IERC20(_issuer).totalSupply(),
                RecipeRwaToken(_rwa).redeemed()
            )
        );
        bytes32 sources = keccak256(
            abi.encode(
                RecipeLiquiditySource(_first).liquidity(),
                RecipeLiquiditySource(_first).withdrawn(),
                RecipeLiquiditySource(_first).calls(),
                RecipeLiquiditySource(_second).liquidity(),
                RecipeLiquiditySource(_second).withdrawn(),
                RecipeLiquiditySource(_second).calls(),
                RecipeLiquiditySource(_first).callbackTarget(),
                RecipeLiquiditySource(_first).callbackData(),
                RecipeLiquiditySource(_second).callbackTarget(),
                RecipeLiquiditySource(_second).callbackData()
            )
        );
        (uint256 maximum, uint48 duration, uint48 periodStart, uint256 spent) =
            LiquidLaneConnector(_lane).assetLimits(_rwa);
        bytes32 nativeState = keccak256(
            abi.encode(
                LiquidLaneConnector(_lane).signer(),
                LiquidLaneConnector(_lane).owner(),
                LiquidLaneConnector(_lane).minDiscount(_rwa),
                ILiquidLaneConnector(_lane).isUsedNonce(_rwa, 7),
                maximum,
                duration,
                periodStart,
                spent,
                LiquidLaneConnector(_lane).remainingAssets(_rwa),
                RecipeIssuerReceipt(_issuer).retainsRwa(),
                _ownerDigest,
                MerkleAccount(payable(account)).root(),
                roots.roots(account)
            )
        );
        return keccak256(
            abi.encode(
                balances,
                sources,
                nativeState,
                IERC20(_asset).allowance(account, _lane),
                IERC20(_rwa).allowance(account, _issuer),
                RecipeExecutor(_executor).caller(),
                RecipeExecutor(_executor).owner(),
                RecipeExecutor(_executor).recipeBlock()
            )
        );
    }

    function _plan() internal pure returns (Plan memory) {
        return Plan({
            amountIn: 100,
            amountOut: 90,
            firstAmount: 30,
            secondAmount: 60,
            redeemAmount: 100,
            receiptAmount: 100,
            minReceiptNumerator: 1,
            preparedFirstLiquidity: 0,
            skipLastCapacity: false,
            redeem: true
        });
    }

    function _swapData(uint256 discount, uint48 deadline, uint48 protocolDeadline, bool ownerSigns)
        internal
        returns (bytes memory)
    {
        (ILiquidLaneConnector.DiscountSwap memory quote, bytes memory signature) =
            _quote(discount, deadline, protocolDeadline, ownerSigns);
        return _encodeSwap(quote, signature);
    }

    function _quote(uint256 discount, uint48 deadline, uint48 protocolDeadline, bool ownerSigns)
        internal
        returns (ILiquidLaneConnector.DiscountSwap memory quote, bytes memory signature)
    {
        quote.discount = ILiquidLaneConnector.Discount({
            tokenToRedeem: _rwa,
            discount: discount,
            signer: ownerSigns ? address(this) : vm.addr(0xAAA),
            protocol: vm.addr(0xBBB),
            nonce: 7,
            deadline: deadline
        });
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount))));
        if (ownerSigns) _ownerDigest = digest;
        else quote.signerSignature = _sign(0xAAA, digest);
        quote.protocolDeadline = protocolDeadline;
        signature = _protocolSignature(quote);
    }

    function _protocolSignature(ILiquidLaneConnector.DiscountSwap memory quote) internal returns (bytes memory) {
        return _sign(
            0xBBB,
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    _domain(),
                    keccak256(
                        abi.encode(
                            DISCOUNT_SWAP_TYPEHASH,
                            keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount)),
                            keccak256(quote.signerSignature),
                            quote.protocolDeadline
                        )
                    )
                )
            )
        );
    }

    function _sign(uint256 key, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LiquidLaneConnector"),
                keccak256("1"),
                block.chainid,
                _lane
            )
        );
    }

    function _encodeSwap(ILiquidLaneConnector.DiscountSwap memory quote, bytes memory signature)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "swap(((address,uint256,address,address,uint256,uint48),bytes,uint48),bytes,address,uint256)",
            quote,
            signature,
            _recipient,
            uint256(100)
        );
    }

    function _prepare(Plan memory plan, bytes memory swapData) internal returns (bytes[] memory runtime) {
        return _prepare(plan, swapData, false);
    }

    function _prepare(Plan memory plan, bytes memory swapData, bool maskRecipient)
        internal
        returns (bytes[] memory runtime)
    {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](plan.redeem ? 7 : 4);
        actions[0] = _action(_first, abi.encodeCall(RecipeLiquiditySource.withdraw, (account, plan.firstAmount)), 36);
        actions[1] = _action(_second, abi.encodeCall(RecipeLiquiditySource.withdraw, (account, plan.secondAmount)), 36);
        actions[2] = _action(_asset, abi.encodeCall(IERC20.approve, (_lane, 0)), 36);
        actions[3] = _action(_lane, swapData, swapData.length);
        _maskDiscountSwap(actions[3]);
        if (maskRecipient) _mask(actions[3].dataMask, 68, 100);
        if (plan.redeem) {
            actions[4] = _action(_rwa, abi.encodeCall(IERC20.approve, (_issuer, 0)), 36);
            actions[5] = _action(
                _issuer, abi.encodeCall(RecipeIssuerReceipt.redeem, (plan.redeemAmount / 2, plan.receiptAmount / 2)), 4
            );
            actions[6] = _action(
                _issuer,
                abi.encodeCall(
                    RecipeIssuerReceipt.redeem,
                    (plan.redeemAmount - plan.redeemAmount / 2, plan.receiptAmount - plan.receiptAmount / 2)
                ),
                4
            );
        }
        _publish(actions);
        LLExecuting.Config memory config;
        config.funding = ExecutingRecipe.Funding({
            adapter: address(adapter),
            account: account,
            pushLeaf: bytes32(0),
            asset: _asset,
            skipUnusedReads: _skipUnusedReads,
            sources: new ExecutingRecipe.Source[](2)
        });
        for (uint256 i; i < 2; ++i) {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = _leaf(actions[i]);
            config.funding.sources[i] = ExecutingRecipe.Source({
                prepare: ExecutingRecipe.Call({target: address(0), data: ""}),
                capacity: ExecutingRecipe.Read({
                    target: actions[i].target, data: abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), offset: 0
                }),
                leaves: leaves,
                amountOffsets: _sourceOffsets()
            });
        }
        if (plan.preparedFirstLiquidity > 0) {
            config.funding.sources[0].prepare = ExecutingRecipe.Call({
                target: _first, data: abi.encodeCall(RecipeLiquiditySource.setLiquidity, (plan.preparedFirstLiquidity))
            });
        }
        if (plan.skipLastCapacity) {
            config.funding.sources[1].capacity = ExecutingRecipe.Read({target: address(0), data: "", offset: 0});
        }
        config.skipZeroApprovals = _skipZeroApprovals;
        config.connector = _lane;
        config.rwa = _rwa;
        config.recipient = _recipient;
        config.approvalLeaf = _leaf(actions[2]);
        config.swapLeaf = _leaf(actions[3]);
        config.maxAmountIn = 1000;
        config.maxFundingAmount = 1000;
        if (plan.redeem) {
            bytes32[] memory leaves = new bytes32[](2);
            leaves[0] = _leaf(actions[5]);
            leaves[1] = _leaf(actions[6]);
            config.redemption = LLExecuting.Redemption({
                spender: _issuer,
                approvalLeaf: _leaf(actions[4]),
                leaves: leaves,
                amountOffsets: new uint256[][](0),
                retainsRwa: _retainsRwa,
                receipt: ExecutingRecipe.Read({
                    target: _issuer, data: abi.encodeCall(IERC20.balanceOf, (account)), offset: 0
                }),
                minReceiptNumerator: plan.minReceiptNumerator,
                receiptDenominator: _receiptDenominator
            });
        }
        (ExecutingRecipe.Recipe memory recipe, LLExecuting.Layout memory layout) = this.buildRecipe(config);
        _layout = layout;
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        runtime = new bytes[](ExecutingRecipe.runtimeSteps(recipe).length);
        for (uint256 i; i < 2; ++i) {
            IMerkleAccount.Action[] memory group = new IMerkleAccount.Action[](1);
            group[0] = actions[i];
            runtime[layout.sourceCalls[i]] = abi.encode(group);
        }
        runtime[layout.approve] = abi.encode(actions[2].dataMask, actions[2].proof);
        runtime[layout.clearApproval] = runtime[layout.approve];
        IMerkleAccount.Action[] memory swap = new IMerkleAccount.Action[](1);
        swap[0] = actions[3];
        runtime[layout.operation] = abi.encode(swap);
        if (plan.redeem) {
            runtime[layout.redeemApprove] = abi.encode(actions[4].dataMask, actions[4].proof);
            runtime[layout.redeemClearApproval] = runtime[layout.redeemApprove];
            IMerkleAccount.Action[] memory posts = new IMerkleAccount.Action[](2);
            posts[0] = actions[5];
            posts[1] = actions[6];
            runtime[layout.redeem] = abi.encode(posts);
        }
        uint256 preparationCalls;
        for (uint256 i; i < recipe.steps.length; ++i) {
            if (uint8(recipe.steps[i][0]) == OP_CALL) ++preparationCalls;
        }
        assertEq(preparationCalls, plan.preparedFirstLiquidity > 0 ? 1 : 0);
    }

    function _sourceOffsets() internal pure returns (uint256[][] memory offsets) {
        offsets = new uint256[][](1);
        offsets[0] = new uint256[](1);
        offsets[0][0] = 36;
    }

    function _publish(IMerkleAccount.Action[] memory actions) internal {
        uint256 width = actions.length > 4 ? 8 : 4;
        bytes32[] memory tree = new bytes32[](width * 2);
        for (uint256 i; i < actions.length; ++i) {
            tree[width + i] = _leaf(actions[i]);
            MerkleAccount(payable(account)).grantRole(tree[width + i], _executor);
        }
        for (uint256 i = width - 1; i > 0; --i) {
            bytes32 a = tree[i * 2];
            bytes32 b = tree[i * 2 + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        for (uint256 i; i < actions.length; ++i) {
            actions[i].proof = new bytes32[](width == 8 ? 3 : 2);
            uint256 index = width + i;
            for (uint256 j; j < actions[i].proof.length; ++j) {
                actions[i].proof[j] = tree[index ^ 1];
                index /= 2;
            }
        }
        roots.setRoot(account, tree[1]);
        MerkleAccount(payable(account)).acceptRoot(tree[1]);
    }

    function _action(address target, bytes memory data, uint256 maskStart)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = IMerkleAccount.Action({
            target: target, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
        for (uint256 i = maskStart; i < data.length; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _leaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _maskDiscountSwap(IMerkleAccount.Action memory action) internal pure {
        uint256 tuple = 4 + _word(action.data, 4);
        _mask(action.dataMask, 100, 132);
        _mask(action.dataMask, tuple + 32, tuple + 64);
        _mask(action.dataMask, tuple + 128, tuple + 192);
        _mask(action.dataMask, tuple + 224, tuple + 256);
        uint256 signature = tuple + _word(action.data, tuple + 192);
        _mask(action.dataMask, signature + 32, signature + 32 + _word(action.data, signature));
        signature = 4 + _word(action.data, 36);
        _mask(action.dataMask, signature + 32, signature + 32 + _word(action.data, signature));
    }

    function _mask(bytes memory mask, uint256 start, uint256 end) internal pure {
        for (uint256 i = start; i < end; ++i) {
            mask[i] = 0xff;
        }
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := mload(add(add(data, 32), offset))
        }
    }

    function _run(Plan memory plan, bytes memory swapData) internal returns (uint256[] memory) {
        return _execute(plan, _prepare(plan, swapData));
    }

    function _execute(Plan memory plan, bytes[] memory runtime) internal returns (uint256[] memory) {
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = plan.amountIn;
        inputs[1] = plan.amountOut;
        vm.prank(_provider);
        return RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
    }

    function _seedExistingBalances() internal {
        IERC20(_rwa).approve(_issuer, 25);
        RecipeIssuerReceipt(_issuer).redeem(25, 40);
        IERC20(_issuer).transfer(account, 40);
        IERC20(_rwa).transfer(account, 50);
        IERC20(_asset).transfer(account, 20);
    }

    function _assertExistingBalancesAfterRollback() internal view {
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 20);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).balanceOf(_lane), 1_000_000);
        assertEq(IERC20(_rwa).balanceOf(account), 50);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
        assertEq(IERC20(_issuer).balanceOf(account), 40);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 25);
    }

    function _assertRollback() internal view {
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_asset).allowance(account, _lane), 0);
        assertEq(IERC20(_rwa).balanceOf(_lane), 1_000_000);
        assertEq(IERC20(_rwa).balanceOf(account), 0);
        assertEq(IERC20(_rwa).allowance(account, _issuer), 0);
        assertEq(IERC20(_issuer).balanceOf(account), 0);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {RecipeLiquiditySource} from "./mocks/RecipeMocks.sol";
import {RecipeRwaToken} from "./mocks/RecipeMocks.sol";
import {ActionOracleMock} from "./LiquidLaneConnector.t.sol";
import {MerkleAdapterDelegatorMock, MerkleAdapterVaultMock} from "../MerkleAdapter.t.sol";
import {RecipeIssuerReceipt} from "./mocks/RecipeMocks.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/oracle/OracleRegistry.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {Token} from "test/mocks/Token.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LLExecuting} from "script/recipes/LLExecuting.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {DISCOUNT_SWAP_TYPEHASH, DISCOUNT_TYPEHASH, ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {ILiquidLaneConnector} from "src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract LLExecutingTest is CapabilityTestBase {
    struct Plan {
        uint256 amountIn;
        uint256 amountOut;
        uint256 firstAmount;
        uint256 secondAmount;
        uint256 redeemAmount;
        uint256 receiptAmount;
        uint256 maxReceiptBalance;
        uint256 minReceiptNumerator;
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
        _executor = address(new RecipeExecutor(address(this), address(adapter)));
        RecipeExecutor(_executor).setCaller(_provider);
        address registry = address(new OracleRegistry(address(this)));
        address prices = address(new MigratablesFactory(address(this)));
        MigratablesFactory(prices).whitelist(address(new ActionOracleMock(prices, 1e18)));
        address lanes = address(new MigratablesFactory(address(this)));
        MigratablesFactory(lanes).whitelist(address(new LiquidLaneConnector(lanes, registry)));
        _lane =
            MigratablesFactory(lanes).create(1, address(this), abi.encode(address(adapter), _asset, new address[](0)));
        OracleRegistry(registry)
            .setOracle(_lane, _rwa, MigratablesFactory(prices).create(1, address(this), abi.encode(_asset, _lane)));
        _manage(_lane, abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (_rwa)));
        _manage(_lane, abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (_rwa, type(uint256).max, 1 days)));
        IERC20(_rwa).transfer(_lane, 1_000_000);
        _issuer = address(new RecipeIssuerReceipt(_rwa));
        _first = address(new RecipeLiquiditySource(IERC20(_asset), address(adapter)));
        _second = address(new RecipeLiquiditySource(IERC20(_asset), address(adapter)));
        IERC20(_asset).transfer(_first, 1_000_000);
        IERC20(_asset).transfer(_second, 1_000_000);
        RecipeLiquiditySource(_first).setLiquidity(30);
        RecipeLiquiditySource(_second).setLiquidity(1_000_000);
        LiquidLaneConnector(_lane).setSigner(vm.addr(0xAAA));
        LiquidLaneConnector(_lane).setMinDiscount(_rwa, 100_000);
    }

    function test_FundsDiscountedSwapAndRedeemsInTwoCallsWithoutTypedExecutor() public {
        uint256[] memory values = _run(_plan(), _swapData(100_000, type(uint48).max, type(uint48).max, false));
        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(values[_layout.sourceAmounts[1]], 60);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 100);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 100);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
        assertEq(IERC20(_rwa).allowance(address(adapter), _issuer), 0);
    }

    function test_SwapAmountAndSourceAmountsAreInsertedBeforeExecution() public {
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = type(uint256).max;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
        bytes memory data = actions[0].data;
        assembly ("memory-safe") { mstore(add(data, 132), 777) }
        runtime[_layout.operation] = abi.encode(actions);
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 100);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
    }

    function test_PreservesOldRwaAndUsesIdleFundingFirst() public {
        IERC20(_rwa).transfer(address(adapter), 50);
        IERC20(_asset).transfer(address(adapter), 20);
        Plan memory plan = _plan();
        plan.secondAmount = 40;
        _run(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 40);
    }

    function test_EmptyPostActionListRetainsAcquiredRwa() public {
        Plan memory plan = _plan();
        plan.redeem = false;
        _run(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 100);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 0);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 0);
        assertEq(IERC20(_rwa).allowance(address(adapter), _issuer), 0);
    }

    function test_FullDiscountNeedsNoFundingAndStillReceivesAndRedeemsRwa() public {
        Plan memory plan = _plan();
        plan.amountOut = 0;
        plan.firstAmount = 0;
        plan.secondAmount = 0;
        _run(plan, _swapData(1_000_000, type(uint48).max, type(uint48).max, false));
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 100);
    }

    function test_RwaAmountCapFailsBeforeFunding() public {
        Plan memory plan = _plan();
        plan.amountIn = 1001;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_FundingCapFailsBeforeFunding() public {
        Plan memory plan = _plan();
        plan.amountOut = 1001;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ERC1271OwnerCanSignAlongsideDelegatedSigner() public {
        _run(_plan(), _swapData(100_000, type(uint48).max, type(uint48).max, true));
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 100);
    }

    function test_ReusableDiscountCanFillAgainUntilInvalidated() public {
        bytes memory swapData = _swapData(100_000, type(uint48).max, type(uint48).max, false);
        _run(_plan(), swapData);
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = 90;
        _run(plan, swapData);
        assertEq(IERC20(_asset).balanceOf(_recipient), 180);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 200);
        assertFalse(ILiquidLaneConnector(_lane).isUsedNonce(_rwa, 7));
    }

    function test_RefreshesSignedQuoteWithoutChangingStoredRecipeRootOrProofs() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        bytes32 root = adapter.merkleRoot();
        _execute(plan, runtime);

        (ILiquidLaneAdapter.DiscountSwap memory quote,) =
            _quote(200_000, uint48(block.timestamp + 1 days), uint48(block.timestamp + 10 minutes), false);
        quote.discount.nonce = 8;
        quote.signerSignature = _sign(
            0xAAA,
            keccak256(abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount))))
        );
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
        bytes32 leaf = _leaf(actions[0]);
        actions[0].data = _encodeSwap(quote, _protocolSignature(quote));
        assertEq(_leaf(actions[0]), leaf);
        runtime[_layout.operation] = abi.encode(actions);
        actions = abi.decode(runtime[_layout.sourceCalls[1]], (IMerkleAdapter.Action[]));
        actions[0].data = abi.encodeCall(RecipeLiquiditySource.withdraw, (address(adapter), 80));
        runtime[_layout.sourceCalls[1]] = abi.encode(actions);
        plan.amountOut = 80;

        _execute(plan, runtime);
        assertEq(adapter.merkleRoot(), root);
        assertEq(IERC20(_asset).balanceOf(_recipient), 170);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 200);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 140);
    }

    function testFuzz_ReusableSignedLeafPinsPolicyAndDynamicStructure(uint8 field) public {
        field = uint8(bound(field, 0, 8));
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
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

    function test_SwapRequiresAdapterEvenFromOwner() public {
        (ILiquidLaneAdapter.DiscountSwap memory quote, bytes memory signature) =
            _quote(100_000, type(uint48).max, type(uint48).max, false);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        ILiquidLaneConnector(_lane).swap(quote, signature, _recipient, 100);
    }

    function test_ValidSignatureFromUnapprovedSignerCannotExecute() public {
        (ILiquidLaneAdapter.DiscountSwap memory quote,) = _quote(100_000, type(uint48).max, type(uint48).max, false);
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
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(bytes4(keccak256("AlreadyUsedNonce()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ExpiredDiscountRollsBackFundingAndApproval() public {
        Plan memory plan = _plan();
        bytes[] memory runtime =
            _prepare(plan, _swapData(100_000, uint48(block.timestamp - 1), type(uint48).max, false));
        vm.expectRevert(bytes4(keccak256("ExpiredSwap()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ExpiredProtocolAuthorizationRollsBackFunding() public {
        Plan memory plan = _plan();
        bytes[] memory runtime =
            _prepare(plan, _swapData(100_000, type(uint48).max, uint48(block.timestamp - 1), false));
        vm.expectRevert(bytes4(keccak256("ExpiredSwap()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_DiscountBelowPinnedMinimumCannotExecute() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(99_999, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(bytes4(keccak256("InvalidDiscount()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_InvalidProtocolSignatureCannotExecute() public {
        (ILiquidLaneAdapter.DiscountSwap memory quote, bytes memory protocolSignature) =
            _quote(100_000, type(uint48).max, type(uint48).max, false);
        protocolSignature[0] ^= 0x01;
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _encodeSwap(quote, protocolSignature));
        vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_InvalidSignerSignatureCannotExecute() public {
        (ILiquidLaneAdapter.DiscountSwap memory quote,) = _quote(100_000, type(uint48).max, type(uint48).max, false);
        quote.signerSignature[0] ^= 0x01;
        bytes memory protocolSignature = _protocolSignature(quote);
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _encodeSwap(quote, protocolSignature));
        vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ValidSignaturesFromWrongDomainCannotExecute() public {
        (ILiquidLaneAdapter.DiscountSwap memory quote,) = _quote(100_000, type(uint48).max, type(uint48).max, false);
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
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_InputSetsSwapSizeDespiteDifferentTemplateAmount() public {
        Plan memory plan = _plan();
        plan.amountIn = 101;
        plan.redeemAmount = 101;
        plan.receiptAmount = 101;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 101);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 101);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
    }

    function test_ReservesAreNotUsedToPayRecipient() public {
        IERC20(_asset).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        _run(_plan(), _swapData(100_000, type(uint48).max, type(uint48).max, false));
        assertEq(adapter.reservedAssets(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
    }

    function test_ZeroCapacitySourceIsSkipped() public {
        RecipeLiquiditySource(_first).setLiquidity(0);
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = 90;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        runtime[_layout.sourceCalls[0]] = "";
        _execute(plan, runtime);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 90);
    }

    function test_MissingRedemptionActionRollsBackSwapAndSources() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        runtime[_layout.redeem] = abi.encode(new IMerkleAdapter.Action[](0));
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ExactRwaDisposalIsRequiredEvenWithEnoughReceipts() public {
        Plan memory plan = _plan();
        plan.redeemAmount = 99;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_TooFewRedemptionReceiptsRollsBackEntirePlan() public {
        Plan memory plan = _plan();
        plan.receiptAmount = 99;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ZeroReceiptsAreRejectedEvenWithZeroMinimumRate() public {
        Plan memory plan = _plan();
        plan.receiptAmount = 0;
        plan.minReceiptNumerator = 0;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ReceiptExposureLimitIncludesEarlierExecutions() public {
        _run(_plan(), _swapData(100_000, type(uint48).max, type(uint48).max, false));
        Plan memory plan = _plan();
        plan.firstAmount = 0;
        plan.secondAmount = 90;
        plan.maxReceiptBalance = 150;
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(plan, runtime);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 100);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 60);
    }

    function test_InvalidPostActionProofRollsBackSourcesAndSwap() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.redeem], (IMerkleAdapter.Action[]));
        actions[1].proof[0] ^= bytes32(uint256(1));
        runtime[_layout.redeem] = abi.encode(actions);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(plan, runtime);
        _assertRollback();
    }

    function test_ProviderCannotExecuteWithoutRecipeLeafRole() public {
        Plan memory plan = _plan();
        bytes[] memory runtime = _prepare(plan, _swapData(100_000, type(uint48).max, type(uint48).max, false));
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
        bytes32 leaf = _leaf(actions[0]);
        adapter.revokeRole(leaf, _executor);
        adapter.grantRole(leaf, _provider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        _execute(plan, runtime);
        _assertRollback();
    }

    function isValidSignature(bytes32 digest, bytes memory) public view returns (bytes4) {
        return digest == _ownerDigest ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function _plan() internal pure returns (Plan memory) {
        return Plan(100, 90, 30, 60, 100, 100, 1000, 1, true);
    }

    function _swapData(uint256 discount, uint48 deadline, uint48 protocolDeadline, bool ownerSigns)
        internal
        returns (bytes memory)
    {
        (ILiquidLaneAdapter.DiscountSwap memory quote, bytes memory signature) =
            _quote(discount, deadline, protocolDeadline, ownerSigns);
        return _encodeSwap(quote, signature);
    }

    function _quote(uint256 discount, uint48 deadline, uint48 protocolDeadline, bool ownerSigns)
        internal
        returns (ILiquidLaneAdapter.DiscountSwap memory quote, bytes memory signature)
    {
        quote.discount = ILiquidLaneAdapter.Discount(
            _rwa, discount, ownerSigns ? address(this) : vm.addr(0xAAA), vm.addr(0xBBB), 7, deadline
        );
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount))));
        if (ownerSigns) _ownerDigest = digest;
        else quote.signerSignature = _sign(0xAAA, digest);
        quote.protocolDeadline = protocolDeadline;
        signature = _protocolSignature(quote);
    }

    function _protocolSignature(ILiquidLaneAdapter.DiscountSwap memory quote) internal returns (bytes memory) {
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

    function _encodeSwap(ILiquidLaneAdapter.DiscountSwap memory quote, bytes memory signature)
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
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](plan.redeem ? 7 : 4);
        actions[0] =
            _action(_first, abi.encodeCall(RecipeLiquiditySource.withdraw, (address(adapter), plan.firstAmount)), 36);
        actions[1] =
            _action(_second, abi.encodeCall(RecipeLiquiditySource.withdraw, (address(adapter), plan.secondAmount)), 36);
        actions[2] = _action(_asset, abi.encodeCall(IERC20.approve, (_lane, 0)), 36);
        actions[3] = _action(_lane, swapData, swapData.length);
        _maskSignedSwap(actions[3]);
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
        config.funding = ExecutingRecipe.Funding(address(adapter), _asset, new ExecutingRecipe.Source[](2));
        for (uint256 i; i < 2; ++i) {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = _leaf(actions[i]);
            config.funding.sources[i] = ExecutingRecipe.Source(
                ExecutingRecipe.Read(actions[i].target, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), 0),
                leaves,
                _sourceOffsets()
            );
        }
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
            config.redemption = LLExecuting.Redemption(
                _issuer,
                _leaf(actions[4]),
                leaves,
                ExecutingRecipe.Read(_issuer, abi.encodeCall(IERC20.balanceOf, (address(adapter))), 0),
                plan.minReceiptNumerator,
                1,
                plan.maxReceiptBalance
            );
        }
        (IRecipeExecutor.Step[] memory recipe, LLExecuting.Layout memory layout) = LLExecuting.build(config);
        _layout = layout;
        RecipeExecutor(_executor).setRecipe(recipe);
        runtime = new bytes[](recipe.length);
        for (uint256 i; i < 2; ++i) {
            IMerkleAdapter.Action[] memory group = new IMerkleAdapter.Action[](1);
            group[0] = actions[i];
            runtime[layout.sourceCalls[i]] = abi.encode(group);
        }
        runtime[layout.approve] = abi.encode(IRecipeExecutor.Permission(actions[2].dataMask, actions[2].proof));
        runtime[layout.clearApproval] = runtime[layout.approve];
        IMerkleAdapter.Action[] memory swap = new IMerkleAdapter.Action[](1);
        swap[0] = actions[3];
        runtime[layout.operation] = abi.encode(swap);
        if (plan.redeem) {
            runtime[layout.redeemApprove] =
                abi.encode(IRecipeExecutor.Permission(actions[4].dataMask, actions[4].proof));
            runtime[layout.redeemClearApproval] = runtime[layout.redeemApprove];
            IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
            posts[0] = actions[5];
            posts[1] = actions[6];
            runtime[layout.redeem] = abi.encode(posts);
        }
        for (uint256 i; i < recipe.length; ++i) {
            assertTrue(recipe[i].kind != IRecipeExecutor.Kind.Invoke);
        }
    }

    function _sourceOffsets() internal pure returns (uint256[][] memory offsets) {
        offsets = new uint256[][](1);
        offsets[0] = new uint256[](1);
        offsets[0][0] = 36;
    }

    function _publish(IMerkleAdapter.Action[] memory actions) internal {
        uint256 width = actions.length > 4 ? 8 : 4;
        bytes32[] memory tree = new bytes32[](width * 2);
        for (uint256 i; i < actions.length; ++i) {
            tree[width + i] = _leaf(actions[i]);
            adapter.grantRole(tree[width + i], _executor);
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
        roots.setRoot(address(adapter), tree[1]);
        adapter.acceptRoot(tree[1]);
    }

    function _action(address target, bytes memory data, uint256 maskStart)
        internal
        pure
        returns (IMerkleAdapter.Action memory action)
    {
        action = IMerkleAdapter.Action(target, 0, data, new bytes(data.length), new bytes32[](0));
        for (uint256 i = maskStart; i < data.length; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _maskSignedSwap(IMerkleAdapter.Action memory action) internal pure {
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
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = plan.amountIn;
        inputs[1] = plan.amountOut;
        vm.prank(_provider);
        return RecipeExecutor(_executor).execute(inputs, runtime);
    }

    function _assertRollback() internal view {
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
        assertEq(IERC20(_rwa).balanceOf(_lane), 1_000_000);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_rwa).allowance(address(adapter), _issuer), 0);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 0);
        assertEq(RecipeRwaToken(_rwa).redeemed(), 0);
    }
}

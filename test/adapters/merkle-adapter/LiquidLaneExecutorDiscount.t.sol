// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ExecutorLiquiditySource} from "./Executor.t.sol";
import {ActionOracleMock} from "./LiquidLaneConnector.t.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/LiquidLaneConnector.sol";
import {LiquidLaneExecutor} from "src/contracts/periphery/LiquidLaneExecutor.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/OracleRegistry.sol";
import {Token} from "test/mocks/Token.sol";

import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IExecutor} from "src/interfaces/periphery/IExecutor.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {ILiquidLaneConnector} from "src/interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {ILiquidLaneExecutor} from "src/interfaces/periphery/ILiquidLaneExecutor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

contract LiquidLaneExecutorDiscountTest is CapabilityTestBase {
    address internal _asset;
    address internal _rwa;
    address internal _lane;
    address internal _executor;
    address internal _recipient = makeAddr("recipient");
    address internal _signer;
    address internal _protocol;
    uint256 internal _signerKey;
    uint256 internal _protocolKey;

    function setUp() public {
        (_signer, _signerKey) = makeAddrAndKey("discount signer");
        (_protocol, _protocolKey) = makeAddrAndKey("protocol signer");
        _asset = address(new Token("Funding"));
        _rwa = address(new Token("RWA"));
        _deployAdapter(_asset);

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
        IERC20(_asset).transfer(address(adapter), 1_000_000);

        _executor = address(new LiquidLaneExecutor(address(this), address(adapter), _lane));
        LiquidLaneExecutor(_executor).setCaller(address(this));
        LiquidLaneExecutor(_executor).setSigner(_signer);
    }

    function test_SignedDiscountPaysComputedOutputFromAdapterAndKeepsRwaAtAdapter() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        uint256 amountOut = _swap(discountSwap, protocolSignature);
        assertEq(amountOut, 995);
        assertEq(IERC20(_asset).balanceOf(_recipient), 995);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 999_005);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 1000);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
        assertEq(IERC20(_asset).balanceOf(_executor), 0);
        assertEq(IERC20(_rwa).balanceOf(_executor), 0);
    }

    function test_DiscountCanFillRepeatedlyUntilInvalidated() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        _swap(discountSwap, protocolSignature);
        _swap(discountSwap, protocolSignature);
        assertEq(IERC20(_asset).balanceOf(_recipient), 1990);
        assertFalse(LiquidLaneExecutor(_executor).isUsedNonce(_rwa, 17));

        LiquidLaneExecutor(_executor).invalidateNonce(_rwa, 17);
        IExecutor.Execution memory execution = _execution();
        vm.expectRevert(ILiquidLaneExecutor.AlreadyUsedNonce.selector);
        LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, execution, new IMerkleAdapter.Action[](0));
        assertEq(IERC20(_asset).balanceOf(_recipient), 1990);
    }

    function test_ConfiguredSignerCanInvalidateDiscount() public {
        vm.prank(_signer);
        LiquidLaneExecutor(_executor).invalidateNonce(_rwa, 17);
        assertTrue(LiquidLaneExecutor(_executor).isUsedNonce(_rwa, 17));
        assertFalse(LiquidLaneExecutor(_executor).isUsedNonce(_asset, 17));
    }

    function test_CallerCannotInvalidateDiscount() public {
        address stranger = makeAddr("stranger");
        LiquidLaneExecutor(_executor).setCaller(stranger);
        vm.prank(stranger);
        vm.expectRevert(IExecutor.InvalidCaller.selector);
        LiquidLaneExecutor(_executor).invalidateNonce(_rwa, 17);
    }

    function test_OwnerCanSignAlongsideConfiguredSigner() public {
        (address curator, uint256 curatorKey) = makeAddrAndKey("curator");
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap,) = _signed(5000);
        discountSwap.discount.signer = curator;
        discountSwap.signerSignature = _sign(curatorKey, _discountDigest(discountSwap, _executor));
        bytes memory protocolSignature = _sign(_protocolKey, _protocolDigest(discountSwap, _executor));
        IExecutor.Execution memory execution = _execution();
        LiquidLaneExecutor(_executor).transferOwnership(curator);
        LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, execution, new IMerkleAdapter.Action[](0));
        assertEq(IERC20(_asset).balanceOf(_recipient), 995);
    }

    function test_SignerReplacementRevokesPriorDiscounts() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        LiquidLaneExecutor(_executor).setSigner(makeAddr("replacement signer"));
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidAccount.selector);
    }

    function test_ClearingSignerRevokesItsDiscounts() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        LiquidLaneExecutor(_executor).setSigner(address(0));
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidAccount.selector);
    }

    function test_RejectsForgedDiscountEvenWithValidProtocolSignature() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap,) = _signed(5000);
        discountSwap.signerSignature = _sign(_protocolKey, _discountDigest(discountSwap, _executor));
        bytes memory protocolSignature = _sign(_protocolKey, _protocolDigest(discountSwap, _executor));
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidSignature.selector);
    }

    function test_RejectsForgedProtocolCountersignature() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap,) = _signed(5000);
        bytes memory protocolSignature = _sign(_signerKey, _protocolDigest(discountSwap, _executor));
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidSignature.selector);
    }

    function test_RejectsSignaturesForAnotherExecutor() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap,) = _signed(5000);
        address otherExecutor = makeAddr("other executor");
        discountSwap.signerSignature = _sign(_signerKey, _discountDigest(discountSwap, otherExecutor));
        bytes memory protocolSignature = _sign(_protocolKey, _protocolDigest(discountSwap, otherExecutor));
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidSignature.selector);
    }

    function test_RejectsSignaturesForAnotherChain() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        vm.chainId(block.chainid + 1);
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidSignature.selector);
    }

    function test_RejectsProtocolDeadlineMutation() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        ++discountSwap.protocolDeadline;
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidSignature.selector);
    }

    function test_RejectsExpiredProtocolSignature() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        vm.warp(uint256(discountSwap.protocolDeadline) + 1);
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.ExpiredSwap.selector);
    }

    function test_RejectsExpiredDiscount() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap,) = _signed(5000);
        discountSwap.protocolDeadline = discountSwap.discount.deadline + 30;
        bytes memory protocolSignature = _sign(_protocolKey, _protocolDigest(discountSwap, _executor));
        vm.warp(uint256(discountSwap.discount.deadline) + 1);
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.ExpiredSwap.selector);
    }

    function test_DeadlineIsInclusive() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        vm.warp(discountSwap.protocolDeadline);
        _swap(discountSwap, protocolSignature);
        assertEq(IERC20(_asset).balanceOf(_recipient), 995);
    }

    function test_MinDiscountFloorIsEnforcedAtFill() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);
        LiquidLaneExecutor(_executor).setMinDiscount(_rwa, 5001);
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidDiscount.selector);
        LiquidLaneExecutor(_executor).setMinDiscount(_rwa, 5000);
        _swap(discountSwap, protocolSignature);
        assertEq(IERC20(_asset).balanceOf(_recipient), 995);
    }

    function test_DiscountAbovePrecisionIsRejected() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(1_000_001);
        _expectSwapRevert(discountSwap, protocolSignature, ILiquidLaneExecutor.InvalidDiscount.selector);
    }

    function test_MinDiscountAbovePrecisionIsRejectedWithoutChangingFloor() public {
        LiquidLaneExecutor(_executor).setMinDiscount(_rwa, 5000);
        vm.expectRevert(ILiquidLaneExecutor.InvalidDiscount.selector);
        LiquidLaneExecutor(_executor).setMinDiscount(_rwa, 1_000_001);
        assertEq(LiquidLaneExecutor(_executor).minDiscount(_rwa), 5000);
    }

    function testFuzz_DiscountPaysRoundedDownPpmQuote(uint256 ppm) public {
        ppm = bound(ppm, 0, 1_000_000);
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(ppm);
        uint256 amountOut = _swap(discountSwap, protocolSignature);
        assertEq(amountOut, (1000 * (1_000_000 - ppm)) / 1_000_000);
        assertEq(IERC20(_asset).balanceOf(_recipient), amountOut);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 1_000_000 - amountOut);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 1000);
    }

    function test_FullDiscountNeedsNoFundingAndTransfersRwa() public {
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(1_000_000);
        assertEq(_swap(discountSwap, protocolSignature), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 1_000_000);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 1000);
    }

    function test_OnlyOwnerCanChangeSignerAndDiscountFloor() public {
        vm.startPrank(_signer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _signer));
        LiquidLaneExecutor(_executor).setSigner(_protocol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _signer));
        LiquidLaneExecutor(_executor).setMinDiscount(_rwa, 5000);
        vm.stopPrank();
    }

    function test_SupportsErc1271DiscountAndProtocolSigners() public {
        address contractSigner = address(new LiquidLaneDiscountSignatureMock());
        address contractProtocol = address(new LiquidLaneDiscountSignatureMock());
        LiquidLaneExecutor(_executor).setSigner(contractSigner);
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap,) = _signed(5000);
        discountSwap.discount.signer = contractSigner;
        discountSwap.discount.protocol = contractProtocol;
        discountSwap.signerSignature = hex"1234";
        bytes memory protocolSignature = hex"5678";
        LiquidLaneDiscountSignatureMock(contractSigner)
            .setSignature(_discountDigest(discountSwap, _executor), discountSwap.signerSignature);
        LiquidLaneDiscountSignatureMock(contractProtocol)
            .setSignature(_protocolDigest(discountSwap, _executor), protocolSignature);
        _swap(discountSwap, protocolSignature);
        assertEq(IERC20(_asset).balanceOf(_recipient), 995);
    }

    function test_OracleUpgradeDuringFundingRollsBackQuoteApprovalAndWithdrawal() public {
        address oracle = LiquidLaneConnector(_lane).oracles(_rwa);
        address factory = ActionOracleMock(oracle).FACTORY();
        MigratablesFactory(factory).whitelist(address(new ActionOracleMock(factory, 2e18)));
        (address source, IExecutor.Execution memory execution) =
            _fundingExecution(factory, abi.encodeCall(IMigratablesFactory.migrate, (oracle, uint64(2), bytes(""))));
        ActionOracleMock(oracle).transferOwnership(source);
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);

        vm.expectRevert(ILiquidLaneExecutor.OperationChanged.selector);
        LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, execution, new IMerkleAdapter.Action[](0));

        assertEq(ActionOracleMock(oracle).version(), 1);
        assertEq(LiquidLaneConnector(_lane).getAmountOut(_rwa, 1000), 1000);
        _assertFundingRollback(source);
    }

    function test_InputAssetChangeDuringFundingRollsBackApprovalAndWithdrawal() public {
        address factory = LiquidLaneConnector(_lane).FACTORY();
        MigratablesFactory(factory)
            .whitelist(
                address(new LiquidLaneMutableInputConnector(factory, LiquidLaneConnector(_lane).ORACLE_REGISTRY()))
            );
        MigratablesFactory(factory).migrate(_lane, 2, "");
        address otherAsset = address(new Token("Other funding"));
        (address source, IExecutor.Execution memory execution) =
            _fundingExecution(_lane, abi.encodeCall(LiquidLaneMutableInputConnector.setInputAsset, (otherAsset)));
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);

        vm.expectRevert(ILiquidLaneExecutor.OperationChanged.selector);
        LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, execution, new IMerkleAdapter.Action[](0));

        assertEq(LiquidLaneConnector(_lane).inputAsset(), _asset);
        _assertFundingRollback(source);
    }

    function testFuzz_OwnerFundingCallbackCannotChangeDiscountPolicy(uint8 operation) public {
        operation = uint8(bound(operation, 0, 2));
        bytes memory callbackData;
        if (operation == 0) {
            callbackData = abi.encodeCall(ILiquidLaneExecutor.setSigner, (_protocol));
        } else if (operation == 1) {
            callbackData = abi.encodeCall(ILiquidLaneExecutor.setMinDiscount, (_rwa, uint256(5001)));
        } else {
            callbackData = abi.encodeCall(ILiquidLaneExecutor.invalidateNonce, (_rwa, uint256(17)));
        }
        (address source, IExecutor.Execution memory execution) = _fundingExecution(_executor, callbackData);
        LiquidLaneExecutor(_executor).transferOwnership(source);
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature) = _signed(5000);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, execution, new IMerkleAdapter.Action[](0));

        assertEq(LiquidLaneExecutor(_executor).signer(), _signer);
        assertEq(LiquidLaneExecutor(_executor).minDiscount(_rwa), 0);
        assertFalse(LiquidLaneExecutor(_executor).isUsedNonce(_rwa, 17));
        _assertFundingRollback(source);
    }

    function test_ConfiguredSignerFundingCallbackCannotInvalidateDiscount() public {
        (address source, IExecutor.Execution memory execution) =
            _fundingExecution(_executor, abi.encodeCall(ILiquidLaneExecutor.invalidateNonce, (_rwa, uint256(17))));
        (address curator, uint256 curatorKey) = makeAddrAndKey("callback curator");
        (ILiquidLaneAdapter.DiscountSwap memory discountSwap,) = _signed(5000);
        discountSwap.discount.signer = curator;
        discountSwap.signerSignature = _sign(curatorKey, _discountDigest(discountSwap, _executor));
        bytes memory protocolSignature = _sign(_protocolKey, _protocolDigest(discountSwap, _executor));
        LiquidLaneExecutor(_executor).setSigner(source);
        LiquidLaneExecutor(_executor).transferOwnership(curator);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, execution, new IMerkleAdapter.Action[](0));

        assertFalse(LiquidLaneExecutor(_executor).isUsedNonce(_rwa, 17));
        _assertFundingRollback(source);
    }

    function _fundingExecution(address callbackTarget, bytes memory callbackData)
        internal
        returns (address source, IExecutor.Execution memory execution)
    {
        source = address(new ExecutorLiquiditySource(IERC20(_asset), address(adapter)));
        vm.prank(address(adapter));
        IERC20(_asset).transfer(source, 1_000_000);
        ExecutorLiquiditySource(source).setLiquidity(1_000_000);
        ExecutorLiquiditySource(source).setCallback(callbackTarget, callbackData);
        execution = _execution();

        bytes memory data = abi.encodeCall(ExecutorLiquiditySource.withdraw, (address(adapter), uint256(995)));
        bytes memory mask = new bytes(data.length);
        bytes32 leaf = _leaf(source, data, mask);
        bytes32 previousRoot = adapter.merkleRoot();
        bytes32 root = previousRoot < leaf
            ? keccak256(abi.encodePacked(previousRoot, leaf))
            : keccak256(abi.encodePacked(leaf, previousRoot));
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        adapter.grantRole(leaf, _executor);

        IExecutor.Action[] memory configuration = new IExecutor.Action[](1);
        configuration[0] = IExecutor.Action(source, abi.encodeCall(ExecutorLiquiditySource.getLiquidity, ()), leaf);
        LiquidLaneExecutor(_executor)
            .setActions(
                configuration,
                LiquidLaneExecutor(_executor).approvalLeaf(),
                LiquidLaneExecutor(_executor).operationLeaf()
            );

        bytes32[] memory approvalProof = new bytes32[](2);
        approvalProof[0] = execution.approval.proof[0];
        approvalProof[1] = leaf;
        execution.approval.proof = approvalProof;
        bytes32[] memory operationProof = new bytes32[](2);
        operationProof[0] = execution.operation.proof[0];
        operationProof[1] = leaf;
        execution.operation.proof = operationProof;
        bytes32[] memory fundingProof = new bytes32[](1);
        fundingProof[0] = previousRoot;
        execution.actions = new IMerkleAdapter.Action[](1);
        execution.actions[0] = IMerkleAdapter.Action(source, 0, data, mask, fundingProof);
    }

    function _assertFundingRollback(address source) internal view {
        assertEq(IERC20(_asset).balanceOf(source), 1_000_000);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_rwa).balanceOf(_lane), 1_000_000);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
    }

    function _swap(ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature)
        internal
        returns (uint256)
    {
        return LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, _execution(), new IMerkleAdapter.Action[](0));
    }

    function _expectSwapRevert(
        ILiquidLaneAdapter.DiscountSwap memory discountSwap,
        bytes memory protocolSignature,
        bytes4 expected
    ) internal {
        IExecutor.Execution memory execution = _execution();
        uint256 balanceBefore = IERC20(_asset).balanceOf(address(adapter));
        vm.expectRevert(expected);
        LiquidLaneExecutor(_executor)
            .swap(discountSwap, protocolSignature, _recipient, 1000, execution, new IMerkleAdapter.Action[](0));
        assertEq(IERC20(_asset).balanceOf(address(adapter)), balanceBefore);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
    }

    function _execution() internal returns (IExecutor.Execution memory execution) {
        bytes memory approvalData = abi.encodeCall(IERC20.approve, (_lane, uint256(0)));
        bytes memory approvalMask = new bytes(approvalData.length);
        for (uint256 i = 36; i < 68; ++i) {
            approvalMask[i] = 0xff;
        }
        bytes memory operationData =
            abi.encodeCall(ILiquidLaneConnector.swap, (ILiquidLaneConnector.Swap(_recipient, _rwa, 0, 0)));
        bytes memory operationMask = new bytes(operationData.length);
        for (uint256 i = 68; i < 132; ++i) {
            operationMask[i] = 0xff;
        }
        bytes32 approvalLeaf = _leaf(_asset, approvalData, approvalMask);
        bytes32 operationLeaf = _leaf(_lane, operationData, operationMask);
        bytes32 root = approvalLeaf < operationLeaf
            ? keccak256(abi.encodePacked(approvalLeaf, operationLeaf))
            : keccak256(abi.encodePacked(operationLeaf, approvalLeaf));
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        adapter.grantRole(approvalLeaf, _executor);
        adapter.grantRole(operationLeaf, _executor);
        LiquidLaneExecutor(_executor).setActions(new IExecutor.Action[](0), approvalLeaf, operationLeaf);
        execution.actions = new IMerkleAdapter.Action[](0);
        execution.approval = IExecutor.Permission(approvalMask, new bytes32[](1));
        execution.approval.proof[0] = operationLeaf;
        execution.operation = IExecutor.Permission(operationMask, new bytes32[](1));
        execution.operation.proof[0] = approvalLeaf;
    }

    function _signed(uint256 ppm)
        internal
        view
        returns (ILiquidLaneAdapter.DiscountSwap memory discountSwap, bytes memory protocolSignature)
    {
        discountSwap.discount =
            ILiquidLaneAdapter.Discount(_rwa, ppm, _signer, _protocol, 17, uint48(block.timestamp + 60));
        discountSwap.protocolDeadline = uint48(block.timestamp + 30);
        discountSwap.signerSignature = _sign(_signerKey, _discountDigest(discountSwap, _executor));
        protocolSignature = _sign(_protocolKey, _protocolDigest(discountSwap, _executor));
    }

    function _discountHash(ILiquidLaneAdapter.DiscountSwap memory discountSwap) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
                ),
                discountSwap.discount
            )
        );
    }

    function _discountDigest(ILiquidLaneAdapter.DiscountSwap memory discountSwap, address verifyingContract)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(hex"1901", _domain(verifyingContract), _discountHash(discountSwap)));
    }

    function _protocolDigest(ILiquidLaneAdapter.DiscountSwap memory discountSwap, address verifyingContract)
        internal
        view
        returns (bytes32)
    {
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "DiscountSwap(Discount discount,bytes signerSignature,uint48 protocolDeadline)Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
                ),
                _discountHash(discountSwap),
                keccak256(discountSwap.signerSignature),
                discountSwap.protocolDeadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", _domain(verifyingContract), hash));
    }

    function _domain(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LiquidLaneExecutor"),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _sign(uint256 key, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _leaf(address target, bytes memory data, bytes memory mask) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(target, bytes1(0), keccak256(mask), keccak256(data)))));
    }
}

contract LiquidLaneDiscountSignatureMock is IERC1271 {
    bytes32 internal _digest;
    bytes32 internal _signatureHash;

    function setSignature(bytes32 digest, bytes calldata signature) public {
        _digest = digest;
        _signatureHash = keccak256(signature);
    }

    function isValidSignature(bytes32 digest, bytes memory signature) public view returns (bytes4) {
        return
            digest == _digest && keccak256(signature) == _signatureHash ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

/// @dev Production connector behavior with a test-only setter for otherwise immutable initialization state.
contract LiquidLaneMutableInputConnector is LiquidLaneConnector {
    constructor(address factory, address oracleRegistry) LiquidLaneConnector(factory, oracleRegistry) {}

    function setInputAsset(address newInputAsset) public {
        inputAsset = newInputAsset;
    }
}

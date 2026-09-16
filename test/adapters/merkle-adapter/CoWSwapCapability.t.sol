// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CoWSwapCapability} from "src/contracts/merkle_adapter/CoWSwapCapability.sol";
import {ICoWSwapCapability} from "src/interfaces/merkle_adapter/ICoWSwapCapability.sol";
import {ICapability} from "src/interfaces/merkle_adapter/ICapability.sol";
import {Token} from "test/mocks/Token.sol";
import {CoWCapabilitySettlementMock, CoWCapabilityPausedTokenMock} from "test/mocks/CoWSwapCapabilityMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract CoWSwapCapabilityTest is CapabilityTestBase {
    CoWCapabilitySettlementMock internal settlement;
    CoWSwapCapability internal implementation;
    CoWSwapCapability internal capability;
    Token internal tokenIn;
    Token internal tokenOut;

    function setUp() public {
        vm.warp(1000);
        settlement = new CoWCapabilitySettlementMock();
        tokenIn = new Token("Sell");
        tokenOut = new Token("Buy");
        _deployAdapter(address(tokenIn));
        implementation = new CoWSwapCapability(address(settlement));
        _installCapability(adapter, address(implementation), _cowSelectors());
        capability = CoWSwapCapability(address(adapter));
        tokenIn.transfer(address(adapter), 1000);
    }

    function test_ConvertKeepsFundsOnAdapterUntilSettlement() public {
        bytes memory uid = _convert(100, _params(90));
        assertEq(tokenIn.balanceOf(address(adapter)), 1000);
        assertEq(tokenIn.balanceOf(address(implementation)), 0);
        assertEq(tokenIn.allowance(address(adapter), settlement.vaultRelayer()), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), uid);
        assertEq(uid.length, 56);
        assertGt(settlement.preSignature(uid), 0);
        bytes memory expectedOwner = abi.encodePacked(address(adapter));
        for (uint256 i; i < 20; ++i) {
            assertEq(uid[32 + i], expectedOwner[i]);
        }
    }

    function test_SeparateApprovalAllowsSettlementFromAdapterAndCancellationKeepsFunds() public {
        _manage(address(tokenIn), abi.encodeCall(IERC20.approve, (settlement.vaultRelayer(), 100)));
        bytes memory uid = _convert(100, _params(90));
        assertEq(tokenIn.allowance(address(adapter), settlement.vaultRelayer()), 100);
        settlement.consumePresignedSellTokens(uid, address(tokenIn), 40);
        assertEq(tokenIn.balanceOf(address(adapter)), 960);
        assertEq(tokenIn.balanceOf(address(settlement)), 40);
        _manage(address(adapter), abi.encodeCall(ICoWSwapCapability.invalidateConvert, (address(tokenIn))));
        assertEq(settlement.preSignature(uid), 0);
        assertEq(tokenIn.balanceOf(address(adapter)), 960);
        assertEq(tokenIn.allowance(address(adapter), settlement.vaultRelayer()), 60);
        vm.expectRevert("GPv2: order not presigned");
        settlement.consumePresignedSellTokens(uid, address(tokenIn), 60);
        _manage(address(tokenIn), abi.encodeCall(IERC20.approve, (settlement.vaultRelayer(), 0)));
        assertEq(tokenIn.allowance(address(adapter), settlement.vaultRelayer()), 0);
    }

    function test_OnlyManagedSelfCallsCanAuthorizeOrCancel() public {
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.convert(address(tokenIn), 100, address(tokenOut), _params(90));
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.invalidateConvert(address(tokenIn));
        vm.expectRevert(ICapability.InvalidCaller.selector);
        implementation.convert(address(tokenIn), 100, address(tokenOut), _params(90));
    }

    function test_ReplacementRevokesOldOrderAndPreservesAdapterFunds() public {
        bytes memory oldUid = _convert(100, _params(90));
        bytes memory uid = _convert(200, _params(185));
        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(settlement.preSignature(uid), 0);
        assertEq(tokenIn.balanceOf(address(adapter)), 1000);
    }

    function test_SettlementCannotReenterSignatureChangesOrManage() public {
        settlement.setCallback(
            address(adapter), abi.encodeCall(ICoWSwapCapability.invalidateConvert, (address(tokenIn)))
        );
        bytes memory oldUid = _convert(100, _params(90));
        assertFalse(settlement.callbackSucceeded());
        assertEq(settlement.callbackResult(), abi.encodeWithSelector(ICapability.InvalidCaller.selector));
        bytes memory uid = _convert(200, _params(185));
        assertFalse(settlement.callbackSucceeded());
        assertEq(settlement.callbackResult(), abi.encodeWithSelector(ICapability.InvalidCaller.selector));
        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(settlement.preSignature(uid), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), uid);

        settlement.setCallback(
            address(adapter), abi.encodeCall(IMerkleAdapter.manage, (new IMerkleAdapter.Action[](0)))
        );
        _manage(address(adapter), abi.encodeCall(ICoWSwapCapability.invalidateConvert, (address(tokenIn))));
        assertFalse(settlement.callbackSucceeded());
        assertEq(
            settlement.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(settlement.preSignature(uid), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), bytes(""));
        assertEq(tokenIn.balanceOf(address(adapter)), 1000);
    }

    function test_ImplementationReplacementCanRevokeOriginalSettlementOrder() public {
        bytes memory oldUid = _convert(100, _params(90));
        CoWCapabilitySettlementMock replacementSettlement = new CoWCapabilitySettlementMock();
        adapter.removeCapability(address(implementation));
        _installCapability(adapter, address(new CoWSwapCapability(address(replacementSettlement))), _cowSelectors());
        assertEq(capability.activeOrderUid(address(tokenIn)), oldUid);
        bytes memory uid = _convert(100, _params(95));
        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(replacementSettlement.preSignature(uid), 0);
        assertEq(tokenIn.balanceOf(address(adapter)), 1000);
    }

    function test_SharedImplementationKeepsAdapterOrdersIsolated() public {
        bytes memory oldUid = _convert(100, _params(90));
        MerkleAdapter first = adapter;
        _deployAdapter(address(tokenIn));
        _installCapability(adapter, address(implementation), _cowSelectors());
        assertEq(CoWSwapCapability(address(adapter)).activeOrderUid(address(tokenIn)), bytes(""));
        tokenIn.transfer(address(adapter), 200);
        _convert(100, _params(95));
        assertEq(CoWSwapCapability(address(first)).activeOrderUid(address(tokenIn)), oldUid);
        assertGt(settlement.preSignature(oldUid), 0);
        assertEq(implementation.activeOrderUid(address(tokenIn)), bytes(""));
    }

    function test_CancellationWorksWithPausedToken() public {
        CoWCapabilityPausedTokenMock token = new CoWCapabilityPausedTokenMock();
        token.transfer(address(adapter), 100);
        bytes memory uid = abi.decode(
            _manage(
                address(adapter),
                abi.encodeCall(ICoWSwapCapability.convert, (address(token), 100, address(tokenOut), _params(90)))
            ),
            (bytes)
        );
        token.setPaused(true);
        _manage(address(adapter), abi.encodeCall(ICoWSwapCapability.invalidateConvert, (address(token))));
        assertEq(settlement.preSignature(uid), 0);
        assertEq(token.balanceOf(address(adapter)), 100);
    }

    function test_InvalidReplacementLeavesOriginalOrderActive() public {
        bytes memory uid = _convert(100, _params(90));
        _expectConvertRevert(1001, _params(90), ICoWSwapCapability.InvalidSellAmount.selector);
        assertGt(settlement.preSignature(uid), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), uid);
    }

    function test_InvalidAmountsAndExpiryRevert() public {
        _expectConvertRevert(0, _params(90), ICoWSwapCapability.InvalidSellAmount.selector);
        _expectConvertRevert(100, _params(0), ICoWSwapCapability.InvalidBuyAmount.selector);
        ICoWSwapCapability.OrderParams memory params = _params(90);
        params.validTo = uint32(block.timestamp);
        _expectConvertRevert(100, params, ICoWSwapCapability.ExpiredOrder.selector);
        params.validTo = uint32(block.timestamp + 1801);
        _expectConvertRevert(100, params, ICoWSwapCapability.TooFarValidTo.selector);
    }

    function test_InvalidTokensRevert() public {
        IMerkleAdapter.Action[] memory calls = _publishCall(
            address(adapter),
            abi.encodeCall(ICoWSwapCapability.convert, (address(tokenIn), 100, address(tokenIn), _params(90)))
        );
        vm.expectRevert(ICoWSwapCapability.InvalidToken.selector);
        adapter.manage(calls);
        calls = _publishCall(
            address(adapter),
            abi.encodeCall(ICoWSwapCapability.convert, (address(0x123), 100, address(tokenOut), _params(90)))
        );
        vm.expectRevert(ICoWSwapCapability.InvalidToken.selector);
        adapter.manage(calls);
    }

    function testFuzz_AuthorizationNeverMovesTokensOrChangesAllowance(uint256 amount, uint256 allowance) public {
        amount = bound(amount, 1, 1000);
        _manage(address(tokenIn), abi.encodeCall(IERC20.approve, (settlement.vaultRelayer(), allowance)));
        _convert(amount, _params(90));
        assertEq(tokenIn.balanceOf(address(adapter)), 1000);
        assertEq(tokenIn.allowance(address(adapter), settlement.vaultRelayer()), allowance);
    }

    function _convert(uint256 amount, ICoWSwapCapability.OrderParams memory params) internal returns (bytes memory) {
        return abi.decode(
            _manage(
                address(adapter),
                abi.encodeCall(ICoWSwapCapability.convert, (address(tokenIn), amount, address(tokenOut), params))
            ),
            (bytes)
        );
    }

    function _params(uint256 buyAmount) internal view returns (ICoWSwapCapability.OrderParams memory) {
        return ICoWSwapCapability.OrderParams(buyAmount, uint32(block.timestamp + 1800), bytes32(0));
    }

    function _expectConvertRevert(uint256 amount, ICoWSwapCapability.OrderParams memory params, bytes4 errorSelector)
        internal
    {
        IMerkleAdapter.Action[] memory calls = _publishCall(
            address(adapter),
            abi.encodeCall(ICoWSwapCapability.convert, (address(tokenIn), amount, address(tokenOut), params))
        );
        vm.expectRevert(errorSelector);
        adapter.manage(calls);
    }
}

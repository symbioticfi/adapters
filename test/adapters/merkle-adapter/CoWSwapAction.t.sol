// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {CoWSwapAction} from "src/contracts/merkle_adapter/CoWSwapAction.sol";
import {ICoWSwapAction} from "src/interfaces/merkle_adapter/ICoWSwapAction.sol";
import {Token} from "test/mocks/Token.sol";
import {
    CoWActionCallbackAdapterMock,
    CoWActionCallbackTokenMock,
    CoWActionPausedTokenMock,
    CoWActionSettlementMock,
    CoWActionSettlementWithoutRelayerMock,
    CoWActionTaxTokenMock
} from "test/mocks/CoWSwapActionMocks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract CoWSwapActionTest is Test {
    CoWActionSettlementMock internal settlement;
    MigratablesFactory internal factory;
    CoWSwapAction internal actionContract;
    Token internal tokenIn;
    Token internal tokenOut;
    address internal adapter = makeAddr("adapter");
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1000);
        settlement = new CoWActionSettlementMock();
        factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new CoWSwapAction(address(factory), address(settlement))));
        actionContract = CoWSwapAction(factory.create(1, owner, abi.encode(adapter)));
        tokenIn = new Token("Sell token");
        tokenOut = new Token("Buy token");
        tokenIn.transfer(adapter, 1000);
        vm.prank(adapter);
        tokenIn.approve(address(actionContract), type(uint256).max);
    }

    function test_ConvertPullsExactFundingAndBoundsRelayerApproval() public {
        bytes memory uid = _convert(100, _params(90));

        assertEq(uid.length, 56);
        assertEq(actionContract.activeOrderUid(address(tokenIn)), uid);
        assertEq(tokenIn.balanceOf(adapter), 900);
        assertEq(tokenIn.balanceOf(address(actionContract)), 100);
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), 100);
        assertGt(settlement.preSignature(uid), 0);
    }

    function test_RecoveryRejectsAddressWithoutTokenCode() public {
        vm.prank(adapter);
        vm.expectRevert(ICoWSwapAction.InvalidToken.selector);
        actionContract.recover(makeAddr("not a token"));
    }

    function test_ConvertMatchesIndependentlyComputedCanonicalGoldenDigest() public {
        address canonicalSell = 0x9994E35Db50125E0DF82e4c2dde62496CE330999;
        address canonicalBuy = 0x1111111111111111111111111111111111111111;
        address canonicalReceiver = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
        vm.etch(canonicalSell, address(tokenIn).code);
        vm.etch(canonicalBuy, address(tokenOut).code);
        CoWSwapAction goldenCapability = CoWSwapAction(factory.create(1, owner, abi.encode(canonicalReceiver)));
        deal(canonicalSell, canonicalReceiver, 5);
        vm.startPrank(canonicalReceiver);
        IERC20(canonicalSell).approve(address(goldenCapability), 5);
        bytes memory uid = goldenCapability.convert(
            canonicalSell,
            5,
            canonicalBuy,
            ICoWSwapAction.OrderParams({
                buyAmount: 990_000,
                validTo: 2200,
                appData: 0x412c256874305de3f4aa0f8391d6f829d4918f6ea6ef32931c6ed62a3e2bc897
            })
        );
        vm.stopPrank();

        // Canonical Ethereum domain and order digest independently match the existing GPv2 golden fixture.
        assertEq(
            uid,
            abi.encodePacked(
                bytes32(0xfddd8f2e7930f6882586ca5be3923ece8b3479e55e144e4d029bf77b36cd143a),
                address(goldenCapability),
                uint32(2200)
            )
        );
    }

    function test_OnlyAdapterCanAuthorizeCancelOrRecover() public {
        ICoWSwapAction.OrderParams memory params = _params(90);
        vm.startPrank(owner);
        vm.expectRevert(ICoWSwapAction.InvalidCaller.selector);
        actionContract.convert(address(tokenIn), 100, address(tokenOut), params);
        vm.expectRevert(ICoWSwapAction.InvalidCaller.selector);
        actionContract.invalidateConvert(address(tokenIn));
        vm.expectRevert(ICoWSwapAction.InvalidCaller.selector);
        actionContract.recover(address(tokenIn));
        vm.stopPrank();
    }

    function test_ConvertRejectsZeroAndUnavailableFunding() public {
        ICoWSwapAction.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        vm.expectRevert(ICoWSwapAction.InvalidSellAmount.selector);
        actionContract.convert(address(tokenIn), 0, address(tokenOut), params);
        vm.expectRevert(ICoWSwapAction.InvalidSellAmount.selector);
        actionContract.convert(address(tokenIn), 1001, address(tokenOut), params);
        vm.stopPrank();
    }

    function test_ConvertRejectsMissingBuyAmount() public {
        ICoWSwapAction.OrderParams memory params = _params(0);
        vm.prank(adapter);
        vm.expectRevert(ICoWSwapAction.InvalidBuyAmount.selector);
        actionContract.convert(address(tokenIn), 100, address(tokenOut), params);
    }

    function test_ConvertRejectsInvalidTokenPair() public {
        ICoWSwapAction.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        vm.expectRevert(ICoWSwapAction.InvalidToken.selector);
        actionContract.convert(address(tokenIn), 100, address(tokenIn), params);
        vm.expectRevert(ICoWSwapAction.InvalidToken.selector);
        actionContract.convert(address(0), 100, address(tokenOut), params);
        vm.expectRevert(ICoWSwapAction.InvalidToken.selector);
        actionContract.convert(address(tokenIn), 100, address(0), params);
        vm.expectRevert(ICoWSwapAction.InvalidToken.selector);
        actionContract.convert(address(tokenIn), 100, owner, params);
        vm.stopPrank();
    }

    function test_ConvertRejectsExpiryAtCurrentTimestampAndBeyondThirtyMinutes() public {
        ICoWSwapAction.OrderParams memory params = _params(90);
        params.validTo = 1000;
        vm.startPrank(adapter);
        vm.expectRevert(ICoWSwapAction.ExpiredOrder.selector);
        actionContract.convert(address(tokenIn), 100, address(tokenOut), params);
        params.validTo = 2801;
        vm.expectRevert(ICoWSwapAction.TooFarValidTo.selector);
        actionContract.convert(address(tokenIn), 100, address(tokenOut), params);
        vm.stopPrank();
    }

    function testFuzz_ConvertAcceptsPositiveAmountsAndExpiryWithinThirtyMinutes(
        uint256 amountIn,
        uint256 amountOut,
        uint32 duration
    ) public {
        amountIn = bound(amountIn, 1, 1000);
        amountOut = bound(amountOut, 1, type(uint128).max);
        duration = uint32(bound(duration, 1, 1800));
        ICoWSwapAction.OrderParams memory params = _params(amountOut);
        params.validTo = uint32(block.timestamp) + duration;
        _convert(amountIn, params);

        assertEq(tokenIn.balanceOf(address(actionContract)), amountIn);
        assertEq(tokenIn.balanceOf(adapter), 1000 - amountIn);
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), amountIn);
    }

    function test_ConvertRejectsTransferTaxAndRollsBackFunding() public {
        CoWActionTaxTokenMock taxed = new CoWActionTaxTokenMock();
        taxed.transfer(adapter, 101);
        ICoWSwapAction.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        taxed.approve(address(actionContract), 100);
        vm.expectRevert(ICoWSwapAction.InvalidSellAmount.selector);
        actionContract.convert(address(taxed), 100, address(tokenOut), params);
        vm.stopPrank();

        assertEq(taxed.balanceOf(adapter), 100);
        assertEq(taxed.balanceOf(address(actionContract)), 0);
        assertEq(taxed.allowance(address(actionContract), settlement.vaultRelayer()), 0);
    }

    function test_InitializationRejectsZeroAdapter() public {
        vm.expectRevert(ICoWSwapAction.InvalidAdapter.selector);
        factory.create(1, owner, abi.encode(address(0)));
    }

    function test_ReplaceRevokesOldOrderBeforeFundingTheNewOne() public {
        bytes memory oldUid = _convert(100, _params(90));
        settlement.consumeSellTokens(address(tokenIn), address(actionContract), 40);

        bytes memory newUid = _convert(80, _params(75));

        assertNotEq(oldUid, newUid);
        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(settlement.preSignature(newUid), 0);
        assertEq(actionContract.activeOrderUid(address(tokenIn)), newUid);
        assertEq(tokenIn.balanceOf(adapter), 880);
        assertEq(tokenIn.balanceOf(address(actionContract)), 80);
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), 80);
    }

    function test_ReplaceCanReuseRefundedFundingWhenAdapterHasNoIdleBalance() public {
        bytes memory oldUid = _convert(1000, _params(900));
        bytes memory newUid = _convert(1000, _params(950));

        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(settlement.preSignature(newUid), 0);
        assertEq(tokenIn.balanceOf(adapter), 0);
        assertEq(tokenIn.balanceOf(address(actionContract)), 1000);
    }

    function test_InvalidReplacementPreservesOldOrderAndFunds() public {
        bytes memory oldUid = _convert(100, _params(90));
        ICoWSwapAction.OrderParams memory params = _params(95);

        vm.startPrank(adapter);
        tokenIn.approve(address(actionContract), 0);
        vm.expectRevert();
        actionContract.convert(address(tokenIn), 100, address(tokenOut), params);
        vm.stopPrank();

        assertGt(settlement.preSignature(oldUid), 0);
        assertEq(actionContract.activeOrderUid(address(tokenIn)), oldUid);
        assertEq(tokenIn.balanceOf(address(actionContract)), 100);
        assertEq(tokenIn.balanceOf(adapter), 900);
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), 100);
    }

    function test_InvalidateClearsSignatureAndKeepsFundingUntilRecoveryClearsAllowance() public {
        bytes memory uid = _convert(100, _params(90));

        vm.prank(adapter);
        actionContract.invalidateConvert(address(tokenIn));

        assertEq(settlement.preSignature(uid), 0);
        assertEq(actionContract.activeOrderUid(address(tokenIn)), bytes(""));
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), 100);
        assertEq(tokenIn.balanceOf(address(actionContract)), 100);

        vm.prank(adapter);
        assertEq(actionContract.recover(address(tokenIn)), 100);
        assertEq(tokenIn.balanceOf(adapter), 1000);
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), 0);
    }

    function test_InvalidatePausedTokenPreventsOldOrderFromFillingAfterResume() public {
        (CoWActionPausedTokenMock pausedToken, bytes memory uid) = _pausedPartialFill();

        vm.prank(adapter);
        actionContract.invalidateConvert(address(pausedToken));

        assertEq(settlement.preSignature(uid), 0);
        assertEq(actionContract.activeOrderUid(address(pausedToken)), bytes(""));
        assertEq(pausedToken.allowance(address(actionContract), settlement.vaultRelayer()), 60);
        assertEq(pausedToken.balanceOf(address(actionContract)), 60);

        pausedToken.setPaused(false);
        vm.expectRevert("GPv2: order not presigned");
        settlement.consumePresignedSellTokens(uid, address(pausedToken), 60);
        assertEq(pausedToken.balanceOf(address(actionContract)), 60);
        assertEq(pausedToken.balanceOf(address(settlement)), 40);
    }

    function test_PausedRecoveryCannotUndoCancellationAndSucceedsAfterResume() public {
        (CoWActionPausedTokenMock pausedToken, bytes memory uid) = _pausedPartialFill();
        vm.prank(adapter);
        actionContract.invalidateConvert(address(pausedToken));

        vm.prank(adapter);
        vm.expectRevert(CoWActionPausedTokenMock.TokenPaused.selector);
        actionContract.recover(address(pausedToken));

        assertEq(settlement.preSignature(uid), 0);
        assertEq(actionContract.activeOrderUid(address(pausedToken)), bytes(""));
        assertEq(pausedToken.balanceOf(address(actionContract)), 60);
        pausedToken.setPaused(false);

        vm.prank(adapter);
        assertEq(actionContract.recover(address(pausedToken)), 60);
        assertEq(pausedToken.balanceOf(adapter), 60);
        assertEq(pausedToken.balanceOf(address(actionContract)), 0);
        assertEq(pausedToken.allowance(address(actionContract), settlement.vaultRelayer()), 0);
        assertEq(settlement.preSignature(uid), 0);
    }

    function testFuzz_RecoverPartialFillReturnsAllUnusedTokensAndRevokesOrder(uint256 sold) public {
        sold = bound(sold, 0, 100);
        bytes memory uid = _convert(100, _params(90));
        settlement.consumeSellTokens(address(tokenIn), address(actionContract), sold);

        vm.prank(adapter);
        uint256 recovered = actionContract.recover(address(tokenIn));

        assertEq(recovered, 100 - sold);
        assertEq(settlement.preSignature(uid), 0);
        assertEq(actionContract.activeOrderUid(address(tokenIn)), bytes(""));
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), 0);
        assertEq(tokenIn.balanceOf(address(actionContract)), 0);
        assertEq(tokenIn.balanceOf(adapter), 1000 - sold);
        assertEq(tokenIn.balanceOf(address(settlement)), sold);
    }

    function test_RecoverExpiredOrderAndAccidentallyReceivedBuyTokens() public {
        bytes memory uid = _convert(100, _params(90));
        tokenOut.transfer(address(actionContract), 73);
        vm.warp(2801);

        vm.startPrank(adapter);
        assertEq(actionContract.recover(address(tokenIn)), 100);
        assertEq(actionContract.recover(address(tokenOut)), 73);
        assertEq(actionContract.recover(address(tokenOut)), 0);
        vm.stopPrank();

        assertEq(settlement.preSignature(uid), 0);
        assertEq(tokenIn.balanceOf(adapter), 1000);
        assertEq(tokenOut.balanceOf(adapter), 73);
    }

    function test_RecoveryOfOneSellTokenLeavesOtherOrderAuthorized() public {
        bytes memory firstUid = _convert(100, _params(90));
        tokenOut.transfer(adapter, 200);
        ICoWSwapAction.OrderParams memory params = _params(190);
        vm.startPrank(adapter);
        tokenOut.approve(address(actionContract), 200);
        bytes memory secondUid = actionContract.convert(address(tokenOut), 200, address(tokenIn), params);
        actionContract.recover(address(tokenIn));
        vm.stopPrank();

        assertEq(settlement.preSignature(firstUid), 0);
        assertGt(settlement.preSignature(secondUid), 0);
        assertEq(tokenOut.balanceOf(address(actionContract)), 200);
        assertEq(tokenOut.allowance(address(actionContract), settlement.vaultRelayer()), 200);
    }

    function test_MigrationPreservesOrderAuthorizationAndRecovery() public {
        bytes memory uid = _convert(100, _params(90));
        factory.whitelist(address(new CoWSwapAction(address(factory), address(settlement))));

        vm.prank(owner);
        factory.migrate(address(actionContract), 2, "");

        assertEq(actionContract.adapter(), adapter);
        assertEq(actionContract.activeOrderUid(address(tokenIn)), uid);
        vm.prank(adapter);
        assertEq(actionContract.recover(address(tokenIn)), 100);
        assertEq(settlement.preSignature(uid), 0);
        assertEq(tokenIn.balanceOf(adapter), 1000);
    }

    function test_MigrationRejectsUnexpectedData() public {
        factory.whitelist(address(new CoWSwapAction(address(factory), address(settlement))));

        vm.prank(owner);
        vm.expectRevert(ICoWSwapAction.InvalidMigrationData.selector);
        factory.migrate(address(actionContract), 2, abi.encode(adapter));
    }

    function test_MigrationRejectsChangedSettlementAndKeepsExistingOrderRecoverable() public {
        bytes memory uid = _convert(100, _params(90));
        CoWActionSettlementMock otherSettlement = new CoWActionSettlementMock();
        factory.whitelist(address(new CoWSwapAction(address(factory), address(otherSettlement))));

        vm.prank(owner);
        vm.expectRevert(ICoWSwapAction.IncompatibleSettlement.selector);
        factory.migrate(address(actionContract), 2, "");

        assertEq(actionContract.version(), 1);
        assertEq(actionContract.COW_SWAP_SETTLEMENT(), address(settlement));
        vm.prank(adapter);
        assertEq(actionContract.recover(address(tokenIn)), 100);
        assertEq(settlement.preSignature(uid), 0);
        assertEq(tokenIn.allowance(address(actionContract), settlement.vaultRelayer()), 0);
    }

    function test_ConstructorRequiresReadableSettlement() public {
        vm.expectRevert();
        new CoWSwapAction(address(factory), address(0));

        address undeployedSettlement = makeAddr("undeployed settlement");
        vm.expectRevert();
        new CoWSwapAction(address(factory), undeployedSettlement);
    }

    function test_ConstructorStoresSettlementRelayerWithoutCode() public {
        CoWActionSettlementWithoutRelayerMock missingRelayer = new CoWActionSettlementWithoutRelayerMock();

        CoWSwapAction uncheckedAction = new CoWSwapAction(address(factory), address(missingRelayer));
        assertEq(uncheckedAction.COW_SWAP_SETTLEMENT(), address(missingRelayer));
        assertEq(uncheckedAction.COW_SWAP_VAULT_RELAYER(), missingRelayer.vaultRelayer());
    }

    function test_CallbackThroughAdapterCannotReenterRecoveryDuringFunding() public {
        CoWActionCallbackTokenMock callbackToken = new CoWActionCallbackTokenMock();
        CoWActionCallbackAdapterMock callbackAdapter = new CoWActionCallbackAdapterMock();
        CoWSwapAction callbackCapability = CoWSwapAction(factory.create(1, owner, abi.encode(address(callbackAdapter))));
        callbackToken.transfer(address(callbackAdapter), 100);
        callbackToken.setCallback(address(callbackAdapter));

        callbackAdapter.authorize(callbackCapability, callbackToken, address(tokenOut));

        assertFalse(callbackAdapter.callbackSucceeded());
        assertEq(
            callbackAdapter.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(callbackToken.balanceOf(address(callbackCapability)), 100);
        assertEq(callbackToken.balanceOf(address(callbackAdapter)), 0);
        assertEq(callbackToken.allowance(address(callbackCapability), settlement.vaultRelayer()), 100);
    }

    function _convert(uint256 amountIn, ICoWSwapAction.OrderParams memory params) internal returns (bytes memory uid) {
        vm.prank(adapter);
        uid = actionContract.convert(address(tokenIn), amountIn, address(tokenOut), params);
    }

    function _pausedPartialFill() internal returns (CoWActionPausedTokenMock pausedToken, bytes memory uid) {
        pausedToken = new CoWActionPausedTokenMock();
        pausedToken.transfer(adapter, 100);
        ICoWSwapAction.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        pausedToken.approve(address(actionContract), 100);
        uid = actionContract.convert(address(pausedToken), 100, address(tokenOut), params);
        vm.stopPrank();
        settlement.consumePresignedSellTokens(uid, address(pausedToken), 40);
        pausedToken.setPaused(true);
    }

    function _params(uint256 buyAmount) internal view returns (ICoWSwapAction.OrderParams memory) {
        return ICoWSwapAction.OrderParams({
            buyAmount: buyAmount, validTo: uint32(block.timestamp + 1800), appData: keccak256("CoW actionContract")
        });
    }
}

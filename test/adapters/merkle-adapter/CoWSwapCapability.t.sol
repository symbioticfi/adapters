// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {CoWSwapCapability} from "src/contracts/merkle_adapter/CoWSwapCapability.sol";
import {ICoWSwapCapability} from "src/interfaces/merkle_adapter/ICoWSwapCapability.sol";
import {Token} from "test/mocks/Token.sol";
import {
    CoWCapabilityCallbackAdapterMock,
    CoWCapabilityCallbackTokenMock,
    CoWCapabilityPausedTokenMock,
    CoWCapabilitySettlementMock,
    CoWCapabilitySettlementWithoutRelayerMock,
    CoWCapabilityTaxTokenMock
} from "test/mocks/CoWSwapCapabilityMocks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract CoWSwapCapabilityTest is Test {
    CoWCapabilitySettlementMock internal settlement;
    MigratablesFactory internal factory;
    CoWSwapCapability internal capability;
    Token internal tokenIn;
    Token internal tokenOut;
    address internal adapter = makeAddr("adapter");
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1000);
        settlement = new CoWCapabilitySettlementMock();
        factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new CoWSwapCapability(address(factory), address(settlement))));
        capability = CoWSwapCapability(factory.create(1, owner, abi.encode(adapter)));
        tokenIn = new Token("Sell token");
        tokenOut = new Token("Buy token");
        tokenIn.transfer(adapter, 1000);
        vm.prank(adapter);
        tokenIn.approve(address(capability), type(uint256).max);
    }

    function test_ConvertPullsExactFundingAndBoundsRelayerApproval() public {
        bytes memory uid = _convert(100, _params(90));

        assertEq(uid.length, 56);
        assertEq(capability.activeOrderUid(address(tokenIn)), uid);
        assertEq(tokenIn.balanceOf(adapter), 900);
        assertEq(tokenIn.balanceOf(address(capability)), 100);
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), 100);
        assertGt(settlement.preSignature(uid), 0);
    }

    function test_RecoveryRejectsAddressWithoutTokenCode() public {
        vm.prank(adapter);
        vm.expectRevert(ICoWSwapCapability.InvalidToken.selector);
        capability.recover(makeAddr("not a token"));
    }

    function test_ConvertMatchesIndependentlyComputedCanonicalGoldenDigest() public {
        address canonicalSell = 0x9994E35Db50125E0DF82e4c2dde62496CE330999;
        address canonicalBuy = 0x1111111111111111111111111111111111111111;
        address canonicalReceiver = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
        vm.etch(canonicalSell, address(tokenIn).code);
        vm.etch(canonicalBuy, address(tokenOut).code);
        CoWSwapCapability goldenCapability = CoWSwapCapability(factory.create(1, owner, abi.encode(canonicalReceiver)));
        deal(canonicalSell, canonicalReceiver, 5);
        vm.startPrank(canonicalReceiver);
        IERC20(canonicalSell).approve(address(goldenCapability), 5);
        bytes memory uid = goldenCapability.convert(
            canonicalSell,
            5,
            canonicalBuy,
            ICoWSwapCapability.OrderParams({
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
        ICoWSwapCapability.OrderParams memory params = _params(90);
        vm.startPrank(owner);
        vm.expectRevert(ICoWSwapCapability.InvalidCaller.selector);
        capability.convert(address(tokenIn), 100, address(tokenOut), params);
        vm.expectRevert(ICoWSwapCapability.InvalidCaller.selector);
        capability.invalidateConvert(address(tokenIn));
        vm.expectRevert(ICoWSwapCapability.InvalidCaller.selector);
        capability.recover(address(tokenIn));
        vm.stopPrank();
    }

    function test_ConvertRejectsZeroAndUnavailableFunding() public {
        ICoWSwapCapability.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        vm.expectRevert(ICoWSwapCapability.InvalidSellAmount.selector);
        capability.convert(address(tokenIn), 0, address(tokenOut), params);
        vm.expectRevert(ICoWSwapCapability.InvalidSellAmount.selector);
        capability.convert(address(tokenIn), 1001, address(tokenOut), params);
        vm.stopPrank();
    }

    function test_ConvertRejectsMissingBuyAmount() public {
        ICoWSwapCapability.OrderParams memory params = _params(0);
        vm.prank(adapter);
        vm.expectRevert(ICoWSwapCapability.InvalidBuyAmount.selector);
        capability.convert(address(tokenIn), 100, address(tokenOut), params);
    }

    function test_ConvertRejectsInvalidTokenPair() public {
        ICoWSwapCapability.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        vm.expectRevert(ICoWSwapCapability.InvalidToken.selector);
        capability.convert(address(tokenIn), 100, address(tokenIn), params);
        vm.expectRevert(ICoWSwapCapability.InvalidToken.selector);
        capability.convert(address(0), 100, address(tokenOut), params);
        vm.expectRevert(ICoWSwapCapability.InvalidToken.selector);
        capability.convert(address(tokenIn), 100, address(0), params);
        vm.expectRevert(ICoWSwapCapability.InvalidToken.selector);
        capability.convert(address(tokenIn), 100, owner, params);
        vm.stopPrank();
    }

    function test_ConvertRejectsExpiryAtCurrentTimestampAndBeyondThirtyMinutes() public {
        ICoWSwapCapability.OrderParams memory params = _params(90);
        params.validTo = 1000;
        vm.startPrank(adapter);
        vm.expectRevert(ICoWSwapCapability.ExpiredOrder.selector);
        capability.convert(address(tokenIn), 100, address(tokenOut), params);
        params.validTo = 2801;
        vm.expectRevert(ICoWSwapCapability.TooFarValidTo.selector);
        capability.convert(address(tokenIn), 100, address(tokenOut), params);
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
        ICoWSwapCapability.OrderParams memory params = _params(amountOut);
        params.validTo = uint32(block.timestamp) + duration;
        _convert(amountIn, params);

        assertEq(tokenIn.balanceOf(address(capability)), amountIn);
        assertEq(tokenIn.balanceOf(adapter), 1000 - amountIn);
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), amountIn);
    }

    function test_ConvertRejectsTransferTaxAndRollsBackFunding() public {
        CoWCapabilityTaxTokenMock taxed = new CoWCapabilityTaxTokenMock();
        taxed.transfer(adapter, 101);
        ICoWSwapCapability.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        taxed.approve(address(capability), 100);
        vm.expectRevert(ICoWSwapCapability.InvalidSellAmount.selector);
        capability.convert(address(taxed), 100, address(tokenOut), params);
        vm.stopPrank();

        assertEq(taxed.balanceOf(adapter), 100);
        assertEq(taxed.balanceOf(address(capability)), 0);
        assertEq(taxed.allowance(address(capability), settlement.vaultRelayer()), 0);
    }

    function test_InitializationRejectsZeroAdapter() public {
        vm.expectRevert(ICoWSwapCapability.InvalidAdapter.selector);
        factory.create(1, owner, abi.encode(address(0)));
    }

    function test_ReplaceRevokesOldOrderBeforeFundingTheNewOne() public {
        bytes memory oldUid = _convert(100, _params(90));
        settlement.consumeSellTokens(address(tokenIn), address(capability), 40);

        bytes memory newUid = _convert(80, _params(75));

        assertNotEq(oldUid, newUid);
        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(settlement.preSignature(newUid), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), newUid);
        assertEq(tokenIn.balanceOf(adapter), 880);
        assertEq(tokenIn.balanceOf(address(capability)), 80);
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), 80);
    }

    function test_ReplaceCanReuseRefundedFundingWhenAdapterHasNoIdleBalance() public {
        bytes memory oldUid = _convert(1000, _params(900));
        bytes memory newUid = _convert(1000, _params(950));

        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(settlement.preSignature(newUid), 0);
        assertEq(tokenIn.balanceOf(adapter), 0);
        assertEq(tokenIn.balanceOf(address(capability)), 1000);
    }

    function test_InvalidReplacementPreservesOldOrderAndFunds() public {
        bytes memory oldUid = _convert(100, _params(90));
        ICoWSwapCapability.OrderParams memory params = _params(95);

        vm.startPrank(adapter);
        tokenIn.approve(address(capability), 0);
        vm.expectRevert();
        capability.convert(address(tokenIn), 100, address(tokenOut), params);
        vm.stopPrank();

        assertGt(settlement.preSignature(oldUid), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), oldUid);
        assertEq(tokenIn.balanceOf(address(capability)), 100);
        assertEq(tokenIn.balanceOf(adapter), 900);
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), 100);
    }

    function test_InvalidateClearsSignatureAndKeepsFundingUntilRecoveryClearsAllowance() public {
        bytes memory uid = _convert(100, _params(90));

        vm.prank(adapter);
        capability.invalidateConvert(address(tokenIn));

        assertEq(settlement.preSignature(uid), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), bytes(""));
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), 100);
        assertEq(tokenIn.balanceOf(address(capability)), 100);

        vm.prank(adapter);
        assertEq(capability.recover(address(tokenIn)), 100);
        assertEq(tokenIn.balanceOf(adapter), 1000);
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), 0);
    }

    function test_InvalidatePausedTokenPreventsOldOrderFromFillingAfterResume() public {
        (CoWCapabilityPausedTokenMock pausedToken, bytes memory uid) = _pausedPartialFill();

        vm.prank(adapter);
        capability.invalidateConvert(address(pausedToken));

        assertEq(settlement.preSignature(uid), 0);
        assertEq(capability.activeOrderUid(address(pausedToken)), bytes(""));
        assertEq(pausedToken.allowance(address(capability), settlement.vaultRelayer()), 60);
        assertEq(pausedToken.balanceOf(address(capability)), 60);

        pausedToken.setPaused(false);
        vm.expectRevert("GPv2: order not presigned");
        settlement.consumePresignedSellTokens(uid, address(pausedToken), 60);
        assertEq(pausedToken.balanceOf(address(capability)), 60);
        assertEq(pausedToken.balanceOf(address(settlement)), 40);
    }

    function test_PausedRecoveryCannotUndoCancellationAndSucceedsAfterResume() public {
        (CoWCapabilityPausedTokenMock pausedToken, bytes memory uid) = _pausedPartialFill();
        vm.prank(adapter);
        capability.invalidateConvert(address(pausedToken));

        vm.prank(adapter);
        vm.expectRevert(CoWCapabilityPausedTokenMock.TokenPaused.selector);
        capability.recover(address(pausedToken));

        assertEq(settlement.preSignature(uid), 0);
        assertEq(capability.activeOrderUid(address(pausedToken)), bytes(""));
        assertEq(pausedToken.balanceOf(address(capability)), 60);
        pausedToken.setPaused(false);

        vm.prank(adapter);
        assertEq(capability.recover(address(pausedToken)), 60);
        assertEq(pausedToken.balanceOf(adapter), 60);
        assertEq(pausedToken.balanceOf(address(capability)), 0);
        assertEq(pausedToken.allowance(address(capability), settlement.vaultRelayer()), 0);
        assertEq(settlement.preSignature(uid), 0);
    }

    function testFuzz_RecoverPartialFillReturnsAllUnusedTokensAndRevokesOrder(uint256 sold) public {
        sold = bound(sold, 0, 100);
        bytes memory uid = _convert(100, _params(90));
        settlement.consumeSellTokens(address(tokenIn), address(capability), sold);

        vm.prank(adapter);
        uint256 recovered = capability.recover(address(tokenIn));

        assertEq(recovered, 100 - sold);
        assertEq(settlement.preSignature(uid), 0);
        assertEq(capability.activeOrderUid(address(tokenIn)), bytes(""));
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), 0);
        assertEq(tokenIn.balanceOf(address(capability)), 0);
        assertEq(tokenIn.balanceOf(adapter), 1000 - sold);
        assertEq(tokenIn.balanceOf(address(settlement)), sold);
    }

    function test_RecoverExpiredOrderAndAccidentallyReceivedBuyTokens() public {
        bytes memory uid = _convert(100, _params(90));
        tokenOut.transfer(address(capability), 73);
        vm.warp(2801);

        vm.startPrank(adapter);
        assertEq(capability.recover(address(tokenIn)), 100);
        assertEq(capability.recover(address(tokenOut)), 73);
        assertEq(capability.recover(address(tokenOut)), 0);
        vm.stopPrank();

        assertEq(settlement.preSignature(uid), 0);
        assertEq(tokenIn.balanceOf(adapter), 1000);
        assertEq(tokenOut.balanceOf(adapter), 73);
    }

    function test_RecoveryOfOneSellTokenLeavesOtherOrderAuthorized() public {
        bytes memory firstUid = _convert(100, _params(90));
        tokenOut.transfer(adapter, 200);
        ICoWSwapCapability.OrderParams memory params = _params(190);
        vm.startPrank(adapter);
        tokenOut.approve(address(capability), 200);
        bytes memory secondUid = capability.convert(address(tokenOut), 200, address(tokenIn), params);
        capability.recover(address(tokenIn));
        vm.stopPrank();

        assertEq(settlement.preSignature(firstUid), 0);
        assertGt(settlement.preSignature(secondUid), 0);
        assertEq(tokenOut.balanceOf(address(capability)), 200);
        assertEq(tokenOut.allowance(address(capability), settlement.vaultRelayer()), 200);
    }

    function test_MigrationPreservesOrderAuthorizationAndRecovery() public {
        bytes memory uid = _convert(100, _params(90));
        factory.whitelist(address(new CoWSwapCapability(address(factory), address(settlement))));

        vm.prank(owner);
        factory.migrate(address(capability), 2, "");

        assertEq(capability.adapter(), adapter);
        assertEq(capability.activeOrderUid(address(tokenIn)), uid);
        vm.prank(adapter);
        assertEq(capability.recover(address(tokenIn)), 100);
        assertEq(settlement.preSignature(uid), 0);
        assertEq(tokenIn.balanceOf(adapter), 1000);
    }

    function test_MigrationRejectsUnexpectedData() public {
        factory.whitelist(address(new CoWSwapCapability(address(factory), address(settlement))));

        vm.prank(owner);
        vm.expectRevert(ICoWSwapCapability.InvalidMigrationData.selector);
        factory.migrate(address(capability), 2, abi.encode(adapter));
    }

    function test_MigrationRejectsChangedSettlementAndKeepsExistingOrderRecoverable() public {
        bytes memory uid = _convert(100, _params(90));
        CoWCapabilitySettlementMock otherSettlement = new CoWCapabilitySettlementMock();
        factory.whitelist(address(new CoWSwapCapability(address(factory), address(otherSettlement))));

        vm.prank(owner);
        vm.expectRevert(ICoWSwapCapability.IncompatibleSettlement.selector);
        factory.migrate(address(capability), 2, "");

        assertEq(capability.version(), 1);
        assertEq(capability.COW_SWAP_SETTLEMENT(), address(settlement));
        vm.prank(adapter);
        assertEq(capability.recover(address(tokenIn)), 100);
        assertEq(settlement.preSignature(uid), 0);
        assertEq(tokenIn.allowance(address(capability), settlement.vaultRelayer()), 0);
    }

    function test_ConstructorRejectsSettlementWithoutCode() public {
        vm.expectRevert(ICoWSwapCapability.InvalidSettlement.selector);
        new CoWSwapCapability(address(factory), address(0));

        address undeployedSettlement = makeAddr("undeployed settlement");
        vm.expectRevert(ICoWSwapCapability.InvalidSettlement.selector);
        new CoWSwapCapability(address(factory), undeployedSettlement);
    }

    function test_ConstructorRejectsSettlementReturningRelayerWithoutCode() public {
        CoWCapabilitySettlementWithoutRelayerMock missingRelayer = new CoWCapabilitySettlementWithoutRelayerMock();

        vm.expectRevert(ICoWSwapCapability.InvalidSettlement.selector);
        new CoWSwapCapability(address(factory), address(missingRelayer));
    }

    function test_CallbackThroughAdapterCannotReenterRecoveryDuringFunding() public {
        CoWCapabilityCallbackTokenMock callbackToken = new CoWCapabilityCallbackTokenMock();
        CoWCapabilityCallbackAdapterMock callbackAdapter = new CoWCapabilityCallbackAdapterMock();
        CoWSwapCapability callbackCapability =
            CoWSwapCapability(factory.create(1, owner, abi.encode(address(callbackAdapter))));
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

    function _convert(uint256 amountIn, ICoWSwapCapability.OrderParams memory params)
        internal
        returns (bytes memory uid)
    {
        vm.prank(adapter);
        uid = capability.convert(address(tokenIn), amountIn, address(tokenOut), params);
    }

    function _pausedPartialFill() internal returns (CoWCapabilityPausedTokenMock pausedToken, bytes memory uid) {
        pausedToken = new CoWCapabilityPausedTokenMock();
        pausedToken.transfer(adapter, 100);
        ICoWSwapCapability.OrderParams memory params = _params(90);
        vm.startPrank(adapter);
        pausedToken.approve(address(capability), 100);
        uid = capability.convert(address(pausedToken), 100, address(tokenOut), params);
        vm.stopPrank();
        settlement.consumePresignedSellTokens(uid, address(pausedToken), 40);
        pausedToken.setPaused(true);
    }

    function _params(uint256 buyAmount) internal view returns (ICoWSwapCapability.OrderParams memory) {
        return ICoWSwapCapability.OrderParams({
            buyAmount: buyAmount, validTo: uint32(block.timestamp + 1800), appData: keccak256("CoW capability")
        });
    }
}

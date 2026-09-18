// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {BorrowCapability} from "src/contracts/merkle_adapter/BorrowCapability.sol";
import {CoWPositionExecutor} from "src/contracts/periphery/CoWPositionExecutor.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {
    COW_SWAP_BALANCE_ERC20,
    COW_SWAP_KIND_SELL,
    COW_SWAP_ORDER_TYPEHASH,
    ICoWSwapConverter
} from "src/interfaces/common/ICoWSwapConverter.sol";
import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {ICoWPositionExecutor} from "src/interfaces/periphery/ICoWPositionExecutor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vm} from "forge-std/Vm.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/BorrowCapabilityMocks.sol";
import {CapabilityTestBase} from "test/adapters/merkle-adapter/CapabilityTestBase.sol";
import {Token} from "test/mocks/Token.sol";

contract CoWPositionExecutorTest is CapabilityTestBase {
    Token internal debt;
    Token internal collateral;
    CoWPositionExecutor internal executor;
    PositionLender internal lender;
    PositionRouter internal router;
    PositionSettlement internal settlement;
    PositionVenue internal venue;
    uint256 private sequenceNonce;

    function setUp() public {
        debt = new Token("Debt");
        collateral = new Token("Collateral");
        _deployAdapter(address(debt));
        venue = new PositionVenue(debt, collateral);
        _installCapability(adapter, address(new BorrowCapability()), _borrowSelectors());
        _setHealthFactor(keccak256(abi.encode(_healthCall().target, _healthCall().data)), 2e18);
        lender = new PositionLender();
        settlement = new PositionSettlement();
        router = new PositionRouter(settlement, lender);
        executor = new CoWPositionExecutor(address(this), address(adapter), address(router), address(lender));
        debt.transfer(address(lender), 100_000e18);
        debt.transfer(address(venue), 100_000e18);
        collateral.transfer(address(venue), 100e18);
        debt.transfer(address(settlement), 100_000e18);
        collateral.transfer(address(settlement), 100e18);
        debt.transfer(address(adapter), 25e18);
        collateral.transfer(address(adapter), 3e18);
        venue.seed(address(adapter), 10e18, 0);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.sequenceArm.selector;
        selectors[1] = this.sequenceExecute.selector;
        selectors[2] = this.sequenceExpireAndRearm.selector;
        selectors[3] = this.sequenceRearmCompleted.selector;
        targetSelector(FuzzSelector(address(this), selectors));
        targetContract(address(this));
    }

    function test_ConstructorAcceptsZeroOwnerAdapterAndLender() public {
        executor = new CoWPositionExecutor(address(0), address(0), address(router), address(0));
        assertEq(executor.owner(), address(0));
        assertEq(executor.adapter(), address(0));
        assertEq(executor.lender(), address(0));
        assertEq(executor.router(), address(router));
        assertEq(executor.settlement(), address(settlement));
        assertEq(executor.vaultRelayer(), address(settlement));
    }

    function test_UnarmedExecutorHasNoOrderOrValidSignature() public view {
        assertEq(executor.orderUid(), hex"");
        assertFalse(executor.active());
        assertEq(executor.isValidSignature(bytes32(0), ""), bytes4(0xffffffff));
    }

    /// forge-config: default.isolate = true
    function test_GasArm() public {
        executor.arm(_intent(true));
        vm.snapshotGasLastCall("CoWPositionExecutor", "arm");
    }

    /// forge-config: default.isolate = true
    function test_GasArmExpiredReplacement() public {
        ICoWPositionExecutor.Intent memory original = _intent(true);
        executor.arm(original);
        vm.warp(uint256(original.order.validTo) + 1);
        executor.arm(_intent(false));
        vm.snapshotGasLastCall("CoWPositionExecutor", "arm_expiredReplacement");
    }

    /// forge-config: default.isolate = true
    function test_GasLeverageCallbacks() public {
        executor.arm(_intent(true));
        lender.setGasSnapshot("executeOperation_leverage");
        router.setGasSnapshot("flashLoanAndCallBack_leverage");
        router.run(executor, 2e18);
    }

    /// forge-config: default.isolate = true
    function test_GasDeleverageCallbacks() public {
        venue.seed(address(adapter), 10e18, 1000e18);
        executor.arm(_intent(false));
        lender.setGasSnapshot("executeOperation_deleverage");
        router.setGasSnapshot("flashLoanAndCallBack_deleverage");
        router.run(executor, 1005e18);
    }

    /// forge-config: default.isolate = true
    function test_GasReadFunctions() public {
        assertFalse(executor.active());
        vm.snapshotGasLastCall("CoWPositionExecutor", "active_inactive");
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        bytes32 hash = executor.orderHash();
        assertEq(executor.owner(), address(this));
        vm.snapshotGasLastCall("CoWPositionExecutor", "owner");
        assertEq(executor.adapter(), address(adapter));
        vm.snapshotGasLastCall("CoWPositionExecutor", "adapter");
        assertEq(executor.router(), address(router));
        vm.snapshotGasLastCall("CoWPositionExecutor", "router");
        assertEq(executor.lender(), address(lender));
        vm.snapshotGasLastCall("CoWPositionExecutor", "lender");
        assertEq(executor.settlement(), address(settlement));
        vm.snapshotGasLastCall("CoWPositionExecutor", "settlement");
        assertEq(executor.vaultRelayer(), address(settlement));
        vm.snapshotGasLastCall("CoWPositionExecutor", "vaultRelayer");
        assertTrue(executor.active());
        vm.snapshotGasLastCall("CoWPositionExecutor", "active_live");
        assertEq(executor.orderHash(), hash);
        vm.snapshotGasLastCall("CoWPositionExecutor", "orderHash");
        assertEq(executor.lastCompletedOrderHash(), bytes32(0));
        vm.snapshotGasLastCall("CoWPositionExecutor", "lastCompletedOrderHash");
        executor.orderUid();
        vm.snapshotGasLastCall("CoWPositionExecutor", "orderUid");
        executor.getIntent();
        vm.snapshotGasLastCall("CoWPositionExecutor", "getIntent");
        assertEq(executor.isValidSignature(hash, ""), bytes4(0x1626ba7e));
        vm.snapshotGasLastCall("CoWPositionExecutor", "isValidSignature_valid");
        assertEq(executor.isValidSignature(bytes32(uint256(1)), ""), bytes4(0xffffffff));
        vm.snapshotGasLastCall("CoWPositionExecutor", "isValidSignature_invalid");
        vm.warp(uint256(intent.order.validTo) + 1);
        assertFalse(executor.active());
        vm.snapshotGasLastCall("CoWPositionExecutor", "active_expired");
    }

    function test_FrontendCanonicalOrderVector() public pure {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                uint256(1),
                address(0x7777777777777777777777777777777777777777)
            )
        );
        ICoWSwapConverter.Data memory order = ICoWSwapConverter.Data({
            sellToken: address(0x4444444444444444444444444444444444444444),
            buyToken: address(0x3333333333333333333333333333333333333333),
            receiver: address(0x2222222222222222222222222222222222222222),
            sellAmount: 1000,
            buyAmount: 500,
            validTo: 2_000_000_000,
            appData: bytes32(0),
            feeAmount: 0,
            kind: COW_SWAP_KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: COW_SWAP_BALANCE_ERC20,
            buyTokenBalance: COW_SWAP_BALANCE_ERC20
        });
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(COW_SWAP_ORDER_TYPEHASH, order))));
        assertEq(digest, bytes32(0xa6d18f32f08969b42503670d27be526578821c390d0867757ad0ea1057ad8d3c));
        assertEq(
            abi.encodePacked(digest, order.receiver, order.validTo),
            hex"a6d18f32f08969b42503670d27be526578821c390d0867757ad0ea1057ad8d3c222222222222222222222222222222222222222277359400"
        );
    }

    function testFuzz_GPv2OrderHashMatchesCanonicalEncodingAndPreservesMemory(
        GPv2Order.Data memory order,
        bytes32 domain
    ) public pure {
        bytes memory original = abi.encode(order);
        bytes32 typeHash = keccak256(
            "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(typeHash, order))));
        bytes32 precedingBefore;
        bytes32 precedingAfter;
        uint256 freeMemoryBefore;
        uint256 freeMemoryAfter;
        assembly {
            precedingBefore := mload(sub(order, 32))
            freeMemoryBefore := mload(0x40)
        }
        bytes32 actual = GPv2Order.hash(order, domain);
        assembly {
            precedingAfter := mload(sub(order, 32))
            freeMemoryAfter := mload(0x40)
        }
        assertEq(actual, expected);
        assertEq(precedingAfter, precedingBefore);
        assertEq(freeMemoryAfter, freeMemoryBefore);
        assertEq(abi.encode(order), original);
        assertEq(GPv2Order.hash(order, domain), expected);
    }

    function testFuzz_ArmedHashAndUidMatchCanonicalOrder(
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData,
        bool leverage
    ) public {
        ICoWPositionExecutor.Intent memory intent = _intent(leverage);
        intent.order.sellAmount = bound(sellAmount, 1, type(uint256).max);
        intent.order.buyAmount = bound(buyAmount, 1, type(uint256).max);
        intent.order.validTo = validTo;
        intent.order.appData = appData;
        bytes memory uid = executor.arm(intent);
        ICoWSwapConverter.Data memory canonical = ICoWSwapConverter.Data({
            sellToken: intent.order.sellToken,
            buyToken: intent.order.buyToken,
            receiver: address(executor),
            sellAmount: intent.order.sellAmount,
            buyAmount: intent.order.buyAmount,
            validTo: intent.order.validTo,
            appData: intent.order.appData,
            feeAmount: 0,
            kind: keccak256("sell"),
            partiallyFillable: false,
            sellTokenBalance: keccak256("erc20"),
            buyTokenBalance: keccak256("erc20")
        });
        bytes32 typeHash = keccak256(
            "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
        );
        bytes32 expected = keccak256(
            abi.encodePacked("\x19\x01", settlement.domainSeparator(), keccak256(abi.encode(typeHash, canonical)))
        );
        assertEq(executor.orderHash(), expected);
        assertEq(uid, abi.encodePacked(expected, address(executor), validTo));
        assertEq(executor.orderUid(), uid);
    }

    function test_ArmCommitsSignatureWithoutFlashContextAndBoundsAllowance() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        vm.recordLogs();
        bytes memory uid = executor.arm(intent);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory armLog = logs[logs.length - 1];
        assertEq(armLog.emitter, address(executor));
        assertEq(armLog.topics[0], ICoWPositionExecutor.Arm.selector);
        assertEq(armLog.topics[1], executor.orderHash());
        (bytes memory emittedUid, ICoWPositionExecutor.Intent memory emittedIntent) =
            abi.decode(armLog.data, (bytes, ICoWPositionExecutor.Intent));
        assertEq(emittedUid, uid);
        assertEq(abi.encode(emittedIntent), abi.encode(intent));
        assertEq(uid.length, 56);
        assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0x1626ba7e));
        assertEq(debt.allowance(address(executor), address(settlement)), 1000e18);
        assertEq(executor.isValidSignature(bytes32(uint256(1)), ""), bytes4(0xffffffff));
        assertEq(executor.isValidSignature(executor.orderHash(), hex"01"), bytes4(0x1626ba7e));
    }

    function test_LeverageSettlesBeforeMandatorySupplyBorrowAndPreservesIdleFunds() public {
        executor.arm(_intent(true));
        uint256 beforeLender = debt.balanceOf(address(lender));
        vm.expectEmit(true, false, false, true, address(executor));
        emit ICoWPositionExecutor.FlashLoanAndCallBack(executor.orderHash(), 1000e18, 1e18);
        router.run(executor, 2e18);
        assertEq(venue.collateralOf(address(adapter)), 12e18);
        assertEq(venue.debtOf(address(adapter)), 1001e18);
        assertEq(debt.balanceOf(address(lender)), beforeLender + 1e18);
        assertEq(debt.balanceOf(address(adapter)), 25e18);
        assertEq(collateral.balanceOf(address(adapter)), 3e18);
        assertEq(debt.balanceOf(address(executor)), 0);
        assertEq(collateral.balanceOf(address(executor)), 0);
        assertEq(debt.allowance(address(executor), address(settlement)), 0);
        assertEq(debt.allowance(address(executor), address(lender)), 0);
        assertFalse(executor.active());
        assertEq(executor.lastCompletedOrderHash(), executor.orderHash());
        assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0xffffffff));
    }

    function test_DeleverageRepaysBeforeWithdrawAndReturnsExcessOutput() public {
        venue.seed(address(adapter), 10e18, 1000e18);
        executor.arm(_intent(false));
        vm.expectEmit(true, false, false, true, address(executor));
        emit ICoWPositionExecutor.FlashLoanAndCallBack(executor.orderHash(), 1000e18, 1e18);
        router.run(executor, 1005e18);
        assertEq(venue.debtOf(address(adapter)), 0);
        assertEq(venue.collateralOf(address(adapter)), 8e18);
        assertEq(debt.balanceOf(address(adapter)), 29e18);
        assertEq(collateral.balanceOf(address(adapter)), 3e18);
        assertFalse(executor.active());
    }

    function testFuzz_LeverageReturnsPriceImprovementToStrategy(uint96 extra) public {
        extra = uint96(bound(extra, 1, 20e18));
        executor.arm(_intent(true));
        router.run(executor, 2e18 + extra);
        assertEq(collateral.balanceOf(address(adapter)), 3e18 + extra);
        assertEq(venue.collateralOf(address(adapter)), 12e18);
    }

    function test_CuratorCanRaiseMinimumAfterArmingAndRevertTradeAndPosition() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        _setHealthFactor(keccak256(abi.encode(_healthCall().target, _healthCall().data)), 100e18);
        vm.expectRevert(IBorrowCapability.HealthFactorTooLow.selector);
        router.run(executor, 2e18);
        _assertUnchanged();
        assertEq(settlement.filledAmount(executor.orderUid()), 0);
    }

    function test_ExecutorLendingRolesDoNotGrantMinimumUpdates() public {
        executor.arm(_intent(true));
        IMerkleAdapter.Action[] memory calls = _minimumCalls(1);
        vm.prank(address(executor));
        vm.expectRevert();
        adapter.manage(calls);
        assertEq(
            IBorrowCapability(address(adapter))
                .minHealthFactor(keccak256(abi.encode(_healthCall().target, _healthCall().data))),
            2e18
        );
    }

    function test_BorrowAmountCanChangeUnderSameApprovedLeaf() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        bytes32 approvedLeaf = _leaf(intent.actions[2]);
        intent.actions[2].data = _checkedAction(1002e18, PositionVenue.borrow.selector).data;
        assertEq(_leaf(intent.actions[2]), approvedLeaf);
        executor.arm(intent);
        router.run(executor, 2e18);
        assertEq(venue.debtOf(address(adapter)), 1002e18);
        assertEq(debt.balanceOf(address(adapter)), 26e18);
        assertFalse(executor.active());
    }

    function test_RevertWhenIntentOrderNotFilled() public {
        executor.arm(_intent(true));
        settlement.setSkipFill(true);
        vm.expectRevert(ICoWPositionExecutor.OrderNotFilled.selector);
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function test_RevertWhenOutputBelowCommittedMinimum() public {
        executor.arm(_intent(true));
        vm.expectRevert("GPv2: limit price not respected");
        router.run(executor, 1e18);
        _assertUnchanged();
    }

    function test_RevertWhenPremiumExceedsCommittedMaximum() public {
        executor.arm(_intent(true));
        lender.setPremium(2e18);
        vm.expectRevert(ICoWPositionExecutor.InvalidLoan.selector);
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function test_RevertWhenCurrentLeafRoleRevoked() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        adapter.revokeRole(_leaf(intent.actions[2]), address(executor));
        vm.expectRevert();
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function test_ChangedRootKeepsSignatureValidButRejectsInvalidProofs() public {
        executor.arm(_intent(true));
        roots.setRoot(address(adapter), bytes32(uint256(100)));
        adapter.acceptRoot(bytes32(uint256(100)));
        assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0x1626ba7e));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        router.run(executor, 2e18);
        _assertUnchanged();
        assertEq(settlement.filledAmount(executor.orderUid()), 0);
    }

    function test_AuthorizedActionCanChangeRootWithoutInvalidatingExecution() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.actions[3] = _action(address(this), abi.encodeCall(this.transferRepaymentAndChangeRoot, ()));
        _publish(intent);
        vm.prank(address(adapter));
        debt.approve(address(this), 1001e18);
        executor.arm(intent);
        router.run(executor, 2e18);
        assertEq(adapter.merkleRoot(), bytes32(uint256(100)));
        assertEq(venue.debtOf(address(adapter)), 1001e18);
        assertEq(venue.collateralOf(address(adapter)), 12e18);
        assertEq(debt.balanceOf(address(adapter)), 25e18);
        assertEq(debt.balanceOf(address(lender)), 100_001e18);
        assertEq(executor.lastCompletedOrderHash(), executor.orderHash());
    }

    function transferRepaymentAndChangeRoot() external {
        require(address(adapter) == msg.sender);
        debt.transferFrom(address(adapter), address(executor), 1001e18);
        roots.setRoot(address(adapter), bytes32(uint256(100)));
        adapter.acceptRoot(bytes32(uint256(100)));
    }

    function test_RevertWhenProgramSubsidizesRepaymentFromIdleBalance() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.actions[2] = _checkedAction(1000e18, PositionVenue.borrow.selector);
        _publish(intent);
        executor.arm(intent);
        vm.expectRevert(ICoWPositionExecutor.AdapterBalanceReduced.selector);
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function test_RevertWhenCallerIsNotRouter() public {
        executor.arm(_intent(true));
        vm.expectRevert(ICoWPositionExecutor.Unauthorized.selector);
        executor.flashLoanAndCallBack(address(lender), address(debt), 1000e18, "");
    }

    function testFuzz_ThirdPartyCannotInitiateExecutorLoan(bool armed) public {
        if (armed) executor.arm(_intent(true));
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = address(debt);
        amounts[0] = 1000e18;
        vm.expectRevert(ICoWPositionExecutor.InvalidCallback.selector);
        lender.flashLoan(address(executor), assets, amounts, new uint256[](1), address(executor), "", 0);
        assertEq(debt.balanceOf(address(executor)), 0);
        assertEq(debt.balanceOf(address(lender)), 100_000e18);
    }

    function test_ExpiredIntentIsInactiveAndCanBeReplacedWithoutCancellation() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        bytes32 expiredHash = executor.orderHash();
        vm.warp(uint256(intent.order.validTo) + 1);
        assertFalse(executor.active());
        intent.order.validTo = uint32(block.timestamp + 600);
        executor.arm(intent);
        assertTrue(executor.active());
        assertNotEq(executor.orderHash(), expiredHash);
        assertEq(executor.isValidSignature(expiredHash, ""), bytes4(0xffffffff));
    }

    function test_MalformedActionMaskArmsButSettlementRevertsAtomically() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.actions[0].dataMask = hex"00";
        executor.arm(intent);
        vm.expectRevert();
        router.run(executor, 2e18);
        _assertUnchanged();
        assertEq(settlement.filledAmount(executor.orderUid()), 0);
    }

    function test_ExecutionReturnsDonatedOrderTokensToAdapter() public {
        executor.arm(_intent(true));
        debt.transfer(address(executor), 7);
        collateral.transfer(address(executor), 11);
        router.run(executor, 2e18);
        assertEq(debt.balanceOf(address(adapter)), 25e18 + 7);
        assertEq(collateral.balanceOf(address(adapter)), 3e18 + 11);
        assertFalse(executor.active());
    }

    function test_CapabilityRejectsWithdrawalBelowCuratorMinimum() public {
        venue.seed(address(adapter), 10e18, 2000e18);
        executor.arm(_intent(false));
        _setHealthFactor(keccak256(abi.encode(_healthCall().target, _healthCall().data)), 9e18);
        vm.expectRevert(IBorrowCapability.HealthFactorTooLow.selector);
        router.run(executor, 1005e18);
        assertEq(venue.collateralOf(address(adapter)), 10e18);
        assertEq(venue.debtOf(address(adapter)), 2000e18);
        assertEq(settlement.filledAmount(executor.orderUid()), 0);
        assertEq(debt.balanceOf(address(lender)), 100_000e18);
        assertTrue(executor.active());
    }

    function test_RevertWhenOwnerRearmsDuringFlashLoan() public {
        lender = new PositionReentrantLender();
        router = new PositionRouter(settlement, lender);
        executor = new CoWPositionExecutor(address(this), address(adapter), address(router), address(lender));
        debt.transfer(address(lender), 100_000e18);
        executor.arm(_intent(true));
        vm.expectRevert(ICoWPositionExecutor.InvalidCallback.selector);
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function test_RevertWhenRouterRequestsSecondLoanDuringSettlement() public {
        router = new PositionReentrantRouter(address(settlement), address(lender));
        executor = new CoWPositionExecutor(address(this), address(adapter), address(router), address(lender));
        executor.arm(_intent(true));
        vm.expectRevert(ICoWPositionExecutor.InvalidCallback.selector);
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function reenterArm() external {
        executor.arm(executor.getIntent());
    }

    function test_RevertWhenNotOwnerArms() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        vm.prank(address(0xbeef));
        vm.expectRevert(ICoWPositionExecutor.Unauthorized.selector);
        executor.arm(intent);
    }

    function testFuzz_RejectZeroOrderAmount(bool zeroSell) public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        if (zeroSell) intent.order.sellAmount = 0;
        else intent.order.buyAmount = 0;
        vm.expectRevert(ICoWPositionExecutor.InvalidIntent.selector);
        executor.arm(intent);
    }

    function testFuzz_SameTokenOrderArmsButCannotSettle(uint96 output) public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.order.buyToken = intent.order.sellToken;
        executor.arm(intent);
        vm.expectRevert();
        router.run(executor, bound(output, intent.order.buyAmount, 2000e18));
        _assertUnchanged();
        assertEq(settlement.filledAmount(executor.orderUid()), 0);
    }

    function testFuzz_RejectNonzeroNativeValue(uint96 value) public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.actions[0].value = uint96(bound(value, 1, type(uint96).max));
        vm.expectRevert(ICoWPositionExecutor.InvalidIntent.selector);
        executor.arm(intent);
    }

    function test_RejectNativeValueWithOnlyHighBitSet() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.actions[0].value = uint96(1) << 95;
        vm.expectRevert(ICoWPositionExecutor.InvalidIntent.selector);
        executor.arm(intent);
    }

    function test_ArmedIntentCannotBeOverwritten() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        vm.expectRevert(ICoWPositionExecutor.ActiveIntent.selector);
        executor.arm(intent);
    }

    function test_ExpiredIntentInvalidatesSignatureAndExecution() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        vm.warp(intent.order.validTo);
        assertTrue(executor.active());
        assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0x1626ba7e));
        vm.warp(uint256(intent.order.validTo) + 1);
        assertFalse(executor.active());
        assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0xffffffff));
        vm.expectRevert("GPv2: invalid eip1271 signature");
        router.run(executor, 2e18);
        assertEq(executor.lastCompletedOrderHash(), bytes32(0));
    }

    function test_CompletedOrderCannotReactivateAndFreshOrderCanReplaceIt() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        router.run(executor, 2e18);
        bytes32 completedHash = executor.orderHash();
        executor.arm(intent);
        assertFalse(executor.active());
        assertEq(debt.allowance(address(executor), address(settlement)), 0);
        assertEq(executor.isValidSignature(completedHash, ""), bytes4(0xffffffff));
        vm.expectRevert("GPv2: invalid eip1271 signature");
        router.run(executor, 2e18);
        assertEq(executor.lastCompletedOrderHash(), completedHash);
        assertEq(venue.debtOf(address(adapter)), 1001e18);
        assertEq(venue.collateralOf(address(adapter)), 12e18);
        intent.order.appData = keccak256("fresh order");
        executor.arm(intent);
        assertTrue(executor.active());
        router.run(executor, 2e18);
        assertEq(venue.debtOf(address(adapter)), 2002e18);
        assertEq(venue.collateralOf(address(adapter)), 14e18);
    }

    function test_ExpiredReplacementAcrossSellTokensClearsOldApprovalAndSignature() public {
        ICoWPositionExecutor.Intent memory original = _intent(true);
        executor.arm(original);
        bytes32 expiredHash = executor.orderHash();
        vm.warp(uint256(original.order.validTo) + 1);
        venue.seed(address(adapter), 10e18, 1000e18);
        ICoWPositionExecutor.Intent memory replacement = _intent(false);
        executor.arm(replacement);
        assertEq(debt.allowance(address(executor), address(settlement)), 0);
        assertEq(collateral.allowance(address(executor), address(settlement)), 2e18);
        assertEq(executor.isValidSignature(expiredHash, ""), bytes4(0xffffffff));
        assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0x1626ba7e));
        router.run(executor, 1001e18);
        assertEq(venue.debtOf(address(adapter)), 0);
        assertFalse(executor.active());
    }

    function testFuzz_RouterMetadataCannotChangeCommittedLoan(bool leverage, address token, uint256 amount) public {
        if (!leverage) venue.seed(address(adapter), 10e18, 1000e18);
        executor.arm(_intent(leverage));
        uint256 lenderBefore = debt.balanceOf(address(lender));
        vm.expectEmit(true, false, false, true, address(executor));
        emit ICoWPositionExecutor.FlashLoanAndCallBack(executor.orderHash(), 1000e18, 1e18);
        router.runWithLoanMetadata(executor, leverage ? 2e18 : 1005e18, token, amount);
        assertEq(debt.balanceOf(address(lender)), lenderBefore + 1e18);
        assertEq(venue.debtOf(address(adapter)), leverage ? 1001e18 : 0);
        assertEq(venue.collateralOf(address(adapter)), leverage ? 12e18 : 8e18);
        assertEq(debt.balanceOf(address(executor)), 0);
        assertEq(collateral.balanceOf(address(executor)), 0);
        assertFalse(executor.active());
        assertEq(executor.lastCompletedOrderHash(), executor.orderHash());
    }

    function test_RouterLenderMetadataCannotChangeImmutableLender() public {
        router = new PositionRouter(settlement, PositionLender(address(0xbeef)));
        executor = new CoWPositionExecutor(address(this), address(adapter), address(router), address(lender));
        executor.arm(_intent(true));
        router.run(executor, 2e18);
        assertEq(debt.balanceOf(address(lender)), 100_001e18);
        assertEq(debt.balanceOf(address(0xbeef)), 0);
        assertEq(venue.debtOf(address(adapter)), 1001e18);
        assertEq(executor.lastCompletedOrderHash(), executor.orderHash());
    }

    function testFuzz_ModifiedLenderCallbackIsRejected(uint8 variant) public {
        executor.arm(_intent(true));
        variant = uint8(bound(variant, 1, 2));
        lender.setInvalidCallback(variant);
        vm.expectRevert();
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function testFuzz_UnusedLenderCallbackMetadataCannotChangeCommittedLoan(uint8 variant) public {
        executor.arm(_intent(true));
        lender.setInvalidCallback(uint8(bound(variant, 3, 4)));
        router.run(executor, 2e18);
        assertEq(venue.debtOf(address(adapter)), 1001e18);
        assertEq(venue.collateralOf(address(adapter)), 12e18);
        assertEq(debt.balanceOf(address(executor)), 0);
        assertEq(executor.lastCompletedOrderHash(), executor.orderHash());
    }

    function test_RevertWhenUnauthenticatedLenderSpoofsCallback() public {
        executor.arm(_intent(true));
        vm.expectRevert(ICoWPositionExecutor.InvalidCallback.selector);
        executor.executeOperation(new address[](0), new uint256[](0), new uint256[](0), address(executor), "");
    }

    function test_RearmedFilledOrderCannotCompleteWhenSettlementOmitsIt() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        executor.arm(intent);
        router.run(executor, 2e18);
        bytes32 completedHash = executor.orderHash();
        executor.arm(intent);
        settlement.setSkipFill(true);
        vm.expectRevert(ICoWPositionExecutor.OrderNotFilled.selector);
        router.run(executor, 2e18);
        assertEq(executor.lastCompletedOrderHash(), completedHash);
        assertEq(settlement.filledAmount(executor.orderUid()), intent.order.sellAmount);
        assertEq(venue.debtOf(address(adapter)), 1001e18);
        assertEq(venue.collateralOf(address(adapter)), 12e18);
        assertEq(debt.balanceOf(address(lender)), 100_001e18);
        assertEq(debt.balanceOf(address(executor)), 0);
        assertFalse(executor.active());
    }

    function testFuzz_InsufficientCommittedLoanArmsButExecutionRollsBack(uint256 amount) public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.loanAmount = bound(amount, 0, intent.order.sellAmount - 1);
        executor.arm(intent);
        vm.expectRevert();
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function test_RevertWhenLoanRepaymentIsInsufficient() public {
        ICoWPositionExecutor.Intent memory intent = _intent(true);
        intent.actions[3] = _action(address(debt), abi.encodeCall(IERC20.transfer, (address(executor), 1000e18)));
        _publish(intent);
        executor.arm(intent);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        router.run(executor, 2e18);
        _assertUnchanged();
    }

    function sequenceArm(bool leverage) external {
        if (executor.active()) return;
        if (!leverage && venue.debtOf(address(adapter)) < 1000e18) return;
        ICoWPositionExecutor.Intent memory intent = _intent(leverage);
        intent.order.appData = keccak256(abi.encode(++sequenceNonce));
        executor.arm(intent);
    }

    function sequenceExecute(uint96 surplus) external {
        if (!executor.active()) return;
        uint256 output = executor.getIntent().order.buyAmount + bound(surplus, 0, 10e18);
        try router.run(executor, output) {} catch {}
    }

    function sequenceExpireAndRearm(bool leverage) external {
        if (!executor.active()) return;
        vm.warp(uint256(executor.getIntent().order.validTo) + 1);
        this.sequenceArm(leverage);
    }

    function sequenceRearmCompleted() external {
        if (executor.orderHash() == bytes32(0) || executor.orderHash() != executor.lastCompletedOrderHash()) return;
        executor.arm(executor.getIntent());
    }

    function invariant_NoIdleStrategySubsidyOrResidualFlashCustody() public view {
        assertGe(debt.balanceOf(address(adapter)), 25e18);
        assertGe(collateral.balanceOf(address(adapter)), 3e18);
        assertGe(debt.balanceOf(address(lender)), 100_000e18);
        assertEq(debt.balanceOf(address(executor)), 0);
        assertEq(collateral.balanceOf(address(executor)), 0);
        assertEq(debt.allowance(address(executor), address(lender)), 0);
        assertGe(venue.health(address(adapter)), 2e18);
        ICoWPositionExecutor.Intent memory intent = executor.getIntent();
        if (executor.active()) {
            assertEq(
                IERC20(intent.order.sellToken).allowance(address(executor), address(settlement)),
                intent.order.sellAmount
            );
        } else if (intent.order.validTo >= block.timestamp) {
            assertEq(debt.allowance(address(executor), address(settlement)), 0);
            assertEq(collateral.allowance(address(executor), address(settlement)), 0);
        } else {
            assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0xffffffff));
        }
    }

    function _assertUnchanged() internal view {
        assertEq(venue.debtOf(address(adapter)), 0);
        assertEq(venue.collateralOf(address(adapter)), 10e18);
        assertEq(debt.balanceOf(address(adapter)), 25e18);
        assertEq(collateral.balanceOf(address(adapter)), 3e18);
        assertTrue(executor.active());
        assertEq(executor.lastCompletedOrderHash(), bytes32(0));
        assertEq(settlement.filledAmount(executor.orderUid()), 0);
        assertEq(debt.balanceOf(address(executor)), 0);
        assertEq(collateral.balanceOf(address(executor)), 0);
        assertEq(debt.balanceOf(address(lender)), 100_000e18);
        assertEq(debt.balanceOf(address(settlement)), 100_000e18);
        assertEq(collateral.balanceOf(address(settlement)), 100e18);
    }

    function _intent(bool leverage) internal returns (ICoWPositionExecutor.Intent memory intent) {
        intent.leverage = leverage;
        intent.loanAmount = 1000e18;
        intent.maxPremium = 1e18;
        intent.order = ICoWPositionExecutor.Order({
            sellToken: leverage ? address(debt) : address(collateral),
            buyToken: leverage ? address(collateral) : address(debt),
            sellAmount: leverage ? 1000e18 : 2e18,
            buyAmount: leverage ? 2e18 : 1001e18,
            validTo: uint32(block.timestamp + 600),
            appData: keccak256("position")
        });
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](4);
        if (leverage) {
            actions[0] = _action(address(collateral), abi.encodeCall(IERC20.approve, (address(venue), 2e18)));
            actions[1] = _action(address(venue), abi.encodeCall(PositionVenue.supply, (2e18)));
            actions[2] = _checkedAction(1001e18, PositionVenue.borrow.selector);
            actions[3] = _action(address(debt), abi.encodeCall(IERC20.transfer, (address(executor), 1001e18)));
            intent.actions = actions;
        } else {
            actions[0] = _action(address(debt), abi.encodeCall(IERC20.approve, (address(venue), 1000e18)));
            actions[1] = _action(address(venue), abi.encodeCall(PositionVenue.repay, (1000e18)));
            actions[2] = _checkedAction(2e18, PositionVenue.withdraw.selector);
            actions[3] = _action(address(collateral), abi.encodeCall(IERC20.transfer, (address(executor), 2e18)));
            intent.actions = actions;
        }
        _publish(intent);
    }

    function _healthCall() internal view returns (BorrowTestCall memory) {
        return BorrowTestCall(address(venue), abi.encodeCall(PositionVenue.health, (address(adapter))));
    }

    function _checkedAction(uint256 amount, bytes4 selector)
        internal
        view
        returns (IMerkleAdapter.Action memory action)
    {
        action = _action(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.borrow,
                (address(venue), _healthCall().target, abi.encodeWithSelector(selector, amount), _healthCall().data)
            )
        );
        // Only the nested lending amount varies at execution.
        for (uint256 i = 168; i < 200; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory) {
        bytes memory mask = new bytes(data.length);
        return IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        bytes memory maskedData = new bytes(action.data.length);
        for (uint256 i; i < maskedData.length; ++i) {
            maskedData[i] = action.data[i] & ~action.dataMask[i];
        }
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        action.target,
                        bytes1(action.value == 0 ? 0 : 0xff),
                        keccak256(action.dataMask),
                        keccak256(maskedData)
                    )
                )
            )
        );
    }

    function _publish(ICoWPositionExecutor.Intent memory intent) internal {
        IMerkleAdapter.Action[] memory actions = intent.actions;
        bytes32[] memory tree = new bytes32[](8);
        for (uint256 i; i < 4; ++i) {
            tree[4 + i] = _leaf(actions[i]);
            adapter.grantRole(tree[4 + i], address(executor));
        }
        for (uint256 i = 3; i > 0; --i) {
            bytes32 a = tree[i * 2];
            bytes32 b = tree[i * 2 + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        for (uint256 i; i < 4; ++i) {
            actions[i].proof = new bytes32[](2);
            actions[i].proof[0] = tree[(4 + i) ^ 1];
            actions[i].proof[1] = tree[((4 + i) / 2) ^ 1];
        }
        roots.setRoot(address(adapter), tree[1]);
        adapter.acceptRoot(tree[1]);
        _includeHealthFactorLeaf(actions, keccak256(abi.encode(_healthCall().target, _healthCall().data)));
    }
}

contract PositionVenue {
    IERC20 internal immutable debt;
    IERC20 internal immutable collateral;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    constructor(IERC20 debt_, IERC20 collateral_) {
        debt = debt_;
        collateral = collateral_;
    }

    function seed(address account, uint256 coll, uint256 amount) external {
        collateralOf[account] = coll;
        debtOf[account] = amount;
    }

    function supply(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
    }

    function borrow(uint256 amount) external {
        debtOf[msg.sender] += amount;
        require(health(msg.sender) >= 1e18);
        debt.transfer(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        debt.transferFrom(msg.sender, address(this), amount);
        debtOf[msg.sender] -= amount;
    }

    function withdraw(uint256 amount) external {
        collateralOf[msg.sender] -= amount;
        require(health(msg.sender) >= 1e18);
        collateral.transfer(msg.sender, amount);
    }

    function health(address account) public view returns (uint256) {
        return debtOf[account] == 0 ? type(uint256).max : collateralOf[account] * 1000e18 / debtOf[account];
    }
}

contract PositionLender {
    string internal _gasSnapshotName;

    uint256 public premium = 1e18;
    uint8 public invalidCallback;

    function setGasSnapshot(string calldata name) external {
        _gasSnapshotName = name;
    }

    function setInvalidCallback(uint8 value) external {
        invalidCallback = value;
    }

    function setPremium(uint256 amount) external {
        premium = amount;
    }

    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata,
        address,
        bytes calldata data,
        uint16
    ) external {
        IERC20(assets[0]).transfer(receiver, amounts[0]);
        _beforeCallback(receiver);
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = premium;
        address[] memory callbackAssets = assets;
        uint256[] memory callbackAmounts = amounts;
        if (invalidCallback == 3) callbackAssets[0] = address(this);
        if (invalidCallback == 4) callbackAmounts[0] += 1;
        require(
            ICoWPositionExecutor(receiver)
                .executeOperation(
                    callbackAssets,
                    callbackAmounts,
                    premiums,
                    invalidCallback == 1 ? address(0xbeef) : msg.sender,
                    invalidCallback == 2 ? abi.encodePacked(data, bytes1(0x01)) : data
                )
        );
        if (bytes(_gasSnapshotName).length > 0) {
            Vm(address(uint160(uint256(keccak256("hevm cheat code")))))
                .snapshotGasLastCall("CoWPositionExecutor", _gasSnapshotName);
        }
        IERC20(assets[0]).transferFrom(receiver, address(this), amounts[0] + premium);
    }

    function _beforeCallback(address) internal virtual {}
}

contract PositionReentrantLender is PositionLender {
    function _beforeCallback(address receiver) internal override {
        CoWPositionExecutorTest(ICoWPositionExecutor(receiver).owner()).reenterArm();
    }
}

contract PositionSettlement {
    mapping(bytes => uint256) public filledAmount;
    bool public skipFill;

    function domainSeparator() external pure returns (bytes32) {
        return keccak256("test-domain");
    }

    function vaultRelayer() external view returns (address) {
        return address(this);
    }

    function setSkipFill(bool skip) external {
        skipFill = skip;
    }

    function fill(ICoWPositionExecutor executor, uint256 output) external {
        if (skipFill) return;
        ICoWPositionExecutor.Intent memory intent = executor.getIntent();
        require(
            executor.isValidSignature(executor.orderHash(), "") == bytes4(0x1626ba7e), "GPv2: invalid eip1271 signature"
        );
        require(intent.order.validTo >= block.timestamp, "GPv2: order expired");
        require(filledAmount[executor.orderUid()] == 0, "GPv2: order filled");
        require(output >= intent.order.buyAmount, "GPv2: limit price not respected");
        IERC20(intent.order.sellToken).transferFrom(address(executor), address(this), intent.order.sellAmount);
        IERC20(intent.order.buyToken).transfer(address(executor), output);
        filledAmount[executor.orderUid()] = intent.order.sellAmount;
    }
}

contract PositionRouter {
    string internal _gasSnapshotName;

    address public immutable settlementContract;
    PositionLender internal immutable lender;
    address internal pending;
    bytes32 internal pendingCallbackHash;
    uint256 internal output;

    constructor(PositionSettlement settlement_, PositionLender lender_) {
        settlementContract = address(settlement_);
        lender = lender_;
    }

    function setGasSnapshot(string calldata name) external {
        _gasSnapshotName = name;
    }

    function run(ICoWPositionExecutor executor, uint256 output_) external {
        ICoWPositionExecutor.Intent memory intent = executor.getIntent();
        runWithLoanMetadata(
            executor, output_, intent.leverage ? intent.order.sellToken : intent.order.buyToken, intent.loanAmount
        );
    }

    function runWithLoanMetadata(ICoWPositionExecutor executor, uint256 output_, address token, uint256 amount) public {
        require(pending == address(0), "Another settlement in progress");
        pending = address(executor);
        output = output_;
        bytes memory data = abi.encode(address(executor));
        pendingCallbackHash = keccak256(data);
        executor.flashLoanAndCallBack(address(lender), token, amount, data);
        if (bytes(_gasSnapshotName).length > 0) {
            Vm(address(uint160(uint256(keccak256("hevm cheat code")))))
                .snapshotGasLastCall("CoWPositionExecutor", _gasSnapshotName);
        }
        require(pending == address(1), "Terminated without settling");
        pending = address(0);
    }

    function borrowerCallBack(bytes calldata data) external {
        require(pending == msg.sender, "Not the pending borrower");
        require(keccak256(data) == pendingCallbackHash, "Data from borrower not matching");
        _beforeSettlement(data);
        pending = address(1);
        PositionSettlement(settlementContract).fill(ICoWPositionExecutor(msg.sender), output);
    }

    function _beforeSettlement(bytes calldata) internal virtual {}
}

contract PositionReentrantRouter is PositionRouter {
    constructor(address newSettlement, address newLender)
        PositionRouter(PositionSettlement(newSettlement), PositionLender(newLender))
    {}

    function _beforeSettlement(bytes calldata data) internal override {
        ICoWPositionExecutor.Intent memory intent = ICoWPositionExecutor(msg.sender).getIntent();
        ICoWPositionExecutor(msg.sender)
            .flashLoanAndCallBack(
                address(lender),
                intent.leverage ? intent.order.sellToken : intent.order.buyToken,
                intent.loanAmount,
                data
            );
    }
}

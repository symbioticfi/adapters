// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BorrowAction} from "src/contracts/merkle_adapter/BorrowAction.sol";
import {IBorrowAction} from "src/interfaces/merkle_adapter/IBorrowAction.sol";
import {
    BorrowActionAdapterMock,
    BorrowActionPoolMock,
    BorrowActionTokenMock
} from "test/adapters/merkle-adapter/mocks/BorrowActionMocks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

contract BorrowActionTest is Test {
    BorrowActionTokenMock internal asset;
    BorrowActionAdapterMock internal adapter;
    BorrowActionPoolMock internal pool;
    MigratablesFactory internal factory;
    BorrowAction internal actionContract;

    function setUp() public {
        asset = new BorrowActionTokenMock();
        adapter = new BorrowActionAdapterMock();
        pool = new BorrowActionPoolMock(address(asset));
        asset.mint(address(pool), 10_000e18);
        pool.setCollateral(address(adapter), 240e18);
        factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new BorrowAction(address(factory))));
        actionContract = _create(_params());
        _delegate(address(actionContract), 1000e18);
    }

    function test_BorrowForAdapterForwardsOnlyProceedsAndAllowsExactFloor() public {
        asset.mint(address(actionContract), 7e18);
        asset.mint(address(adapter), 3e18);

        vm.expectEmit(false, false, false, true, address(actionContract));
        emit IBorrowAction.Borrow(_borrowData(200e18), 200e18, 1.2e18);
        bytes memory result = _borrow(200e18);

        assertEq(abi.decode(abi.decode(result, (bytes)), (uint256)), 200e18);
        assertEq(asset.balanceOf(address(adapter)), 203e18);
        assertEq(asset.balanceOf(address(actionContract)), 7e18);
        assertEq(pool.debt(address(adapter)), 200e18);
        assertEq(pool.debt(address(actionContract)), 0);
        assertEq(actionContract.getHealthFactor(), 1.2e18);
    }

    function test_BorrowBelowFloorRevertsDebtDelegationAndTransfers() public {
        asset.mint(address(actionContract), 7e18);
        asset.mint(address(adapter), 3e18);

        vm.expectRevert(abi.encodeWithSelector(IBorrowAction.HealthFactorTooLow.selector, 1e18, 1.2e18));
        _borrow(240e18);

        _assertUnborrowed();
        assertEq(asset.balanceOf(address(adapter)), 3e18);
        assertEq(asset.balanceOf(address(actionContract)), 7e18);
    }

    function test_BorrowAfterRepaymentUsesCurrentDebt() public {
        _borrow(200e18);
        adapter.execute(address(asset), abi.encodeCall(IERC20.approve, (address(pool), 100e18)));
        adapter.execute(address(pool), abi.encodeCall(BorrowActionPoolMock.repay, (100e18, address(adapter))));

        _borrow(100e18);

        assertEq(asset.balanceOf(address(adapter)), 200e18);
        assertEq(pool.debt(address(adapter)), 200e18);
        assertEq(actionContract.getHealthFactor(), 1.2e18);
        vm.expectPartialRevert(IBorrowAction.HealthFactorTooLow.selector);
        _borrow(1e18);
        assertEq(pool.debt(address(adapter)), 200e18);
        assertEq(asset.balanceOf(address(adapter)), 200e18);
    }

    function test_BorrowDirectlyToAdapterStillChecksHealthAndPreservesCapabilityBalance() public {
        pool.setSendDirectly(true);
        asset.mint(address(actionContract), 7e18);

        vm.expectEmit(false, false, false, true, address(actionContract));
        emit IBorrowAction.Borrow(_borrowData(200e18), 0, 1.2e18);
        _borrow(200e18);

        assertEq(asset.balanceOf(address(adapter)), 200e18);
        assertEq(asset.balanceOf(address(actionContract)), 7e18);
        vm.expectPartialRevert(IBorrowAction.HealthFactorTooLow.selector);
        _borrow(1e18);
        assertEq(pool.debt(address(adapter)), 200e18);
        assertEq(asset.balanceOf(address(adapter)), 200e18);
    }

    function test_BorrowUsesHealthAfterForwarding() public {
        asset.setTransferCallback(
            address(actionContract),
            address(pool),
            abi.encodeCall(BorrowActionPoolMock.setCollateral, (address(adapter), 100e18))
        );

        vm.expectRevert(abi.encodeWithSelector(IBorrowAction.HealthFactorTooLow.selector, 0.5e18, 1.2e18));
        _borrow(200e18);

        _assertUnborrowed();
        assertEq(pool.collateral(address(adapter)), 240e18);
    }

    function test_BorrowRejectsNonAdapterIncludingOwner() public {
        vm.expectRevert(IBorrowAction.InvalidCaller.selector);
        actionContract.borrow(_borrowData(200e18));
        _assertUnborrowed();
    }

    function test_BorrowRejectsAlternateSelector() public {
        vm.expectRevert(IBorrowAction.InvalidBorrowData.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeCall(IBorrowAction.borrow, (abi.encodeCall(BorrowActionPoolMock.setQueryMode, (3))))
        );
        assertEq(pool.queryMode(), 0);
    }

    function test_BorrowRejectsShortCalldata() public {
        vm.expectRevert(IBorrowAction.InvalidBorrowData.selector);
        adapter.execute(address(actionContract), abi.encodeCall(IBorrowAction.borrow, (hex"aabbcc")));
    }

    function test_BorrowBubblesProtocolFailureAndDoesNotForwardDust() public {
        pool.setFailBorrow(true);
        asset.mint(address(actionContract), 7e18);

        vm.expectRevert(BorrowActionPoolMock.BorrowFailed.selector);
        _borrow(200e18);

        _assertUnborrowed();
        assertEq(asset.balanceOf(address(actionContract)), 7e18);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_BorrowRequiresDelegationForConfiguredAccount() public {
        _delegate(address(actionContract), 0);

        vm.expectRevert(BorrowActionPoolMock.MissingDelegation.selector);
        _borrow(200e18);

        assertEq(pool.debt(address(adapter)), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_BorrowRollsBackDebtIfForwardingFails() public {
        asset.setTransferCallback(
            address(pool), address(asset), abi.encodeCall(BorrowActionTokenMock.setFailTransfers, (true))
        );

        vm.expectRevert(BorrowActionTokenMock.TransferFailed.selector);
        _borrow(200e18);

        _assertUnborrowed();
        assertEq(asset.balanceOf(address(actionContract)), 0);
        assertFalse(asset.failTransfers());
    }

    function test_BorrowRollsBackWhenQueryRevertsAfterBorrow() public {
        _setQueryModeDuringBorrow(1);

        vm.expectRevert(BorrowActionPoolMock.QueryFailed.selector);
        _borrow(200e18);

        _assertUnborrowed();
        assertEq(pool.queryMode(), 0);
    }

    function test_BorrowRollsBackWhenQueryIsMalformedAfterBorrow() public {
        _setQueryModeDuringBorrow(2);

        vm.expectRevert(IBorrowAction.InvalidHealthFactorResponse.selector);
        _borrow(200e18);

        _assertUnborrowed();
        assertEq(pool.queryMode(), 0);
    }

    function test_BorrowRejectsMissingHealthWordDespiteHighFirstWord() public {
        _setQueryModeDuringBorrow(4);

        vm.expectRevert(IBorrowAction.InvalidHealthFactorResponse.selector);
        _borrow(200e18);

        _assertUnborrowed();
    }

    function test_BorrowRejectsIncompleteHealthWord() public {
        _setQueryModeDuringBorrow(5);

        vm.expectRevert(IBorrowAction.InvalidHealthFactorResponse.selector);
        _borrow(200e18);

        _assertUnborrowed();
    }

    function test_BorrowRejectsZeroHealth() public {
        _setQueryModeDuringBorrow(3);

        vm.expectRevert(abi.encodeWithSelector(IBorrowAction.HealthFactorTooLow.selector, 0, 1.2e18));
        _borrow(200e18);

        _assertUnborrowed();
    }

    function test_BorrowRejectsReentryViaBoundAdapter() public {
        pool.setBorrowCallback(
            address(adapter),
            abi.encodeCall(
                BorrowActionAdapterMock.execute,
                (address(actionContract), abi.encodeCall(IBorrowAction.borrow, (_borrowData(1e18))))
            )
        );

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _borrow(200e18);

        _assertUnborrowed();
    }

    function test_BorrowCannotLowerFloorDuringProtocolCallback() public {
        pool.setBorrowCallback(
            address(adapter),
            abi.encodeCall(
                BorrowActionAdapterMock.execute,
                (address(actionContract), abi.encodeCall(IBorrowAction.setMinHealthFactor, (1)))
            )
        );

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _borrow(240e18);

        _assertUnborrowed();
        assertEq(actionContract.minHealthFactor(), 1.2e18);
    }

    function test_SetMinHealthFactorOnlyAdapterAndImmediatelyApplied() public {
        vm.expectRevert(IBorrowAction.InvalidCaller.selector);
        actionContract.setMinHealthFactor(1e18);

        vm.expectEmit(false, false, false, true, address(actionContract));
        emit IBorrowAction.SetMinHealthFactor(2e18);
        adapter.execute(address(actionContract), abi.encodeCall(IBorrowAction.setMinHealthFactor, (2e18)));

        vm.expectRevert(abi.encodeWithSelector(IBorrowAction.HealthFactorTooLow.selector, 1.2e18, 2e18));
        _borrow(200e18);
        _borrow(120e18);
        assertEq(pool.debt(address(adapter)), 120e18);
        assertEq(actionContract.getHealthFactor(), 2e18);
    }

    function test_SetMinHealthFactorCannotDisableCheck() public {
        vm.expectRevert(IBorrowAction.InvalidMinHealthFactor.selector);
        adapter.execute(address(actionContract), abi.encodeCall(IBorrowAction.setMinHealthFactor, (0)));
        assertEq(actionContract.minHealthFactor(), 1.2e18);
    }

    function test_InitializeAllowsTemporarilyLowHealthButBorrowCannotWorsenIt() public {
        vm.prank(address(adapter));
        pool.borrow(address(asset), 200e18, 2, 0, address(adapter));
        pool.setCollateral(address(adapter), 0);
        BorrowAction other = _create(_params());
        _delegate(address(other), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(IBorrowAction.HealthFactorTooLow.selector, 0, 1.2e18));
        adapter.execute(address(other), abi.encodeCall(IBorrowAction.borrow, (_borrowData(1e18))));
        assertEq(pool.debt(address(adapter)), 200e18);
        assertEq(asset.balanceOf(address(adapter)), 200e18);
    }

    function test_InitializeSupportsScalarHealthQueryAtOffsetZero() public {
        IBorrowAction.InitParams memory params = _params();
        params.healthFactorData = abi.encodeCall(BorrowActionPoolMock.healthFactor, (address(adapter)));
        params.healthFactorOffset = 0;
        BorrowAction scalar = _create(params);
        _delegate(address(scalar), 1000e18);

        adapter.execute(address(scalar), abi.encodeCall(IBorrowAction.borrow, (_borrowData(200e18))));

        assertEq(scalar.getHealthFactor(), 1.2e18);
        assertEq(asset.balanceOf(address(adapter)), 200e18);
    }

    function test_InitializeRejectsZeroAdapter() public {
        IBorrowAction.InitParams memory params = _params();
        params.adapter = address(0);
        _expectInitRevert(params, IBorrowAction.InvalidAdapter.selector);
    }

    function test_InitializeRejectsBorrowTargetWithoutCode() public {
        IBorrowAction.InitParams memory params = _params();
        params.borrowTarget = makeAddr("borrow EOA");
        _expectInitRevert(params, IBorrowAction.InvalidBorrowTarget.selector);
    }

    function test_InitializeRejectsBorrowAssetWithoutCode() public {
        IBorrowAction.InitParams memory params = _params();
        params.borrowAsset = makeAddr("token EOA");
        _expectInitRevert(params, IBorrowAction.InvalidBorrowAsset.selector);
    }

    function test_InitializeRejectsHealthTargetWithoutCode() public {
        IBorrowAction.InitParams memory params = _params();
        params.healthFactorTarget = makeAddr("query EOA");
        _expectInitRevert(params, IBorrowAction.InvalidHealthFactorTarget.selector);
    }

    function test_InitializeRejectsHealthQueryWithoutSelector() public {
        IBorrowAction.InitParams memory params = _params();
        params.healthFactorData = hex"000102";
        _expectInitRevert(params, IBorrowAction.InvalidHealthFactorData.selector);
    }

    function test_InitializeRejectsUnalignedOffset() public {
        IBorrowAction.InitParams memory params = _params();
        params.healthFactorOffset = 159;
        _expectInitRevert(params, IBorrowAction.InvalidHealthFactorOffset.selector);
    }

    function test_InitializeRejectsOutOfBoundsOffsetWithoutOverflow() public {
        IBorrowAction.InitParams memory params = _params();
        params.healthFactorOffset = type(uint256).max - 31;
        _expectInitRevert(params, IBorrowAction.InvalidHealthFactorResponse.selector);
    }

    function test_InitializeRejectsZeroMinimum() public {
        IBorrowAction.InitParams memory params = _params();
        params.minHealthFactor = 0;
        _expectInitRevert(params, IBorrowAction.InvalidMinHealthFactor.selector);
    }

    function test_InitializeRejectsMalformedHealthResponse() public {
        pool.setQueryMode(2);
        _expectInitRevert(_params(), IBorrowAction.InvalidHealthFactorResponse.selector);
    }

    function test_InitializeExecutesHealthQueryWithStaticCall() public {
        IBorrowAction.InitParams memory params = _params();
        params.healthFactorData = abi.encodeCall(BorrowActionPoolMock.statefulHealth, ());
        params.healthFactorOffset = 0;
        uint64 version = factory.lastVersion();

        vm.expectRevert();
        factory.create{gas: 2_000_000}(version, address(this), abi.encode(params));

        assertEq(pool.queryMode(), 0);
    }

    function test_MigratePreservesHealthAndProtocolConfiguration() public {
        factory.whitelist(address(new BorrowAction(address(factory))));
        factory.migrate(address(actionContract), 2, bytes(""));

        _borrow(200e18);

        assertEq(actionContract.version(), 2);
        assertEq(actionContract.getHealthFactor(), 1.2e18);
        assertEq(asset.balanceOf(address(adapter)), 200e18);
    }

    function test_MigrateRejectsReconfiguration() public {
        factory.whitelist(address(new BorrowAction(address(factory))));
        vm.expectRevert(IBorrowAction.InvalidMigrationData.selector);
        factory.migrate(address(actionContract), 2, abi.encode(_params()));
        assertEq(actionContract.version(), 1);
    }

    function testFuzz_BorrowFloorBoundsDebtAndTransfers(uint256 amount, uint256 minimum) public {
        amount = bound(amount, 1, 1000e18);
        minimum = bound(minimum, 1, 10e18);
        uint256 finalHealth = 240e36 / amount;
        adapter.execute(address(actionContract), abi.encodeCall(IBorrowAction.setMinHealthFactor, (minimum)));

        if (finalHealth < minimum) {
            vm.expectRevert(abi.encodeWithSelector(IBorrowAction.HealthFactorTooLow.selector, finalHealth, minimum));
            _borrow(amount);
            _assertUnborrowed();
            assertEq(asset.balanceOf(address(adapter)), 0);
        } else {
            _borrow(amount);
            assertEq(pool.debt(address(adapter)), amount);
            assertEq(asset.balanceOf(address(adapter)), amount);
            assertEq(actionContract.getHealthFactor(), finalHealth);
        }
        assertEq(asset.balanceOf(address(actionContract)), 0);
    }

    function _params() internal view returns (IBorrowAction.InitParams memory) {
        return IBorrowAction.InitParams({
            adapter: address(adapter),
            borrowTarget: address(pool),
            borrowSelector: BorrowActionPoolMock.borrow.selector,
            borrowAsset: address(asset),
            healthFactorTarget: address(pool),
            healthFactorData: abi.encodeCall(BorrowActionPoolMock.getUserAccountData, (address(adapter))),
            healthFactorOffset: 160,
            minHealthFactor: 1.2e18
        });
    }

    function _create(IBorrowAction.InitParams memory params) internal returns (BorrowAction) {
        return BorrowAction(factory.create(factory.lastVersion(), address(this), abi.encode(params)));
    }

    function _borrowData(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(BorrowActionPoolMock.borrow, (address(asset), amount, 2, 0, address(adapter)));
    }

    function _borrow(uint256 amount) internal returns (bytes memory) {
        return adapter.execute(address(actionContract), abi.encodeCall(IBorrowAction.borrow, (_borrowData(amount))));
    }

    function _delegate(address borrower, uint256 amount) internal {
        adapter.execute(address(pool), abi.encodeCall(BorrowActionPoolMock.approveDelegation, (borrower, amount)));
    }

    function _setQueryModeDuringBorrow(uint256 mode) internal {
        pool.setBorrowCallback(address(pool), abi.encodeCall(BorrowActionPoolMock.setQueryMode, (mode)));
    }

    function _assertUnborrowed() internal view {
        assertEq(pool.debt(address(adapter)), 0);
        assertEq(pool.delegation(address(adapter), address(actionContract)), 1000e18);
        assertEq(asset.balanceOf(address(pool)), 10_000e18);
    }

    function _expectInitRevert(IBorrowAction.InitParams memory params, bytes4 selector) internal {
        uint256 entitiesBefore = factory.totalEntities();
        uint64 version = factory.lastVersion();
        vm.expectRevert(selector);
        factory.create(version, address(this), abi.encode(params));
        assertEq(factory.totalEntities(), entitiesBefore);
    }
}

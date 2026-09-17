// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {BorrowCapability} from "src/contracts/merkle_adapter/BorrowCapability.sol";
import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {ICapability} from "src/interfaces/merkle_adapter/ICapability.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {BorrowCapabilityPoolMock, BorrowCapabilityTokenMock} from "./mocks/BorrowCapabilityMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract BorrowCapabilityTest is CapabilityTestBase {
    BorrowCapabilityTokenMock internal asset;
    BorrowCapabilityPoolMock internal pool;
    address internal factory;
    BorrowCapability internal implementation;
    BorrowCapability internal capability;

    function setUp() public {
        asset = new BorrowCapabilityTokenMock();
        pool = new BorrowCapabilityPoolMock(address(asset));
        asset.mint(address(pool), 10_000e18);
        factory = address(new ImmutableFactory(type(BorrowCapability).creationCode));
        implementation = BorrowCapability(IImmutableFactory(factory).create(""));
        _freshAdapter();
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.initializeBorrow, (_params())));
    }

    function test_BorrowUsesAdapterAsProtocolCallerDebtOwnerAndRecipientWithoutDelegation() public {
        asset.mint(address(adapter), 3e18);
        bytes memory result = _borrow(200e18);
        assertEq(abi.decode(abi.decode(result, (bytes)), (uint256)), 200e18);
        assertEq(asset.balanceOf(address(adapter)), 203e18);
        assertEq(asset.balanceOf(address(implementation)), 0);
        assertEq(pool.debt(address(adapter)), 200e18);
        assertEq(pool.debt(address(implementation)), 0);
        assertEq(pool.delegation(address(adapter), address(implementation)), 0);
        assertEq(capability.getHealthFactor(), 1.2e18);
    }

    function test_BelowFloorRollsBackDebtAndTokenTransfer() public {
        asset.mint(address(adapter), 3e18);
        _expectBorrowRevert(240e18, IBorrowCapability.HealthFactorTooLow.selector);
        assertEq(asset.balanceOf(address(adapter)), 3e18);
        assertEq(pool.debt(address(adapter)), 0);
        assertEq(asset.balanceOf(address(pool)), 10_000e18);
    }

    function test_BorrowAfterRepaymentUsesCurrentDebt() public {
        _borrow(200e18);
        _manage(address(asset), abi.encodeCall(IERC20.approve, (address(pool), 100e18)));
        _manage(address(pool), abi.encodeCall(pool.repay, (100e18, address(adapter))));
        _borrow(100e18);
        assertEq(pool.debt(address(adapter)), 200e18);
        assertEq(capability.getHealthFactor(), 1.2e18);
        _expectBorrowRevert(1e18, IBorrowCapability.HealthFactorTooLow.selector);
    }

    function test_DirectCallsToAdapterOrImplementationCannotBorrowOrConfigure() public {
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.borrow(_borrowData(1e18));
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.setMinHealthFactor(1);
        IBorrowCapability.InitParams memory params = _params();
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.initializeBorrow(params);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        implementation.initializeBorrow(params);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        implementation.borrow(_borrowData(1e18));
    }

    function test_InitializationIsFixedAcrossRemovalAndReplacement() public {
        _borrow(100e18);
        adapter.removeCapability(address(implementation));
        _installCapability(adapter, IImmutableFactory(factory).create(""), _borrowSelectors());
        assertEq(capability.minHealthFactor(), 1.2e18);
        assertEq(capability.getHealthFactor(), 2.4e18);
        _expectInitRevert(_params(), IBorrowCapability.AlreadyInitialized.selector);
        _borrow(100e18);
        assertEq(pool.debt(address(adapter)), 200e18);
    }

    function test_SharedImplementationHasIndependentAdapterConfiguration() public {
        MerkleAdapter first = adapter;
        _freshAdapter();
        IBorrowCapability.InitParams memory params = _params();
        params.minHealthFactor = 2e18;
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.initializeBorrow, (params)));
        assertEq(BorrowCapability(address(first)).minHealthFactor(), 1.2e18);
        assertEq(capability.minHealthFactor(), 2e18);
        assertEq(implementation.borrowTarget(), address(0));
        _expectBorrowRevert(200e18, IBorrowCapability.HealthFactorTooLow.selector);
    }

    function test_UninitializedOperationsRevert() public {
        _freshAdapter();
        _expectBorrowRevert(1e18, IBorrowCapability.NotInitialized.selector);
        vm.expectRevert(IBorrowCapability.NotInitialized.selector);
        capability.getHealthFactor();
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (1)));
        vm.expectRevert(IBorrowCapability.NotInitialized.selector);
        adapter.manage(calls);
    }

    function test_SelectorAndMalformedCalldataAreRejected() public {
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IBorrowCapability.borrow, (hex"aabbcc")));
        vm.expectRevert(IBorrowCapability.InvalidBorrowData.selector);
        adapter.manage(calls);
        calls = _publishCall(
            address(adapter), abi.encodeCall(IBorrowCapability.borrow, (abi.encodeCall(pool.setQueryMode, (3))))
        );
        vm.expectRevert(IBorrowCapability.InvalidBorrowData.selector);
        adapter.manage(calls);
        assertEq(pool.queryMode(), 0);
    }

    function test_ProtocolFailureBubbles() public {
        pool.setFailBorrow(true);
        _expectBorrowRevert(1e18, BorrowCapabilityPoolMock.BorrowFailed.selector);
        assertEq(pool.debt(address(adapter)), 0);
    }

    function test_HealthIsCheckedAfterProtocolCallbacks() public {
        pool.setBorrowCallback(address(pool), abi.encodeCall(pool.setCollateral, (address(adapter), 100e18)));
        _expectBorrowRevert(200e18, IBorrowCapability.HealthFactorTooLow.selector);
        assertEq(pool.collateral(address(adapter)), 240e18);
        assertEq(pool.debt(address(adapter)), 0);
    }

    function test_QueryFailuresAndMalformedResponsesRollBackBorrow() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            pool.setBorrowCallback(address(pool), abi.encodeCall(pool.setQueryMode, (mode)));
            bytes4 expected = mode == 1
                ? BorrowCapabilityPoolMock.QueryFailed.selector
                : mode == 3
                    ? IBorrowCapability.HealthFactorTooLow.selector
                    : IBorrowCapability.InvalidHealthFactorResponse.selector;
            _expectBorrowRevert(200e18, expected);
            assertEq(pool.debt(address(adapter)), 0);
            assertEq(pool.queryMode(), 0);
        }
    }

    function test_ProtocolCallbackCannotLowerFloorOrReenterManage() public {
        pool.setBorrowCallback(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (1)));
        _expectBorrowRevert(200e18, ICapability.InvalidCaller.selector);
        pool.setBorrowCallback(
            address(adapter), abi.encodeCall(IMerkleAdapter.manage, (new IMerkleAdapter.Action[](0)))
        );
        _expectBorrowRevert(200e18, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(capability.minHealthFactor(), 1.2e18);
    }

    function test_CuratorFloorUpdateImmediatelyAppliesAndCannotBeZero() public {
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (2e18)));
        _expectBorrowRevert(200e18, IBorrowCapability.HealthFactorTooLow.selector);
        _borrow(120e18);
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (0)));
        vm.expectRevert(IBorrowCapability.InvalidMinHealthFactor.selector);
        adapter.manage(calls);
        assertEq(capability.minHealthFactor(), 2e18);
    }

    function test_ScalarHealthQueryAndLowHealthInitialization() public {
        _freshAdapter();
        IBorrowCapability.InitParams memory params = _params();
        params.healthFactorData = abi.encodeCall(pool.healthFactor, (address(adapter)));
        params.healthFactorOffset = 0;
        vm.prank(address(adapter));
        pool.borrow(address(asset), 200e18, 2, 0, address(adapter));
        pool.setCollateral(address(adapter), 0);
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.initializeBorrow, (params)));
        assertEq(capability.getHealthFactor(), 0);
        _expectBorrowRevert(1e18, IBorrowCapability.HealthFactorTooLow.selector);
    }

    function test_InitializationRejectsInvalidConfigurationWithoutSavingIt() public {
        _freshAdapter();
        IBorrowCapability.InitParams memory params = _params();
        params.borrowTarget = address(1);
        _expectInitRevert(params, IBorrowCapability.InvalidBorrowTarget.selector);
        params = _params();
        params.borrowAsset = address(1);
        _expectInitRevert(params, IBorrowCapability.InvalidBorrowAsset.selector);
        params = _params();
        params.healthFactorTarget = address(1);
        _expectInitRevert(params, IBorrowCapability.InvalidHealthFactorTarget.selector);
        params = _params();
        params.healthFactorData = hex"001122";
        _expectInitRevert(params, IBorrowCapability.InvalidHealthFactorData.selector);
        params = _params();
        params.healthFactorOffset = 159;
        _expectInitRevert(params, IBorrowCapability.InvalidHealthFactorOffset.selector);
        params = _params();
        params.healthFactorOffset = type(uint256).max - 31;
        _expectInitRevert(params, IBorrowCapability.InvalidHealthFactorResponse.selector);
        params = _params();
        params.minHealthFactor = 0;
        _expectInitRevert(params, IBorrowCapability.InvalidMinHealthFactor.selector);
        assertEq(capability.borrowTarget(), address(0));
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.initializeBorrow, (_params())));
        _borrow(200e18);
    }

    function test_HealthQueryUsesStaticCall() public {
        _freshAdapter();
        IBorrowCapability.InitParams memory params = _params();
        params.healthFactorData = abi.encodeCall(pool.statefulHealth, ());
        params.healthFactorOffset = 0;
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IBorrowCapability.initializeBorrow, (params)));
        vm.expectRevert();
        adapter.manage{gas: 2_000_000}(calls);
        assertEq(pool.queryMode(), 0);
        assertEq(capability.borrowTarget(), address(0));
    }

    function testFuzz_FinalHealthBoundsBorrowedDebt(uint256 amount, uint256 minimum) public {
        amount = bound(amount, 1, 1000e18);
        minimum = bound(minimum, 1, 10e18);
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (minimum)));
        if (240e36 / amount < minimum) {
            _expectBorrowRevert(amount, IBorrowCapability.HealthFactorTooLow.selector);
            assertEq(pool.debt(address(adapter)), 0);
        } else {
            _borrow(amount);
            assertEq(pool.debt(address(adapter)), amount);
            assertEq(asset.balanceOf(address(adapter)), amount);
        }
        assertEq(asset.balanceOf(address(implementation)), 0);
    }

    function _freshAdapter() internal {
        _deployAdapter(address(asset));
        _installCapability(adapter, address(implementation), _borrowSelectors());
        capability = BorrowCapability(address(adapter));
        pool.setCollateral(address(adapter), 240e18);
    }

    function _params() internal view returns (IBorrowCapability.InitParams memory) {
        return IBorrowCapability.InitParams(
            address(pool),
            pool.borrow.selector,
            address(asset),
            address(pool),
            abi.encodeCall(pool.getUserAccountData, (address(adapter))),
            160,
            1.2e18
        );
    }

    function _borrowData(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(pool.borrow, (address(asset), amount, 2, 0, address(adapter)));
    }

    function _borrow(uint256 amount) internal returns (bytes memory) {
        return _manage(address(adapter), abi.encodeCall(IBorrowCapability.borrow, (_borrowData(amount))));
    }

    function _expectBorrowRevert(uint256 amount, bytes4 errorSelector) internal {
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IBorrowCapability.borrow, (_borrowData(amount))));
        vm.expectRevert(errorSelector);
        adapter.manage(calls);
    }

    function _expectInitRevert(IBorrowCapability.InitParams memory params, bytes4 errorSelector) internal {
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IBorrowCapability.initializeBorrow, (params)));
        vm.expectRevert(errorSelector);
        adapter.manage(calls);
    }
}

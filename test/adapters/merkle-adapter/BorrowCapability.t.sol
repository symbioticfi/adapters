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
        _freshAdapter();
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (1.2e18)));
    }

    function test_FactoryArgumentsSetBorrowConfiguration() public {
        BorrowCapability deployed = BorrowCapability(IImmutableFactory(factory).create(abi.encode(_params())));
        assertEq(deployed.borrowTarget(), address(pool));
        assertEq(deployed.borrowSelector(), pool.borrow.selector);
        assertEq(deployed.borrowAsset(), address(asset));
        assertEq(deployed.healthFactorTarget(), address(pool));
        assertEq(deployed.healthFactorData(), abi.encodeCall(pool.getUserAccountData, (address(adapter))));
        assertEq(deployed.healthFactorOffset(), 160);
        assertEq(deployed.minHealthFactor(), 0);
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
        vm.expectRevert(ICapability.InvalidCaller.selector);
        implementation.setMinHealthFactor(1);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        implementation.borrow(_borrowData(1e18));
    }

    function test_ReplacementUsesConstructorConfigurationAndRetainsMinimum() public {
        _borrow(100e18);
        BorrowCapabilityPoolMock firstPool = pool;
        pool = new BorrowCapabilityPoolMock(address(asset));
        asset.mint(address(pool), 10_000e18);
        pool.setCollateral(address(adapter), 120e18);
        _replaceImplementation(_params());
        assertEq(capability.borrowTarget(), address(pool));
        assertEq(capability.healthFactorTarget(), address(pool));
        assertEq(capability.minHealthFactor(), 1.2e18);
        assertEq(capability.getHealthFactor(), type(uint256).max);
        _borrow(100e18);
        _expectBorrowRevert(1e18, IBorrowCapability.HealthFactorTooLow.selector);
        assertEq(firstPool.debt(address(adapter)), 100e18);
        assertEq(pool.debt(address(adapter)), 100e18);
    }

    function test_RemovingAndReaddingImplementationRetainsMinimum() public {
        _borrow(100e18);
        adapter.removeCapability(address(implementation));
        adapter.addCapability(address(implementation));
        assertEq(capability.minHealthFactor(), 1.2e18);
        assertEq(capability.getHealthFactor(), 2.4e18);
        _borrow(100e18);
        assertEq(pool.debt(address(adapter)), 200e18);
    }

    function test_DifferentImplementationsHaveIndependentQueriesAndMinimums() public {
        MerkleAdapter first = adapter;
        _freshAdapter();
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (2e18)));
        assertEq(BorrowCapability(address(first)).minHealthFactor(), 1.2e18);
        assertEq(capability.minHealthFactor(), 2e18);
        assertEq(implementation.minHealthFactor(), 0);
        assertEq(capability.healthFactorData(), abi.encodeCall(pool.getUserAccountData, (address(adapter))));
        assertEq(
            BorrowCapability(address(first)).healthFactorData(),
            abi.encodeCall(pool.getUserAccountData, (address(first)))
        );
        _expectBorrowRevert(200e18, IBorrowCapability.HealthFactorTooLow.selector);
    }

    function test_SharedImplementationSharesFixedQueryButNotMinimum() public {
        MerkleAdapter first = adapter;
        _deployAdapter(address(asset));
        _installCapability(adapter, address(implementation), _borrowSelectors());
        capability = BorrowCapability(address(adapter));
        assertEq(capability.minHealthFactor(), 0);
        assertEq(capability.healthFactorData(), BorrowCapability(address(first)).healthFactorData());
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (2e18)));
        assertEq(BorrowCapability(address(first)).minHealthFactor(), 1.2e18);
        assertEq(capability.minHealthFactor(), 2e18);
        assertEq(implementation.minHealthFactor(), 0);
    }

    function test_BorrowRequiresMinimumButReadsWorkBeforeItIsSet() public {
        _freshAdapter();
        assertEq(capability.borrowTarget(), address(pool));
        assertEq(capability.getHealthFactor(), type(uint256).max);
        assertEq(capability.minHealthFactor(), 0);
        pool.setFailBorrow(true);
        _expectBorrowRevert(1e18, IBorrowCapability.MinHealthFactorNotSet.selector);
        assertEq(pool.debt(address(adapter)), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        pool.setFailBorrow(false);
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (1.2e18)));
        _borrow(200e18);
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

    function test_ScalarHealthQueryAndMinimumCanBeSetWhileHealthIsLow() public {
        IBorrowCapability.ConstructorParams memory params = _params();
        params.healthFactorData = abi.encodeCall(pool.healthFactor, (address(adapter)));
        params.healthFactorOffset = 0;
        _replaceImplementation(params);
        vm.prank(address(adapter));
        pool.borrow(address(asset), 200e18, 2, 0, address(adapter));
        pool.setCollateral(address(adapter), 0);
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (2e18)));
        assertEq(capability.minHealthFactor(), 2e18);
        assertEq(capability.getHealthFactor(), 0);
        _expectBorrowRevert(1e18, IBorrowCapability.HealthFactorTooLow.selector);
    }

    function test_ConstructorDoesNotValidateOrCallExternalTargets() public {
        IBorrowCapability.ConstructorParams memory params;
        BorrowCapability deployed = BorrowCapability(IImmutableFactory(factory).create(abi.encode(params)));
        assertEq(deployed.borrowTarget(), address(0));
        assertEq(deployed.healthFactorData().length, 0);
        pool.setQueryMode(1);
        _replaceImplementation(_params());
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (2e18)));
        _expectBorrowRevert(1e18, BorrowCapabilityPoolMock.QueryFailed.selector);
        assertEq(pool.debt(address(adapter)), 0);
    }

    function test_InvalidHealthOffsetsRevertAtReadAndRollBackBorrow() public {
        uint256[3] memory offsets = [uint256(159), uint256(192), type(uint256).max - 31];
        for (uint256 i; i < offsets.length; ++i) {
            IBorrowCapability.ConstructorParams memory params = _params();
            params.healthFactorOffset = offsets[i];
            _replaceImplementation(params);
            vm.expectRevert(IBorrowCapability.InvalidHealthFactorResponse.selector);
            capability.getHealthFactor();
            _expectBorrowRevert(1e18, IBorrowCapability.InvalidHealthFactorResponse.selector);
            assertEq(pool.debt(address(adapter)), 0);
            assertEq(asset.balanceOf(address(adapter)), 0);
        }
    }

    function testFuzz_ConstructorCalldataIsReadFromImplementation(bytes memory data) public {
        IBorrowCapability.ConstructorParams memory params = _params();
        params.healthFactorData = data;
        _replaceImplementation(params);
        assertEq(implementation.healthFactorData(), data);
        assertEq(capability.healthFactorData(), data);
        assertEq(implementation.minHealthFactor(), 0);
        assertEq(capability.minHealthFactor(), 1.2e18);
    }

    function test_HealthQueryUsesStaticCall() public {
        IBorrowCapability.ConstructorParams memory params = _params();
        params.healthFactorData = abi.encodeCall(pool.statefulHealth, ());
        params.healthFactorOffset = 0;
        _replaceImplementation(params);
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IBorrowCapability.borrow, (_borrowData(1e18))));
        vm.expectRevert();
        adapter.manage{gas: 2_000_000}(calls);
        assertEq(pool.queryMode(), 0);
        assertEq(pool.debt(address(adapter)), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
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
        implementation = BorrowCapability(IImmutableFactory(factory).create(abi.encode(_params())));
        _installCapability(adapter, address(implementation), _borrowSelectors());
        capability = BorrowCapability(address(adapter));
        pool.setCollateral(address(adapter), 240e18);
    }

    function _params() internal view returns (IBorrowCapability.ConstructorParams memory) {
        return IBorrowCapability.ConstructorParams(
            address(pool),
            pool.borrow.selector,
            address(asset),
            address(pool),
            abi.encodeCall(pool.getUserAccountData, (address(adapter))),
            160
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

    function _replaceImplementation(IBorrowCapability.ConstructorParams memory params) internal {
        adapter.removeCapability(address(implementation));
        implementation = BorrowCapability(IImmutableFactory(factory).create(abi.encode(params)));
        _installCapability(adapter, address(implementation), _borrowSelectors());
    }
}

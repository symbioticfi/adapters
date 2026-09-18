// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/capabilities/borrow-capability/AaveHealthFactor.sol";
import {BorrowCapabilityPoolMock, BorrowCapabilityTokenMock} from "./mocks/BorrowCapabilityMocks.sol";
import {BorrowCapability} from "src/contracts/merkle-adapter/capabilities/BorrowCapability.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";

import {IBorrowCapability} from "src/interfaces/merkle-adapter/capabilities/IBorrowCapability.sol";
import {ICapability} from "src/interfaces/merkle-adapter/capabilities/ICapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMorphoBase, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/BorrowCapabilityMocks.sol";

contract BorrowCapabilityTest is CapabilityTestBase {
    address internal asset;
    address internal pool;
    address internal helper;
    address internal implementation;
    BorrowTestCall internal health;

    function setUp() public {
        asset = address(new BorrowCapabilityTokenMock());
        pool = address(new BorrowCapabilityPoolMock(asset));
        helper = address(new AaveHealthFactor());
        BorrowCapabilityTokenMock(asset).mint(pool, 10_000e18);
        implementation =
            IImmutableFactory(address(new ImmutableFactory(type(BorrowCapability).creationCode))).create("");
        _freshAdapter();
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 1.2e18);
    }

    function test_BorrowUsesAdapterAsCallerDebtOwnerAndRecipientWithoutDelegation() public {
        BorrowCapabilityTokenMock(asset).mint(address(adapter), 3e18);
        bytes memory result = _borrow(200e18);
        assertEq(abi.decode(abi.decode(result, (bytes)), (uint256)), 200e18);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 203e18);
        assertEq(IERC20(asset).balanceOf(implementation), 0);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 200e18);
        assertEq(BorrowCapabilityPoolMock(pool).debt(implementation), 0);
        assertEq(BorrowCapabilityPoolMock(pool).delegation(address(adapter), implementation), 0);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 1.2e18);
    }

    function test_BelowFloorRollsBackDebtAndTokenTransfer() public {
        BorrowCapabilityTokenMock(asset).mint(address(adapter), 3e18);
        _expectBorrowRevert(240e18, IBorrowCapability.HealthFactorTooLow.selector);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 3e18);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
        assertEq(IERC20(asset).balanceOf(pool), 10_000e18);
    }

    function test_BorrowAcceptsAndEmitsFlatArguments() public {
        bytes memory data =
            abi.encodeCall(BorrowCapabilityPoolMock.borrow, (asset, uint256(100e18), 2, 0, address(adapter)));
        bytes4 selector = bytes4(keccak256("borrow(address,address,bytes,bytes)"));
        assertEq(IBorrowCapability.borrow.selector, selector);
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeWithSelector(selector, pool, helper, data, health.data));
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IBorrowCapability.Borrow(pool, helper, data, health.data, 2.4e18);
        adapter.manage(calls);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 100e18);
    }

    function test_BorrowAfterRepaymentUsesCurrentDebt() public {
        _borrow(200e18);
        _manage(asset, abi.encodeCall(IERC20.approve, (pool, 100e18)));
        _manage(pool, abi.encodeCall(BorrowCapabilityPoolMock.repay, (100e18, address(adapter))));
        _borrow(100e18);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 200e18);
        _expectBorrowRevert(1e18, IBorrowCapability.HealthFactorTooLow.selector);
    }

    function test_DirectBorrowCallsRejectEvenTheOwner() public {
        BorrowTestCall memory operation = _borrowCall();
        vm.expectRevert(ICapability.InvalidCaller.selector);
        BorrowCapability(address(adapter)).borrow(operation.target, health.target, operation.data, health.data);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        BorrowCapability(implementation).borrow(operation.target, health.target, operation.data, health.data);
    }

    function test_DirectSetMinimumRejectsEvenTheOwner() public {
        bytes32 id = keccak256(abi.encode(health.target, health.data));
        vm.expectRevert(ICapability.InvalidCaller.selector);
        BorrowCapability(address(adapter)).setHealthFactor(id, 1);
        vm.prank(address(0xbad));
        vm.expectRevert(ICapability.InvalidCaller.selector);
        BorrowCapability(address(adapter)).setHealthFactor(id, 1);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        BorrowCapability(implementation).setHealthFactor(id, 1);
    }

    function test_SetMinimumAcceptsApprovedNonOwner() public {
        address curator = address(0xbeef);
        adapter.grantRole(_healthFactorLeaf(_healthUpdate), curator);
        IMerkleAdapter.Action[] memory calls = _minimumCalls(2e18);
        vm.prank(curator);
        adapter.manage(calls);
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))), 2e18
        );
    }

    function test_SetMinimumRejectsMissingRoleIncludingOwner() public {
        IMerkleAdapter.Action[] memory calls = _minimumCalls(2e18);
        vm.prank(address(0xbeef));
        vm.expectRevert();
        adapter.manage(calls);
        adapter.revokeRole(_healthFactorLeaf(_healthUpdate), address(this));
        vm.expectRevert();
        adapter.manage(calls);
    }

    function test_SetMinimumRejectsChangedPolicyAndMask() public {
        IMerkleAdapter.Action[] memory calls = _minimumCalls(2e18);
        calls[0].data[4] ^= 0x01;
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(calls);
        calls = _minimumCalls(2e18);
        calls[0].dataMask[4] = 0xff;
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(calls);
    }

    function test_SetMinimumRejectsStaleRoot() public {
        IMerkleAdapter.Action[] memory calls = _minimumCalls(2e18);
        _publishCall(asset, abi.encodeCall(IERC20.approve, (pool, uint256(0))));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(calls);
    }

    function test_AuthorizedCallerUpdatesMinimumWithoutChangingRootOrRoles() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        bytes32 root = adapter.merkleRoot();
        adapter.transferOwnership(address(0xbeef));
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 2e18);
        _setAmount(calls, 200e18);
        vm.expectRevert(IBorrowCapability.HealthFactorTooLow.selector);
        adapter.manage(calls);
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 1.2e18);
        adapter.manage(calls);
        assertEq(adapter.merkleRoot(), root);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 200e18);
        IMerkleAdapter.Action[] memory zero = _minimumCalls(0);
        vm.expectRevert(IBorrowCapability.InvalidMinHealthFactor.selector);
        adapter.manage(zero);
    }

    function test_AuthorizedCallerCanSetMinimumWhileHealthIsLowWithoutCallingTheQuery() public {
        _borrow(200e18);
        BorrowCapabilityPoolMock(pool).setCollateral(address(adapter), 0);
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 2e18);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 0);
        BorrowCapabilityPoolMock(pool).setQueryMode(1);
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 3e18);
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))), 3e18
        );
    }

    function test_UnsetMinimumRejectsBeforeTheProtocolCall() public {
        _freshAdapter();
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), type(uint256).max);
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))), 0
        );
        BorrowCapabilityPoolMock(pool).setFailBorrow(true);
        _expectBorrowRevert(1e18, IBorrowCapability.MinHealthFactorNotSet.selector);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_OneInstalledCapabilityHandlesIndependentPools() public {
        _borrow(100e18);
        address firstPool = pool;
        BorrowTestCall memory firstHealth = health;
        pool = address(new BorrowCapabilityPoolMock(asset));
        BorrowCapabilityTokenMock(asset).mint(pool, 10_000e18);
        BorrowCapabilityPoolMock(pool).setCollateral(address(adapter), 120e18);
        health = BorrowTestCall(helper, abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, address(adapter))));
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 2e18);
        bytes memory data = abi.encodeCall(
            IBorrowCapability.borrow, (_borrowCall().target, health.target, _borrowCall().data, health.data)
        );
        IMerkleAdapter.Action[] memory unapproved = new IMerkleAdapter.Action[](1);
        unapproved[0] = IMerkleAdapter.Action(address(adapter), 0, data, new bytes(data.length), new bytes32[](0));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(unapproved);
        _borrow(60e18);
        _expectBorrowRevert(1e18, IBorrowCapability.HealthFactorTooLow.selector);
        assertEq(adapter.getCapabilities().length, 1);
        assertEq(adapter.capabilityBySelector(IBorrowCapability.borrow.selector), implementation);
        assertEq(
            BorrowCapability(address(adapter))
                .minHealthFactor(keccak256(abi.encode(firstHealth.target, firstHealth.data))),
            1.2e18
        );
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))), 2e18
        );
        assertEq(BorrowCapabilityPoolMock(firstPool).debt(address(adapter)), 100e18);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 60e18);
    }

    function test_TwoAssetsInOnePoolShareTheirAccountMinimum() public {
        _borrow(100e18);
        asset = address(new BorrowCapabilityTokenMock());
        BorrowCapabilityTokenMock(asset).mint(pool, 10_000e18);
        BorrowCapabilityPoolMock(pool).setReserve(asset);
        _borrow(100e18);
        _expectBorrowRevert(1e18, IBorrowCapability.HealthFactorTooLow.selector);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 200e18);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 1.2e18);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 100e18);
    }

    function test_HealthPolicyKeyIncludesBothTargetAndCalldata() public {
        BorrowTestCall memory otherTarget = BorrowTestCall(address(0x1234), health.data);
        BorrowTestCall memory otherAccount =
            BorrowTestCall(helper, abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, address(0x5678))));
        assertEq(
            BorrowCapability(address(adapter))
                .minHealthFactor(keccak256(abi.encode(otherTarget.target, otherTarget.data))),
            0
        );
        assertEq(
            BorrowCapability(address(adapter))
                .minHealthFactor(keccak256(abi.encode(otherAccount.target, otherAccount.data))),
            0
        );
        _setHealthFactor(keccak256(abi.encode(otherAccount.target, otherAccount.data)), 2e18);
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))),
            1.2e18
        );
        assertEq(
            BorrowCapability(address(adapter))
                .minHealthFactor(keccak256(abi.encode(otherAccount.target, otherAccount.data))),
            2e18
        );
    }

    function test_SharedImplementationKeepsAdapterMinimumsIndependent() public {
        address first = address(adapter);
        BorrowTestCall memory firstHealth = health;
        _freshAdapter();
        _setHealthFactor(keccak256(abi.encode(firstHealth.target, firstHealth.data)), 2e18);
        assertEq(
            BorrowCapability(first).minHealthFactor(keccak256(abi.encode(firstHealth.target, firstHealth.data))), 1.2e18
        );
        assertEq(
            BorrowCapability(address(adapter))
                .minHealthFactor(keccak256(abi.encode(firstHealth.target, firstHealth.data))),
            2e18
        );
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))), 0
        );
        assertEq(
            BorrowCapability(implementation)
                .minHealthFactor(keccak256(abi.encode(firstHealth.target, firstHealth.data))),
            0
        );
    }

    function test_ReplacementAndRemovalKeepAllMinimums() public {
        adapter.removeCapability(implementation);
        adapter.addCapability(implementation);
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))),
            1.2e18
        );
        adapter.removeCapability(implementation);
        implementation = address(new BorrowCapability());
        _installCapability(adapter, implementation, _borrowSelectors());
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))),
            1.2e18
        );
        _borrow(200e18);
    }

    function test_StorageUsesBorrowNamespace() public {
        bytes32 id = keccak256(abi.encode(health.target, health.data));
        bytes32 slot =
            keccak256(abi.encode(id, uint256(0x14594e0b2a6dcf0d335223cd7b83327c553fe4ff39745016f5460d86c7a0dd00)));
        assertEq(uint256(vm.load(address(adapter), slot)), 1.2e18);
        assertEq(vm.load(implementation, slot), bytes32(0));
        vm.store(address(adapter), slot, bytes32(uint256(2e18)));
        assertEq(BorrowCapability(address(adapter)).minHealthFactor(id), 2e18);
        _expectBorrowRevert(200e18, IBorrowCapability.HealthFactorTooLow.selector);
    }

    function test_AmountsVaryUnderTheSameAcceptedLeaf() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        bytes32 root = adapter.merkleRoot();
        _setAmount(calls, 60e18);
        adapter.manage(calls);
        _setAmount(calls, 140e18);
        adapter.manage(calls);
        assertEq(adapter.merkleRoot(), root);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 200e18);
    }

    function testFuzz_ChangingAnyPinnedByteInvalidatesTheProof(uint256 index, uint8 difference) public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        index = bound(index, 0, calls[0].data.length - 1);
        while (calls[0].dataMask[index] == 0xff) index = (index + 1) % calls[0].data.length;
        difference = uint8(bound(difference, 1, 255));
        calls[0].data[index] ^= bytes1(difference);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(calls);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_AValidProofDoesNotGrantTheCallerItsLeafRole() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 1e18);
        vm.prank(address(0xbad));
        vm.expectRevert();
        adapter.manage(calls);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
    }

    function testFuzz_PassesTheExactAaveCalldataWithoutChangingOtherArguments(uint256 amount) public {
        address recorder = address(new BorrowTemplateRecorder());
        BorrowTestCall memory operation = _borrowCall();
        operation.target = recorder;
        IMerkleAdapter.Action[] memory calls = _publishBorrow(operation, health);
        _setAmount(calls, amount);
        bytes[] memory result = adapter.manage(calls);
        bytes memory expected = abi.encodeCall(BorrowCapabilityPoolMock.borrow, (asset, amount, 2, 0, address(adapter)));
        assertEq(BorrowTemplateRecorder(recorder).lastCall(), expected);
        assertEq(abi.decode(result[0], (bytes)), expected);
        assertEq(operation.data, _borrowCall().data);
    }

    function testFuzz_PassesTheExactMorphoCalldata(uint256 amount) public {
        address recorder = address(new BorrowTemplateRecorder());
        MarketParams memory market = MarketParams(asset, address(2), address(3), address(4), 0.86e18);
        BorrowTestCall memory operation = BorrowTestCall(
            recorder, abi.encodeCall(IMorphoBase.borrow, (market, uint256(0), 0, address(adapter), address(adapter)))
        );
        IMerkleAdapter.Action[] memory calls = _publishBorrowAt(operation, health, 5);
        _setAmount(calls, amount);
        adapter.manage(calls);
        assertEq(
            BorrowTemplateRecorder(recorder).lastCall(),
            abi.encodeCall(IMorphoBase.borrow, (market, amount, 0, address(adapter), address(adapter)))
        );
    }

    function test_ProtocolFailureBubbles() public {
        BorrowCapabilityPoolMock(pool).setFailBorrow(true);
        _expectBorrowRevert(1e18, BorrowCapabilityPoolMock.BorrowFailed.selector);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_HealthIsCheckedAfterProtocolCallbacks() public {
        BorrowCapabilityPoolMock(pool)
            .setBorrowCallback(pool, abi.encodeCall(BorrowCapabilityPoolMock.setCollateral, (address(adapter), 100e18)));
        _expectBorrowRevert(200e18, IBorrowCapability.HealthFactorTooLow.selector);
        assertEq(BorrowCapabilityPoolMock(pool).collateral(address(adapter)), 240e18);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_QueryFailuresAndMalformedAaveResponsesRollBackBorrow() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            BorrowCapabilityPoolMock(pool)
                .setBorrowCallback(pool, abi.encodeCall(BorrowCapabilityPoolMock.setQueryMode, (mode)));
            IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
            _setAmount(calls, 200e18);
            vm.expectRevert();
            adapter.manage(calls);
            assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
            assertEq(BorrowCapabilityPoolMock(pool).queryMode(), 0);
        }
    }

    function test_ProtocolCallbackCannotLowerFloorOrReenterManage() public {
        BorrowCapabilityPoolMock(pool)
            .setBorrowCallback(
                address(adapter),
                abi.encodeCall(
                    IBorrowCapability.setHealthFactor, (keccak256(abi.encode(health.target, health.data)), uint256(1))
                )
            );
        _expectBorrowRevert(200e18, ICapability.InvalidCaller.selector);
        BorrowCapabilityPoolMock(pool)
            .setBorrowCallback(
                address(adapter), abi.encodeCall(IMerkleAdapter.manage, (new IMerkleAdapter.Action[](0)))
            );
        _expectBorrowRevert(200e18, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))),
            1.2e18
        );
    }

    function test_OwnerCallbackCannotInvokeSetter() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 240e18);
        address newOwner = address(new BorrowOwnerCallback(address(adapter), health));
        adapter.transferOwnership(newOwner);
        BorrowCapabilityPoolMock(pool).setBorrowCallback(newOwner, abi.encodeCall(BorrowOwnerCallback.lowerMinimum, ()));
        vm.expectRevert(ICapability.InvalidCaller.selector);
        adapter.manage(calls);
        assertEq(
            BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data))),
            1.2e18
        );
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_HealthQueryUsesStaticCall() public {
        health = BorrowTestCall(pool, abi.encodeCall(BorrowCapabilityPoolMock.statefulHealth, ()));
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 1.2e18);
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 1e18);
        vm.expectRevert();
        adapter.manage{gas: 2_000_000}(calls);
        assertEq(BorrowCapabilityPoolMock(pool).queryMode(), 0);
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_HealthQueryRequiresExactlyOneScalarWord() public {
        health = BorrowTestCall(pool, abi.encodeCall(BorrowCapabilityPoolMock.healthFactor, (address(adapter))));
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 1.2e18);
        uint256[4] memory lengths = [uint256(0), uint256(31), uint256(33), uint256(64)];
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(pool, health.data, new bytes(lengths[i]));
            _expectBorrowRevert(1e18, IBorrowCapability.InvalidHealthFactorResponse.selector);
            assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
        }
        vm.mockCall(pool, health.data, abi.encode(uint256(2e18)));
        _borrow(1e18);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 2e18);
    }

    function test_ZeroAndMaximumAmountsArePassedThroughWithoutSpecialMeaning() public {
        address recorder = address(new BorrowTemplateRecorder());
        BorrowTestCall memory operation = _borrowCall();
        operation.target = recorder;
        IMerkleAdapter.Action[] memory calls = _publishBorrow(operation, health);
        uint256[2] memory amounts = [uint256(0), type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            _setAmount(calls, amounts[i]);
            adapter.manage(calls);
            assertEq(
                BorrowTemplateRecorder(recorder).lastCall(),
                abi.encodeCall(BorrowCapabilityPoolMock.borrow, (asset, amounts[i], 2, 0, address(adapter)))
            );
        }
    }

    function test_CollateralWithdrawalIsCheckedAndPartialRepaymentRemainsAvailable() public {
        _borrow(200e18);
        BorrowTestCall memory operation = BorrowTestCall(
            pool, abi.encodeCall(BorrowCapabilityPoolMock.withdrawCollateral, (uint256(0), address(adapter)))
        );
        IMerkleAdapter.Action[] memory calls = _publishBorrowAt(operation, health, 0);
        _setAmount(calls, 1e18);
        vm.expectRevert(IBorrowCapability.HealthFactorTooLow.selector);
        adapter.manage(calls);
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 1.19e18);
        adapter.manage(calls);
        assertEq(BorrowCapabilityPoolMock(pool).collateral(address(adapter)), 239e18);
        BorrowCapabilityPoolMock(pool).setCollateral(address(adapter), 100e18);
        _manage(asset, abi.encodeCall(IERC20.approve, (pool, 1e18)));
        _manage(pool, abi.encodeCall(BorrowCapabilityPoolMock.repay, (1e18, address(adapter))));
        assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 199e18);
        assertLt(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 1.2e18);
    }

    function testFuzz_FinalHealthBoundsBorrowedDebt(uint256 amount, uint256 minimum) public {
        amount = bound(amount, 1, 1000e18);
        minimum = bound(minimum, 1, 10e18);
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), minimum);
        if (240e36 / amount < minimum) {
            _expectBorrowRevert(amount, IBorrowCapability.HealthFactorTooLow.selector);
            assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), 0);
        } else {
            _borrow(amount);
            assertEq(BorrowCapabilityPoolMock(pool).debt(address(adapter)), amount);
            assertEq(IERC20(asset).balanceOf(address(adapter)), amount);
        }
        assertEq(IERC20(asset).balanceOf(implementation), 0);
    }

    /// forge-config: default.isolate = true
    function test_GasBorrow() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 100e18);
        adapter.manage(calls);
        vm.snapshotGasLastCall("BorrowCapability", "borrow");
    }

    /// forge-config: default.isolate = true
    function test_GasSetHealthFactor() public {
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 2e18);
        vm.snapshotGasLastCall("BorrowCapability", "setHealthFactor");
    }

    /// forge-config: default.isolate = true
    function test_GasSetInitialHealthFactor() public {
        BorrowTestCall memory another = BorrowTestCall(pool, "");
        _setHealthFactor(keccak256(abi.encode(another.target, another.data)), 2e18);
        vm.snapshotGasLastCall("BorrowCapability", "setInitialHealthFactor");
    }

    /// forge-config: default.isolate = true
    function test_GasMinHealthFactor() public {
        BorrowCapability(address(adapter)).minHealthFactor(keccak256(abi.encode(health.target, health.data)));
        vm.snapshotGasLastCall("BorrowCapability", "minHealthFactor");
    }

    /// forge-config: default.isolate = true
    function test_GasGetHealthFactor() public {
        BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data);
        vm.snapshotGasLastCall("BorrowCapability", "getHealthFactor");
    }

    function _freshAdapter() internal {
        _deployAdapter(asset);
        _installCapability(adapter, implementation, _borrowSelectors());
        BorrowCapabilityPoolMock(pool).setCollateral(address(adapter), 240e18);
        health = BorrowTestCall(helper, abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, address(adapter))));
    }

    function _borrowCall() internal view returns (BorrowTestCall memory) {
        return BorrowTestCall(
            pool, abi.encodeCall(BorrowCapabilityPoolMock.borrow, (asset, uint256(0), 2, 0, address(adapter)))
        );
    }

    function _borrow(uint256 amount) internal returns (bytes memory) {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, amount);
        return adapter.manage(calls)[0];
    }

    function _expectBorrowRevert(uint256 amount, bytes4 errorSelector) internal {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, amount);
        vm.expectRevert(errorSelector);
        adapter.manage(calls);
    }

    function _publishBorrow(BorrowTestCall memory operation, BorrowTestCall memory healthCall)
        internal
        returns (IMerkleAdapter.Action[] memory calls)
    {
        return _publishBorrowAt(operation, healthCall, 1);
    }

    function _publishBorrowAt(BorrowTestCall memory operation, BorrowTestCall memory healthCall, uint256 amountWord)
        internal
        returns (IMerkleAdapter.Action[] memory calls)
    {
        bytes memory data = abi.encodeCall(
            IBorrowCapability.borrow, (operation.target, healthCall.target, operation.data, healthCall.data)
        );
        bytes memory mask = new bytes(data.length);
        // Selector + four argument words + lending bytes length + native selector.
        uint256 offset = 4 + 128 + 32 + 4 + amountWord * 32;
        bytes memory fixedData = bytes.concat(data);
        for (uint256 i = offset; i < offset + 32; ++i) {
            mask[i] = 0xff;
            fixedData[i] = 0;
        }
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(address(adapter), bytes1(0), keccak256(mask), keccak256(fixedData))))
        );
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(this));
        calls = new IMerkleAdapter.Action[](1);
        calls[0] = IMerkleAdapter.Action(address(adapter), 0, data, mask, new bytes32[](0));
        _includeHealthFactorLeaf(calls, keccak256(abi.encode(healthCall.target, healthCall.data)));
    }

    function _setAmount(IMerkleAdapter.Action[] memory calls, uint256 amount) internal pure {
        bytes memory data = calls[0].data;
        uint256 offset;
        while (calls[0].dataMask[offset] == 0) ++offset;
        assembly ("memory-safe") { mstore(add(add(data, 32), offset), amount) }
    }
}

contract BorrowTemplateRecorder {
    bytes public lastCall;

    fallback(bytes calldata data) external returns (bytes memory) {
        lastCall = data;
        return data;
    }
}

contract BorrowOwnerCallback {
    address internal immutable _adapter;
    BorrowTestCall internal _health;

    constructor(address newAdapter, BorrowTestCall memory newHealth) {
        _adapter = newAdapter;
        _health = newHealth;
    }

    function lowerMinimum() public {
        BorrowCapability(_adapter).setHealthFactor(keccak256(abi.encode(_health.target, _health.data)), 1);
    }
}

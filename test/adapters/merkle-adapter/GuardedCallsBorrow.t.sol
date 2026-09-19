// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/capabilities/borrow-capability/AaveHealthFactor.sol";
import {GuardedCallsPoolMock, GuardedCallsTokenMock} from "./mocks/GuardedCallsMocks.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {ICapability} from "src/interfaces/merkle-adapter/capabilities/ICapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMorphoBase, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/GuardedCallsMocks.sol";

contract GuardedCallsBorrowTest is CapabilityTestBase {
    address internal asset;
    address internal pool;
    address internal helper;
    address internal implementation;
    BorrowTestCall internal health;

    function setUp() public {
        asset = address(new GuardedCallsTokenMock());
        pool = address(new GuardedCallsPoolMock(asset));
        helper = address(new AaveHealthFactor());
        GuardedCallsTokenMock(asset).mint(pool, 10_000e18);
        implementation =
            IImmutableFactory(address(new ImmutableFactory(type(GuardedCallsCapability).creationCode))).create("");
        _freshAdapter();
        _minimum = 1.2e18;
    }

    function test_BorrowUsesAdapterAsCallerDebtOwnerAndRecipientWithoutDelegation() public {
        GuardedCallsTokenMock(asset).mint(address(adapter), 3e18);
        bytes memory result = _borrow(200e18);
        assertEq(abi.decode(abi.decode(result, (bytes[]))[0], (uint256)), 200e18);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 203e18);
        assertEq(IERC20(asset).balanceOf(implementation), 0);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 200e18);
        assertEq(GuardedCallsPoolMock(pool).debt(implementation), 0);
        assertEq(GuardedCallsPoolMock(pool).delegation(address(adapter), implementation), 0);
        assertEq(_healthValue(health.target, health.data), 1.2e18);
    }

    function test_BelowFloorRollsBackDebtAndTokenTransfer() public {
        GuardedCallsTokenMock(asset).mint(address(adapter), 3e18);
        _expectBorrowRevert(240e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 3e18);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
        assertEq(IERC20(asset).balanceOf(pool), 10_000e18);
    }

    function test_BorrowAfterRepaymentUsesCurrentDebt() public {
        _borrow(200e18);
        _manage(asset, abi.encodeCall(IERC20.approve, (pool, 100e18)));
        _manage(pool, abi.encodeCall(GuardedCallsPoolMock.repay, (100e18, address(adapter))));
        _borrow(100e18);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 200e18);
        _expectBorrowRevert(1e18, IGuardedCallsCapability.CheckFailed.selector);
    }

    function test_OneInstalledCapabilityHandlesIndependentPools() public {
        _borrow(100e18);
        address firstPool = pool;
        pool = address(new GuardedCallsPoolMock(asset));
        GuardedCallsTokenMock(asset).mint(pool, 10_000e18);
        GuardedCallsPoolMock(pool).setCollateral(address(adapter), 120e18);
        health = BorrowTestCall(helper, abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, address(adapter))));
        _minimum = 2e18;
        bytes memory data = _guardedData(_borrowCall().target, health.target, _borrowCall().data, health.data);
        IMerkleAdapter.Action[] memory unapproved = new IMerkleAdapter.Action[](1);
        unapproved[0] = IMerkleAdapter.Action(address(adapter), 0, data, new bytes(data.length), new bytes32[](0));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(unapproved);
        _borrow(60e18);
        _expectBorrowRevert(1e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(adapter.getCapabilities().length, 1);
        assertEq(adapter.capabilityBySelector(IGuardedCallsCapability.execute.selector), implementation);
        assertEq(GuardedCallsPoolMock(firstPool).debt(address(adapter)), 100e18);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 60e18);
    }

    function test_TwoAssetsInOnePoolShareTheirAccountMinimum() public {
        _borrow(100e18);
        asset = address(new GuardedCallsTokenMock());
        GuardedCallsTokenMock(asset).mint(pool, 10_000e18);
        GuardedCallsPoolMock(pool).setReserve(asset);
        _borrow(100e18);
        _expectBorrowRevert(1e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 200e18);
        assertEq(_healthValue(health.target, health.data), 1.2e18);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 100e18);
    }

    function test_ThresholdCannotBeWeakenedOrMaskedByLeafRoleHolder() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        bytes memory acceptedData = calls[0].data;
        _minimum = 0;
        calls[0].data = _guardedData(_borrowCall().target, health.target, _borrowCall().data, health.data);
        uint256 changed;
        while (acceptedData[changed] == calls[0].data[changed]) ++changed;
        _setAmount(calls, 240e18);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(calls);
        calls[0].dataMask[changed] = 0xff;
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(calls);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_ThresholdChangeRequiresNewAcceptedLeafAndRole() public {
        _minimum = 2e18;
        IMerkleAdapter.Action[] memory previous = _publishBorrow(_borrowCall(), health);
        _setAmount(previous, 200e18);
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        adapter.manage(previous);
        bytes32 previousRoot = adapter.merkleRoot();
        _minimum = 1.2e18;
        IMerkleAdapter.Action[] memory replacement = _publishBorrow(_borrowCall(), health);
        bytes32 newRoot = adapter.merkleRoot();
        assertNotEq(newRoot, previousRoot);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(previous);
        adapter.revokeRole(newRoot, address(this));
        _setAmount(replacement, 200e18);
        vm.expectRevert();
        adapter.manage(replacement);
        adapter.grantRole(newRoot, address(this));
        adapter.manage(replacement);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 200e18);
    }

    function test_ProtocolCallbackCannotReenterManage() public {
        GuardedCallsPoolMock(pool)
            .setBorrowCallback(
                address(adapter), abi.encodeCall(IMerkleAdapter.manage, (new IMerkleAdapter.Action[](0)))
            );
        _expectBorrowRevert(200e18, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_AmountsVaryUnderTheSameAcceptedLeaf() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        bytes32 root = adapter.merkleRoot();
        _setAmount(calls, 60e18);
        adapter.manage(calls);
        _setAmount(calls, 140e18);
        adapter.manage(calls);
        assertEq(adapter.merkleRoot(), root);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 200e18);
    }

    function testFuzz_ChangingAnyPinnedByteInvalidatesTheProof(uint256 index, uint8 difference) public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        index = bound(index, 0, calls[0].data.length - 1);
        while (calls[0].dataMask[index] == 0xff) index = (index + 1) % calls[0].data.length;
        difference = uint8(bound(difference, 1, 255));
        calls[0].data[index] ^= bytes1(difference);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(calls);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_AValidProofDoesNotGrantTheCallerItsLeafRole() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 1e18);
        vm.prank(address(0xbad));
        vm.expectRevert();
        adapter.manage(calls);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
    }

    function testFuzz_PassesTheExactAaveCalldataWithoutChangingOtherArguments(uint256 amount) public {
        address recorder = address(new BorrowTemplateRecorder());
        BorrowTestCall memory operation = _borrowCall();
        operation.target = recorder;
        IMerkleAdapter.Action[] memory calls = _publishBorrow(operation, health);
        _setAmount(calls, amount);
        bytes[] memory result = adapter.manage(calls);
        bytes memory expected = abi.encodeCall(GuardedCallsPoolMock.borrow, (asset, amount, 2, 0, address(adapter)));
        assertEq(BorrowTemplateRecorder(recorder).lastCall(), expected);
        assertEq(abi.decode(result[0], (bytes[]))[0], expected);
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
        GuardedCallsPoolMock(pool).setFailBorrow(true);
        _expectBorrowRevert(1e18, GuardedCallsPoolMock.BorrowFailed.selector);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_HealthIsCheckedAfterProtocolCallbacks() public {
        GuardedCallsPoolMock(pool)
            .setBorrowCallback(pool, abi.encodeCall(GuardedCallsPoolMock.setCollateral, (address(adapter), 100e18)));
        _expectBorrowRevert(200e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(GuardedCallsPoolMock(pool).collateral(address(adapter)), 240e18);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
    }

    function test_QueryFailuresAndMalformedAaveResponsesRollBackBorrow() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            GuardedCallsPoolMock(pool)
                .setBorrowCallback(pool, abi.encodeCall(GuardedCallsPoolMock.setQueryMode, (mode)));
            IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
            _setAmount(calls, 200e18);
            vm.expectRevert();
            adapter.manage(calls);
            assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
            assertEq(GuardedCallsPoolMock(pool).queryMode(), 0);
        }
    }

    function test_HealthQueryUsesStaticCall() public {
        health = BorrowTestCall(pool, abi.encodeCall(GuardedCallsPoolMock.statefulHealth, ()));
        _minimum = 1.2e18;
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 1e18);
        vm.expectRevert();
        adapter.manage{gas: 2_000_000}(calls);
        assertEq(GuardedCallsPoolMock(pool).queryMode(), 0);
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
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
                abi.encodeCall(GuardedCallsPoolMock.borrow, (asset, amounts[i], 2, 0, address(adapter)))
            );
        }
    }

    function test_CollateralWithdrawalIsCheckedAndPartialRepaymentRemainsAvailable() public {
        _borrow(200e18);
        BorrowTestCall memory operation = BorrowTestCall(
            pool, abi.encodeCall(GuardedCallsPoolMock.withdrawCollateral, (uint256(0), address(adapter)))
        );
        IMerkleAdapter.Action[] memory calls = _publishBorrowAt(operation, health, 0);
        _setAmount(calls, 1e18);
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        adapter.manage(calls);
        _minimum = 1.19e18;
        calls = _publishBorrowAt(operation, health, 0);
        _setAmount(calls, 1e18);
        adapter.manage(calls);
        assertEq(GuardedCallsPoolMock(pool).collateral(address(adapter)), 239e18);
        GuardedCallsPoolMock(pool).setCollateral(address(adapter), 100e18);
        _manage(asset, abi.encodeCall(IERC20.approve, (pool, 1e18)));
        _manage(pool, abi.encodeCall(GuardedCallsPoolMock.repay, (1e18, address(adapter))));
        assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 199e18);
        assertLt(_healthValue(health.target, health.data), 1.2e18);
    }

    function testFuzz_FinalHealthBoundsBorrowedDebt(uint256 amount, uint256 minimum) public {
        amount = bound(amount, 1, 1000e18);
        minimum = bound(minimum, 1, 10e18);
        _minimum = minimum;
        if (240e36 / amount < minimum) {
            _expectBorrowRevert(amount, IGuardedCallsCapability.CheckFailed.selector);
            assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), 0);
        } else {
            _borrow(amount);
            assertEq(GuardedCallsPoolMock(pool).debt(address(adapter)), amount);
            assertEq(IERC20(asset).balanceOf(address(adapter)), amount);
        }
        assertEq(IERC20(asset).balanceOf(implementation), 0);
    }

    /// forge-config: default.isolate = true
    function test_GasBorrow() public {
        IMerkleAdapter.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 100e18);
        adapter.manage(calls);
        vm.snapshotGasLastCall("GuardedCallsCapability", "executeBorrow");
    }

    function _freshAdapter() internal {
        _deployAdapter(asset);
        _installCapability(adapter, implementation, _guardedSelectors());
        GuardedCallsPoolMock(pool).setCollateral(address(adapter), 240e18);
        health = BorrowTestCall(helper, abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, address(adapter))));
    }

    function _borrowCall() internal view returns (BorrowTestCall memory) {
        return
            BorrowTestCall(
                pool, abi.encodeCall(GuardedCallsPoolMock.borrow, (asset, uint256(0), 2, 0, address(adapter)))
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
        bytes memory data = _guardedData(operation.target, healthCall.target, operation.data, healthCall.data);
        bytes memory mask = new bytes(data.length);
        // Outer heads, call-array length/offset, Call heads, bytes length and native selector.
        uint256 offset = 4 + 64 + 32 + 32 + 64 + 32 + 4 + amountWord * 32;
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

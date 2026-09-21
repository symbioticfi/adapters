// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {GuardedCallsPoolMock, GuardedCallsTokenMock} from "./mocks/GuardedCallsMocks.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

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
        GuardedCallsTokenMock(asset).mint(account, 3e18);
        bytes memory result = _borrow(200e18);
        assertEq(abi.decode(abi.decode(result, (bytes[]))[0], (uint256)), 200e18);
        assertEq(IERC20(asset).balanceOf(account), 203e18);
        assertEq(IERC20(asset).balanceOf(implementation), 0);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 200e18);
        assertEq(GuardedCallsPoolMock(pool).debt(implementation), 0);
        assertEq(GuardedCallsPoolMock(pool).delegation(account, implementation), 0);
        assertEq(_healthValue(health.target, health.data), 1.2e18);
    }

    function test_BelowFloorRollsBackDebtAndTokenTransfer() public {
        GuardedCallsTokenMock(asset).mint(account, 3e18);
        _expectBorrowRevert(240e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(IERC20(asset).balanceOf(account), 3e18);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
        assertEq(IERC20(asset).balanceOf(pool), 10_000e18);
    }

    function test_BorrowAfterRepaymentUsesCurrentDebt() public {
        _borrow(200e18);
        _manage(asset, abi.encodeCall(IERC20.approve, (pool, 100e18)));
        _manage(pool, abi.encodeCall(GuardedCallsPoolMock.repay, (100e18, account)));
        _borrow(100e18);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 200e18);
        _expectBorrowRevert(1e18, IGuardedCallsCapability.CheckFailed.selector);
    }

    function test_OneInstalledCapabilityHandlesIndependentPools() public {
        _borrow(100e18);
        address firstPool = pool;
        pool = address(new GuardedCallsPoolMock(asset));
        GuardedCallsTokenMock(asset).mint(pool, 10_000e18);
        GuardedCallsPoolMock(pool).setCollateral(account, 120e18);
        health =
            BorrowTestCall({target: helper, data: abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, account))});
        _minimum = 2e18;
        bytes memory data = _guardedData(_borrowCall().target, health.target, _borrowCall().data, health.data);
        IMerkleAccount.Action[] memory unapproved = new IMerkleAccount.Action[](1);
        unapproved[0] = IMerkleAccount.Action({
            target: account, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(unapproved);
        _borrow(60e18);
        _expectBorrowRevert(1e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        assertEq(
            MerkleAccount(payable(account)).capabilityBySelector(IGuardedCallsCapability.execute.selector),
            implementation
        );
        assertEq(GuardedCallsPoolMock(firstPool).debt(account), 100e18);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 60e18);
    }

    function test_TwoAssetsInOnePoolShareTheirAccountMinimum() public {
        _borrow(100e18);
        asset = address(new GuardedCallsTokenMock());
        GuardedCallsTokenMock(asset).mint(pool, 10_000e18);
        GuardedCallsPoolMock(pool).setReserve(asset);
        _borrow(100e18);
        _expectBorrowRevert(1e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 200e18);
        assertEq(_healthValue(health.target, health.data), 1.2e18);
        assertEq(IERC20(asset).balanceOf(account), 100e18);
    }

    function test_ThresholdCannotBeWeakenedOrMaskedByLeafRoleHolder() public {
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        bytes memory acceptedData = calls[0].data;
        _minimum = 0;
        calls[0].data = _guardedData(_borrowCall().target, health.target, _borrowCall().data, health.data);
        uint256 changed;
        while (acceptedData[changed] == calls[0].data[changed]) ++changed;
        _setAmount(calls, 240e18);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(calls);
        calls[0].dataMask[changed] = 0xff;
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(calls);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
    }

    function test_ThresholdChangeRequiresNewAcceptedLeafAndRole() public {
        _minimum = 2e18;
        IMerkleAccount.Action[] memory previous = _publishBorrow(_borrowCall(), health);
        _setAmount(previous, 200e18);
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(previous);
        bytes32 previousRoot = MerkleAccount(payable(account)).merkleRoot();
        _minimum = 1.2e18;
        IMerkleAccount.Action[] memory replacement = _publishBorrow(_borrowCall(), health);
        bytes32 newRoot = MerkleAccount(payable(account)).merkleRoot();
        assertNotEq(newRoot, previousRoot);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(previous);
        MerkleAccount(payable(account)).revokeRole(newRoot, address(this));
        _setAmount(replacement, 200e18);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(replacement);
        MerkleAccount(payable(account)).grantRole(newRoot, address(this));
        MerkleAccount(payable(account)).manage(replacement);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 200e18);
    }

    function test_ProtocolCallbackCannotReenterManage() public {
        GuardedCallsPoolMock(pool)
            .setBorrowCallback(account, abi.encodeCall(IMerkleAccount.manage, (new IMerkleAccount.Action[](0))));
        _expectBorrowRevert(200e18, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
    }

    function test_AmountsVaryUnderTheSameAcceptedLeaf() public {
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        bytes32 root = MerkleAccount(payable(account)).merkleRoot();
        _setAmount(calls, 60e18);
        MerkleAccount(payable(account)).manage(calls);
        _setAmount(calls, 140e18);
        MerkleAccount(payable(account)).manage(calls);
        assertEq(MerkleAccount(payable(account)).merkleRoot(), root);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 200e18);
    }

    function testFuzz_ChangingAnyPinnedByteInvalidatesTheProof(uint256 index, uint8 difference) public {
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        index = bound(index, 0, calls[0].data.length - 1);
        while (calls[0].dataMask[index] == 0xff) index = (index + 1) % calls[0].data.length;
        difference = uint8(bound(difference, 1, 255));
        calls[0].data[index] ^= bytes1(difference);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(calls);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
    }

    function test_AValidProofDoesNotGrantTheCallerItsLeafRole() public {
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 1e18);
        vm.prank(address(0xbad));
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(calls);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
    }

    function testFuzz_PassesTheExactAaveCalldataWithoutChangingOtherArguments(uint256 amount) public {
        address recorder = address(new BorrowTemplateRecorder());
        BorrowTestCall memory operation = _borrowCall();
        operation.target = recorder;
        IMerkleAccount.Action[] memory calls = _publishBorrow(operation, health);
        _setAmount(calls, amount);
        bytes[] memory result = MerkleAccount(payable(account)).manage(calls);
        bytes memory expected = abi.encodeCall(GuardedCallsPoolMock.borrow, (asset, amount, 2, 0, account));
        assertEq(BorrowTemplateRecorder(recorder).lastCall(), expected);
        assertEq(abi.decode(result[0], (bytes[]))[0], expected);
        assertEq(operation.data, _borrowCall().data);
    }

    function testFuzz_PassesTheExactMorphoCalldata(uint256 amount) public {
        address recorder = address(new BorrowTemplateRecorder());
        MarketParams memory market = MarketParams({
            loanToken: asset, collateralToken: address(2), oracle: address(3), irm: address(4), lltv: 0.86e18
        });
        BorrowTestCall memory operation = BorrowTestCall({
            target: recorder, data: abi.encodeCall(IMorphoBase.borrow, (market, uint256(0), 0, account, account))
        });
        IMerkleAccount.Action[] memory calls = _publishBorrowAt(operation, health, 5);
        _setAmount(calls, amount);
        MerkleAccount(payable(account)).manage(calls);
        assertEq(
            BorrowTemplateRecorder(recorder).lastCall(),
            abi.encodeCall(IMorphoBase.borrow, (market, amount, 0, account, account))
        );
    }

    function test_ProtocolFailureBubbles() public {
        GuardedCallsPoolMock(pool).setFailBorrow(true);
        _expectBorrowRevert(1e18, GuardedCallsPoolMock.BorrowFailed.selector);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
    }

    function test_HealthIsCheckedAfterProtocolCallbacks() public {
        GuardedCallsPoolMock(pool)
            .setBorrowCallback(pool, abi.encodeCall(GuardedCallsPoolMock.setCollateral, (account, 100e18)));
        _expectBorrowRevert(200e18, IGuardedCallsCapability.CheckFailed.selector);
        assertEq(GuardedCallsPoolMock(pool).collateral(account), 240e18);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
    }

    function test_QueryFailuresAndMalformedAaveResponsesRollBackBorrow() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            GuardedCallsPoolMock(pool)
                .setBorrowCallback(pool, abi.encodeCall(GuardedCallsPoolMock.setQueryMode, (mode)));
            IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
            _setAmount(calls, 200e18);
            vm.expectRevert();
            MerkleAccount(payable(account)).manage(calls);
            assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
            assertEq(GuardedCallsPoolMock(pool).queryMode(), 0);
        }
    }

    function test_HealthQueryUsesStaticCall() public {
        health = BorrowTestCall({target: pool, data: abi.encodeCall(GuardedCallsPoolMock.statefulHealth, ())});
        _minimum = 1.2e18;
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 1e18);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage{gas: 2_000_000}(calls);
        assertEq(GuardedCallsPoolMock(pool).queryMode(), 0);
        assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
    }

    function test_ZeroAndMaximumAmountsArePassedThroughWithoutSpecialMeaning() public {
        address recorder = address(new BorrowTemplateRecorder());
        BorrowTestCall memory operation = _borrowCall();
        operation.target = recorder;
        IMerkleAccount.Action[] memory calls = _publishBorrow(operation, health);
        uint256[2] memory amounts = [uint256(0), type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            _setAmount(calls, amounts[i]);
            MerkleAccount(payable(account)).manage(calls);
            assertEq(
                BorrowTemplateRecorder(recorder).lastCall(),
                abi.encodeCall(GuardedCallsPoolMock.borrow, (asset, amounts[i], 2, 0, account))
            );
        }
    }

    function test_CollateralWithdrawalIsCheckedAndPartialRepaymentRemainsAvailable() public {
        _borrow(200e18);
        BorrowTestCall memory operation = BorrowTestCall({
            target: pool, data: abi.encodeCall(GuardedCallsPoolMock.withdrawCollateral, (uint256(0), account))
        });
        IMerkleAccount.Action[] memory calls = _publishBorrowAt(operation, health, 0);
        _setAmount(calls, 1e18);
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(calls);
        _minimum = 1.19e18;
        calls = _publishBorrowAt(operation, health, 0);
        _setAmount(calls, 1e18);
        MerkleAccount(payable(account)).manage(calls);
        assertEq(GuardedCallsPoolMock(pool).collateral(account), 239e18);
        GuardedCallsPoolMock(pool).setCollateral(account, 100e18);
        _manage(asset, abi.encodeCall(IERC20.approve, (pool, 1e18)));
        _manage(pool, abi.encodeCall(GuardedCallsPoolMock.repay, (1e18, account)));
        assertEq(GuardedCallsPoolMock(pool).debt(account), 199e18);
        assertLt(_healthValue(health.target, health.data), 1.2e18);
    }

    function testFuzz_FinalHealthBoundsBorrowedDebt(uint256 amount, uint256 minimum) public {
        amount = bound(amount, 1, 1000e18);
        minimum = bound(minimum, 1, 10e18);
        _minimum = minimum;
        if (240e36 / amount < minimum) {
            _expectBorrowRevert(amount, IGuardedCallsCapability.CheckFailed.selector);
            assertEq(GuardedCallsPoolMock(pool).debt(account), 0);
        } else {
            _borrow(amount);
            assertEq(GuardedCallsPoolMock(pool).debt(account), amount);
            assertEq(IERC20(asset).balanceOf(account), amount);
        }
        assertEq(IERC20(asset).balanceOf(implementation), 0);
    }

    /// forge-config: default.isolate = true
    function test_GasBorrow() public {
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, 100e18);
        MerkleAccount(payable(account)).manage(calls);
        vm.snapshotGasLastCall("GuardedCallsCapability", "executeBorrow");
    }

    function _freshAdapter() internal {
        _deployAdapter(asset);
        _installCapability(adapter, implementation, _guardedSelectors());
        GuardedCallsPoolMock(pool).setCollateral(account, 240e18);
        health =
            BorrowTestCall({target: helper, data: abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, account))});
    }

    function _borrowCall() internal view returns (BorrowTestCall memory) {
        return BorrowTestCall({
            target: pool, data: abi.encodeCall(GuardedCallsPoolMock.borrow, (asset, uint256(0), 2, 0, account))
        });
    }

    function _borrow(uint256 amount) internal returns (bytes memory) {
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, amount);
        return MerkleAccount(payable(account)).manage(calls)[0];
    }

    function _expectBorrowRevert(uint256 amount, bytes4 errorSelector) internal {
        IMerkleAccount.Action[] memory calls = _publishBorrow(_borrowCall(), health);
        _setAmount(calls, amount);
        vm.expectRevert(errorSelector);
        MerkleAccount(payable(account)).manage(calls);
    }

    function _publishBorrow(BorrowTestCall memory operation, BorrowTestCall memory healthCall)
        internal
        returns (IMerkleAccount.Action[] memory calls)
    {
        return _publishBorrowAt(operation, healthCall, 1);
    }

    function _publishBorrowAt(BorrowTestCall memory operation, BorrowTestCall memory healthCall, uint256 amountWord)
        internal
        returns (IMerkleAccount.Action[] memory calls)
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
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(account, bytes1(0), keccak256(mask), keccak256(fixedData)))));
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        calls = new IMerkleAccount.Action[](1);
        calls[0] =
            IMerkleAccount.Action({target: account, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _setAmount(IMerkleAccount.Action[] memory calls, uint256 amount) internal pure {
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

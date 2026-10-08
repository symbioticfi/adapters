// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterDelegatorMock
} from "test/adapters/MerkleAdapter.t.sol";
import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

contract MerkleAccountCaller {
    function caller() public view returns (address) {
        return msg.sender;
    }
}

contract MerkleAccountTest is CapabilityTestBase {
    address internal _assetToken;
    address internal _delegator;

    function setUp() public {
        _assetToken = address(new Token("asset"));
        _deployAdapter(_assetToken);
        _delegator = address(new MerkleAdapterDelegatorMock(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(_delegator);
    }

    function test_ManagedCallsOriginateOutsideReserveCustody() public {
        address target = address(new MerkleAccountCaller());
        address caller = abi.decode(_manage(target, abi.encodeCall(MerkleAccountCaller.caller, ())), (address));
        assertNotEq(caller, address(adapter));
        assertGt(caller.code.length, 0);
    }

    /// forge-config: default.isolate = true
    function test_AccountRejectsManagementWithoutLeafRole() public {
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(new MerkleAccountCaller()), abi.encodeCall(MerkleAccountCaller.caller, ()));
        bytes32 leaf = IMerkleAccount(account).root();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xBAD), leaf)
        );
        vm.prank(address(0xBAD));
        vm.startSnapshotGas("MerkleAccount", "manageMissingRoleRegion");
        IMerkleAccount(account).manage(actions);
        vm.stopSnapshotGas();
    }

    /// forge-config: default.isolate = true
    function test_AccountExecutionGas() public {
        address custody = adapter.account();
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(new MerkleAccountCaller()), abi.encodeCall(MerkleAccountCaller.caller, ()));
        bytes[] memory results = IMerkleAccount(custody).manage(actions);
        vm.snapshotGasLastCall("manage");
        assertEq(abi.decode(results[0], (address)), custody);
    }

    /// forge-config: default.isolate = true
    function test_PushGas() public {
        address custody = adapter.account();
        IERC20(_assetToken).transfer(adapter.vault(), 30);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 30);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 30);
        IERC20(_assetToken).transfer(address(adapter), 70);
        vm.prank(custody);
        adapter.push(70);
        vm.snapshotGasLastCall("push");
        assertEq(IERC20(_assetToken).balanceOf(custody), 70);
        assertEq(IERC20(_assetToken).balanceOf(address(adapter)), adapter.pendingDeallocation());
    }

    function test_PushRejectsDirectCaller() public {
        IERC20(_assetToken).transfer(address(adapter), 100);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.push(100);
        assertEq(IERC20(_assetToken).balanceOf(address(adapter)), 100);
    }

    function test_NewAllocationsCanBePushedImmediately() public {
        IERC20(_assetToken).transfer(adapter.vault(), 100);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 100);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.push, (100)));
        assertEq(IERC20(_assetToken).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_assetToken).balanceOf(adapter.account()), 100);
        assertEq(adapter.netFlow(), 100);
    }

    function testFuzz_PushPreservesReserves(uint96 reserved, uint96 available, uint96 requested) public {
        reserved = uint96(bound(reserved, 1, 1e24));
        available = uint96(bound(available, 0, 1e24));
        requested = uint96(bound(requested, 0, uint256(available) + 1));
        deal(_assetToken, adapter.vault(), reserved);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), reserved);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), reserved);
        deal(_assetToken, address(adapter), uint256(reserved) + available);
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.push, (requested)));
        if (requested > available) vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        MerkleAccount(payable(account)).manage(actions);
        uint256 released = requested > available ? 0 : requested;
        assertEq(IERC20(_assetToken).balanceOf(address(adapter)), uint256(reserved) + available - released);
        assertEq(IERC20(_assetToken).balanceOf(adapter.account()), released);
        assertEq(adapter.pendingDeallocation(), reserved);
    }

    function test_ReturnedWithdrawalCannotBePushedWhileRequested() public {
        IERC20(_assetToken).transfer(adapter.vault(), 100);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 100);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.push, (100)));
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 40);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.pull, (40)));
        // Returned cash is locked until a report covers its staging block.
        assertEq(adapter.pendingDeallocation(), 40);
        assertEq(adapter.stagedLiquidity(), 40);
        assertEq(MerkleAdapterDelegatorMock(_delegator).deallocate(address(adapter), 40), 0);
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.push, (1)));
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        MerkleAccount(payable(account)).manage(actions);
        uint48 stagedAt = uint48(block.number);
        vm.roll(block.number + 1);
        MerkleAdapterOracleMock(adapter.oracle()).setSnapshotBlock(stagedAt);
        vm.prank(_delegator);
        adapter.deallocate(0);
        assertEq(adapter.releasedLiquidity(), 40);
        assertEq(MerkleAdapterDelegatorMock(_delegator).deallocate(address(adapter), 40), 40);
        assertEq(IERC20(_assetToken).balanceOf(adapter.vault()), 40);
        assertEq(IERC20(_assetToken).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_assetToken).balanceOf(adapter.account()), 60);
    }

    function test_DelayedSignedSpendCannotReachCurrentOrNewReserves() public {
        address custody = adapter.account();
        address spender = makeAddr("settlement relayer");
        IERC20(_assetToken).transfer(adapter.vault(), 30);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 30);
        IERC20(_assetToken).transfer(address(adapter), 70);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.push, (70)));
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(_assetToken),
            buyToken: IERC20(makeAddr("buy token")),
            receiver: custody,
            sellAmount: 70,
            buyAmount: 1,
            validTo: type(uint32).max,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        bytes32 domain = keccak256("settlement domain");
        _manage(
            custody,
            abi.encodeCall(
                IMerkleAccount.sign,
                (domain, abi.encode(GPv2Order.TYPE_HASH, order), flatPlan(abi.encode(GPv2Order.TYPE_HASH, order)))
            )
        );
        _manage(_assetToken, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)));
        assertEq(
            IMerkleAccount(custody).isValidSignature(GPv2Order.hash(order, domain), ""),
            IERC1271.isValidSignature.selector
        );
        assertEq(IERC20(_assetToken).allowance(address(adapter), spender), 0);

        // Later allocation stays with the adapter, outside the signed order's custody.
        IERC20(_assetToken).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        vm.prank(spender);
        IERC20(_assetToken).transferFrom(custody, spender, 70);
        assertEq(IERC20(_assetToken).balanceOf(address(adapter)), 80);
        assertEq(adapter.netFlow(), 80);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, custody, 0, 1));
        vm.prank(spender);
        IERC20(_assetToken).transferFrom(custody, spender, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        IERC20(_assetToken).transferFrom(address(adapter), spender, 1);
    }
}

contract MerkleAccountInvariantHandler is CapabilityTestBase {
    address public token;
    address public controller;
    address public custody;
    address public spender;
    address internal _delegator;

    constructor() {
        token = address(new Token("asset"));
        _deployAdapter(token);
        controller = address(adapter);
        custody = adapter.account();
        spender = address(0xdead);
        _delegator = address(new MerkleAdapterDelegatorMock(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(_delegator);
        IERC20(token).transfer(adapter.vault(), 1000e18);
        MerkleAdapterDelegatorMock(_delegator).allocate(controller, 1000e18);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(controller, 1000e18);
        IERC20(token).transfer(controller, 1000e18);
        _manage(token, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)));
    }

    function push(uint96 amount) public {
        uint256 available = IERC20(token).balanceOf(controller) - adapter.pendingDeallocation();
        amount = uint96(bound(amount, 0, available + 1));
        IMerkleAccount.Action[] memory actions = _publishCall(controller, abi.encodeCall(IMerkleAdapter.push, (amount)));
        if (amount > available) vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function spend(uint96 amount) public {
        amount = uint96(bound(amount, 0, IERC20(token).balanceOf(custody)));
        vm.prank(spender);
        IERC20(token).transferFrom(custody, spender, amount);
    }

    function returnAssets(uint96 amount) public {
        amount = uint96(bound(amount, 0, IERC20(token).balanceOf(custody)));
        _manage(controller, abi.encodeCall(IMerkleAdapter.pull, (amount)));
    }

    function allocate(uint96 amount) public {
        amount = uint96(bound(amount, 0, IERC20(token).balanceOf(address(this))));
        IERC20(token).transfer(adapter.vault(), amount);
        MerkleAdapterDelegatorMock(_delegator).allocate(controller, amount);
    }
}

contract MerkleAccountInvariantTest is CapabilityTestBase {
    address internal _handler;

    function setUp() public {
        _handler = address(new MerkleAccountInvariantHandler());
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MerkleAccountInvariantHandler.push.selector;
        selectors[1] = MerkleAccountInvariantHandler.spend.selector;
        selectors[2] = MerkleAccountInvariantHandler.returnAssets.selector;
        selectors[3] = MerkleAccountInvariantHandler.allocate.selector;
        targetSelector(FuzzSelector({addr: _handler, selectors: selectors}));
        targetContract(_handler);
    }

    function invariant_DelayedSpendersCannotReachVaultReserves() public view {
        address token = MerkleAccountInvariantHandler(_handler).token();
        address controller = MerkleAccountInvariantHandler(_handler).controller();
        assertGe(IERC20(token).balanceOf(controller), IMerkleAdapter(controller).pendingDeallocation());
        assertEq(IERC20(token).allowance(controller, MerkleAccountInvariantHandler(_handler).spender()), 0);
        assertEq(
            IERC20(token).balanceOf(controller) + IERC20(token).balanceOf(IMerkleAdapter(controller).vault())
                + IERC20(token).balanceOf(MerkleAccountInvariantHandler(_handler).custody())
                + IERC20(token).balanceOf(MerkleAccountInvariantHandler(_handler).spender()),
            1_000_000e18 - IERC20(token).balanceOf(_handler)
        );
    }
}

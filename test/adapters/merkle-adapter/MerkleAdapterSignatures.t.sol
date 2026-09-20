// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Token} from "test/mocks/Token.sol";

contract MerkleAdapterSignaturesTest is CapabilityTestBase {
    bytes32 internal domain = keccak256("test domain");

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
    }

    function testFuzz_ApprovesComputedDigest(bytes32 value) public {
        bytes memory data = abi.encode(keccak256("Data(bytes32 value)"), value);
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        IMerkleAdapter.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, data)));
        vm.expectEmit(true, false, false, true, account);
        emit IMerkleAccount.SetSignature(digest, data);
        adapter.manage(actions);
        assertTrue(IMerkleAccount(account).signatures(digest));
        assertFalse(IMerkleAccount(account).signatures(domain));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        assertEq(IMerkleAccount(account).isValidSignature(digest, hex"1234"), IERC1271.isValidSignature.selector);
        assertEq(adapter.getCapabilities().length, 0);
    }

    function test_OwnerCannotApproveOrRevokeOutsideManage() public {
        vm.expectRevert(IMerkleAccount.InvalidCaller.selector);
        IMerkleAccount(account).setSignature(domain, abi.encode(bytes32(uint256(1))));
        vm.expectRevert(IMerkleAccount.InvalidCaller.selector);
        IMerkleAccount(account).revokeSignature(domain);
    }

    function test_ProofWithoutRoleCannotApprove() public {
        IMerkleAdapter.Action[] memory actions = _publishCall(
            account, abi.encodeCall(IMerkleAccount.setSignature, (domain, abi.encode(bytes32(uint256(1)))))
        );
        address caller = makeAddr("unapproved");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, adapter.merkleRoot()
            )
        );
        vm.prank(caller);
        adapter.manage(actions);
    }

    function test_DomainIsBoundByLeafAndDigest() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        IMerkleAdapter.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, data)));
        adapter.manage(actions);
        bytes32 other = keccak256("another domain");
        assertEq(
            IMerkleAccount(account).isValidSignature(MessageHashUtils.toTypedDataHash(other, keccak256(data)), ""),
            bytes4(0xffffffff)
        );
        actions[0].data = abi.encodeCall(IMerkleAccount.setSignature, (other, data));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(actions);
    }

    function testFuzz_DataCannotBeAssociatedWithAnUnrelatedDigest(bytes32 value) public {
        bytes memory data = abi.encode(keccak256("Data(bytes32 value)"), value);
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, data)));
        bytes32 actual = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        assertEq(IMerkleAccount(account).isValidSignature(bytes32(uint256(actual) ^ 1), data), bytes4(0xffffffff));
    }

    function test_UnknownDigestIsInvalidRegardlessOfSignatureBytes() public view {
        assertEq(IMerkleAccount(account).isValidSignature(bytes32(0), ""), bytes4(0xffffffff));
        assertEq(IMerkleAccount(account).isValidSignature(bytes32(0), hex"1234"), bytes4(0xffffffff));
    }

    function test_RevocationRequiresItsOwnLeafAndRole() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        IMerkleAdapter.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, data)));
        adapter.manage(actions);
        actions[0].data = abi.encodeCall(IMerkleAccount.revokeSignature, (digest));
        actions[0].dataMask = new bytes(actions[0].data.length);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(actions);
        actions = _publishCall(account, actions[0].data);
        vm.expectEmit(true, false, false, true, account);
        emit IMerkleAccount.RevokeSignature(digest);
        adapter.manage(actions);
        assertFalse(IMerkleAccount(account).signatures(digest));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), bytes4(0xffffffff));
    }

    function test_ApprovalsAreIndependent() public {
        bytes memory first = abi.encode(bytes32(uint256(1)));
        bytes memory second = abi.encode(bytes32(uint256(2)));
        bytes32 firstDigest = MessageHashUtils.toTypedDataHash(domain, keccak256(first));
        bytes32 secondDigest = MessageHashUtils.toTypedDataHash(domain, keccak256(second));
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, first)));
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, second)));
        _manage(account, abi.encodeCall(IMerkleAccount.revokeSignature, (firstDigest)));
        assertEq(IMerkleAccount(account).isValidSignature(firstDigest, ""), bytes4(0xffffffff));
        assertEq(IMerkleAccount(account).isValidSignature(secondDigest, ""), IERC1271.isValidSignature.selector);
    }

    function test_RootAndRoleChangesDoNotImplicitlyRevokeApproval() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, data)));
        adapter.revokeRole(adapter.merkleRoot(), address(this));
        roots.setRoot(address(adapter), bytes32(0));
        adapter.acceptRoot(bytes32(0));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
    }

    function test_GuardChecksActualSignedAmountAndRollsBackApproval() public {
        _installCapability(adapter, address(new GuardedCallsCapability()), _guardedSelectors());
        Token token = new Token("guarded asset");
        deal(address(token), account, 100);
        IGuardedCallsCapability.Call[] memory calls = new IGuardedCallsCapability.Call[](1);
        calls[0] = IGuardedCallsCapability.Call({
            target: account,
            data: abi.encodeCall(
                IMerkleAccount.setSignature, (domain, abi.encode(keccak256("Order(uint256 amount)"), uint256(101)))
            )
        });
        IGuardedCallsCapability.Check[] memory checks = new IGuardedCallsCapability.Check[](1);
        checks[0] = IGuardedCallsCapability.Check({
            query: IGuardedCallsCapability.Call({
                target: address(token), data: abi.encodeCall(IERC20.balanceOf, (account))
            }),
            offset: 0,
            observation: IGuardedCallsCapability.Observation.After,
            comparison: IGuardedCallsCapability.Comparison.GreaterOrEqual,
            bound: IGuardedCallsCapability.Bound({
                source: IGuardedCallsCapability.Source.Calldata, value: 0, offset: 4 + 4 * 32
            })
        });
        IMerkleAdapter.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IGuardedCallsCapability.execute, (calls, checks)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domain, keccak256(abi.encode(keccak256("Order(uint256 amount)"), uint256(101)))
        );
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        adapter.manage(actions);
        assertFalse(IMerkleAccount(account).signatures(digest));
        deal(address(token), account, 101);
        adapter.manage(actions);
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    /// forge-config: default.isolate = true
    function test_GasApproveValidateAndRevoke() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        IMerkleAdapter.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, data)));
        adapter.manage(actions);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "approve");
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "validate");
        actions = _publishCall(account, abi.encodeCall(IMerkleAccount.revokeSignature, (digest)));
        adapter.manage(actions);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "revoke");
    }
}

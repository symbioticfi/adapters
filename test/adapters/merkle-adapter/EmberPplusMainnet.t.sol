// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {IEmberVault} from "src/interfaces/common/IEmberVault.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Native PPLUS contracts at a pinned block; USDC funding and the adapter vault/oracle are local fixtures.
contract EmberPplusMainnetTest is CapabilityTestBase {
    uint256 internal constant FORK_BLOCK = 26_204_923;
    address internal constant PPLUS = 0xbc5d3722376d44f3bC316C6EA61C9Bd553Be8CBe;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        _deployAdapter(USDC);
        deal(USDC, account, 1_000_000);
    }

    function test_MainnetDepositAndQueuedRequestKeepCustodyAndClearAllowances() public {
        _manage(USDC, abi.encodeCall(IERC20.approve, (PPLUS, 1_000_000)));
        uint256 shares =
            abi.decode(_manage(PPLUS, abi.encodeCall(IEmberVault.deposit, (1_000_000, account))), (uint256));
        _manage(USDC, abi.encodeCall(IERC20.approve, (PPLUS, 0)));
        assertEq(IERC20(USDC).balanceOf(account), 0);
        assertEq(IERC20(PPLUS).balanceOf(account), shares);
        assertEq(IERC20(USDC).allowance(account, PPLUS), 0);
        uint256 escrowBefore = IERC20(PPLUS).balanceOf(PPLUS);
        uint256 supplyBefore = IERC20(PPLUS).totalSupply();
        uint256 gross = IEmberVault(PPLUS).convertToAssets(shares);
        assertGt(gross, 0);
        assertGe(shares, IEmberVault(PPLUS).minWithdrawableShares());

        _manage(PPLUS, abi.encodeCall(IERC20.approve, (PPLUS, shares)));
        IEmberVault.WithdrawalRequest memory request = abi.decode(
            _manage(PPLUS, abi.encodeCall(IEmberVault.redeemShares, (shares, account))), (IEmberVault.WithdrawalRequest)
        );
        _manage(PPLUS, abi.encodeCall(IERC20.approve, (PPLUS, 0)));
        assertEq(IERC20(PPLUS).allowance(account, PPLUS), 0);
        assertEq(IERC20(PPLUS).balanceOf(account), 0);
        assertEq(IERC20(PPLUS).balanceOf(PPLUS), escrowBefore + shares);
        assertEq(IERC20(PPLUS).totalSupply(), supplyBefore);
        assertEq(IERC20(USDC).balanceOf(account), 0); // Requesting creates no cash or same-run repayment credit.
        assertEq(request.owner, account);
        assertEq(request.receiver, account);
        assertEq(request.shares, shares);
        assertEq(request.estimatedWithdrawAmount, gross);
        assertEq(request.timestamp, block.timestamp * 1000);
        (uint256 pendingShares, uint256[] memory ids, uint256[] memory cancelled) =
            IEmberVault(PPLUS).getAccountState(account);
        assertEq(pendingShares, shares);
        assertEq(ids.length, 1);
        assertEq(ids[0], request.sequenceNumber);
        assertEq(cancelled.length, 0);
    }

    function test_MainnetPermissionsRejectChangedReceiversAndInvalidProofsBeforeExternalCalls() public {
        IMerkleAccount.Action[] memory actions = _publishCall(PPLUS, abi.encodeCall(IEmberVault.deposit, (1, account)));
        actions[0].data = abi.encodeCall(IEmberVault.deposit, (1, address(this)));
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);

        actions = _publishCall(PPLUS, abi.encodeCall(IEmberVault.redeemShares, (100_000, account)));
        actions[0].data = abi.encodeCall(IEmberVault.redeemShares, (100_000, address(this)));
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);

        actions = _publishCall(PPLUS, abi.encodeCall(IEmberVault.redeemShares, (100_000, account)));
        actions[0].proof = new bytes32[](1);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(IERC20(USDC).balanceOf(account), 1_000_000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ActivityContext, ActivityPhaseScript} from "./ActivityContext.sol";
import {TestnetCatalog} from "../catalog/TestnetCatalog.sol";
import {
    TestnetEtherFiPool,
    TestnetLidoQueue,
    TestnetNativeStake,
    TestnetWrappedStake
} from "../protocols/TestnetEthRedemptions.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IEtherFiAccount} from "src/interfaces/ll-adapter/etherfi/IEtherFiAccount.sol";
import {IEtherFiWithdrawRequestNFT} from "src/interfaces/ll-adapter/etherfi/IEtherFiWithdrawRequestNFT.sol";
import {ILidoAccount} from "src/interfaces/ll-adapter/lido/ILidoAccount.sol";
import {ILidoWithdrawalQueue} from "src/interfaces/ll-adapter/lido/ILidoWithdrawalQueue.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title EthActivityScript
/// @notice Maintains genuinely funded fixture ETH inventory and rotates bounded native withdrawal settlement batches.
/// @dev Production account sync scans its complete tracked list; callers should pause new swaps at eight pending requests.
contract EthActivityScript is ActivityPhaseScript {
    using SafeERC20 for IERC20;

    error InvalidAccount();
    error InvalidFixture();
    error SettlementFailed();

    /* STATE VARIABLES */

    uint256 public nextCursor;

    /* PUBLIC FUNCTIONS */

    /// @notice Returns the account's tracked request count using at most 64 bounded getter probes.
    function pendingRequests(address account, address endpoint) public view returns (uint256 count) {
        uint256 upper = TestnetLidoQueue(payable(endpoint)).nextRequestId();
        if (upper == 0 || upper > type(uint64).max) revert InvalidFixture();
        --upper;
        while (count < upper) {
            uint256 middle = count + (upper - count) / 2;
            (bool exists,) = _requestAt(account, middle);
            if (exists) count = middle + 1;
            else upper = middle;
        }
    }

    /// @notice Settles ready fixture requests and replenishes owned wrapped inventory within the actual native budget.
    function runBase(ActivityContext memory context, bool broadcast) public returns (uint256 settled) {
        TestnetCatalog.Profile memory profile = TestnetCatalog.profile(context.profile);
        if (
            profile.mechanism != 6 || profile.variant > 1 || context.owner == address(0)
                || Ownable(context.endpoint).owner() != context.owner
                || Ownable(context.account).owner() != context.owner
                || IAccount(context.account).TOKEN_TO_REDEEM() != context.token
                || IAccount(context.account).ORACLE() != context.oracle
        ) revert InvalidFixture();
        address stake = TestnetWrappedStake(context.token).underlying();
        if (
            Ownable(stake).owner() != context.owner
                || TestnetNativeStake(stake).redemptionEndpoint() != context.endpoint
        ) revert InvalidFixture();
        if (profile.variant == 0) {
            if (
                TestnetLidoQueue(payable(context.endpoint)).stETH() != stake
                    || TestnetLidoQueue(payable(context.endpoint)).wstETH() != context.token
                    || ILidoAccount(payable(context.account)).WITHDRAWAL_QUEUE() != context.endpoint
                    || ILidoAccount(payable(context.account)).WETH() != context.asset
                    || ILidoAccount(payable(context.account)).STETH() != stake
            ) revert InvalidFixture();
        } else {
            if (
                TestnetEtherFiPool(payable(context.endpoint)).eETH() != stake
                    || TestnetEtherFiPool(payable(context.endpoint)).weETH() != context.token
                    || IEtherFiAccount(payable(context.account)).LIQUIDITY_POOL() != context.endpoint
                    || IEtherFiAccount(payable(context.account)).WITHDRAW_REQUEST_NFT() != context.endpoint
                    || IEtherFiAccount(payable(context.account)).WETH() != context.asset
                    || IEtherFiAccount(payable(context.account)).EETH() != stake
            ) revert InvalidFixture();
        }
        uint256 count = pendingRequests(context.account, context.endpoint);
        uint256[] memory ids = new uint256[](Math.min(count, 8));
        for (uint256 i; i < ids.length; ++i) {
            (, ids[i]) = _requestAt(context.account, (context.cursor % count + i) % count);
        }
        bool[] memory ready = new bool[](ids.length);
        uint256 budget = Math.min(context.assets, context.owner.balance);
        _start(context.owner, broadcast);
        if (profile.variant == 0) {
            ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory requests =
                ILidoWithdrawalQueue(context.endpoint).getWithdrawalStatus(ids);
            for (uint256 i; i < ids.length; ++i) {
                if (requests[i].owner != context.account || requests[i].isClaimed) revert InvalidAccount();
                ready[i] = requests[i].isFinalized;
                if (
                    !ready[i]
                        && block.timestamp
                            >= requests[i].timestamp + TestnetLidoQueue(payable(context.endpoint)).settlementDelay()
                ) {
                    budget = _fundCash(stake, requests[i].amountOfStETH, budget);
                    if (stake.balance >= requests[i].amountOfStETH) {
                        TestnetLidoQueue(payable(context.endpoint)).finalize(ids[i], requests[i].amountOfStETH);
                        ready[i] = true;
                    }
                }
            }
        } else {
            for (uint256 i; i < ids.length; ++i) {
                IEtherFiWithdrawRequestNFT.WithdrawRequest memory request =
                    IEtherFiWithdrawRequestNFT(context.endpoint).getRequest(ids[i]);
                if (
                    !request.isValid || TestnetEtherFiPool(payable(context.endpoint)).ownerOf(ids[i]) != context.account
                ) revert InvalidAccount();
                ready[i] = TestnetEtherFiPool(payable(context.endpoint)).finalized(ids[i]);
                if (
                    !ready[i]
                        && block.timestamp
                            >= uint256(TestnetEtherFiPool(payable(context.endpoint)).requestedAt(ids[i]))
                                + TestnetEtherFiPool(payable(context.endpoint)).settlementDelay()
                ) {
                    budget = _fundCash(stake, request.amountOfEEth, budget);
                    if (stake.balance >= request.amountOfEEth) {
                        TestnetEtherFiPool(payable(context.endpoint)).finalize(ids[i]);
                        ready[i] = true;
                    }
                }
            }
        }
        uint256 inventory =
            TestnetWrappedStake(context.token).getStETHByWstETH(IERC20(context.token).balanceOf(context.owner));
        if (inventory < context.assets && budget > 0) {
            uint256 amount = Math.min(context.assets - inventory, budget);
            if (TestnetWrappedStake(context.token).getWstETHByStETH(amount) > 0) {
                TestnetNativeStake(stake).deposit{value: amount}(context.owner);
                IERC20(stake).forceApprove(context.token, amount);
                TestnetWrappedStake(context.token).wrap(amount);
                IERC20(stake).forceApprove(context.token, 0);
            }
        }
        IAccount(context.account).sync();
        _stop(broadcast);
        if (profile.variant == 0) {
            ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory requests =
                ILidoWithdrawalQueue(context.endpoint).getWithdrawalStatus(ids);
            for (uint256 i; i < ids.length; ++i) {
                if (ready[i]) {
                    if (!requests[i].isClaimed) revert SettlementFailed();
                    ++settled;
                }
            }
        } else {
            for (uint256 i; i < ids.length; ++i) {
                if (ready[i]) {
                    if (IEtherFiWithdrawRequestNFT(context.endpoint).getRequest(ids[i]).isValid) {
                        revert SettlementFailed();
                    }
                    ++settled;
                }
            }
        }
        uint256 remaining = pendingRequests(context.account, context.endpoint);
        nextCursor = remaining == 0 ? 0 : (context.cursor % Math.max(count, 1) + ids.length) % remaining;
    }

    /* INTERNAL FUNCTIONS */

    function _fundCash(address stake, uint256 required, uint256 budget) internal returns (uint256) {
        if (stake.balance < required && budget > 0) {
            uint256 amount =
                Math.min(required - stake.balance, Math.min(budget, TestnetNativeStake(stake).deployedAssets()));
            if (amount > 0) {
                TestnetNativeStake(stake).fundLiquidity{value: amount}();
                budget -= amount;
            }
        }
        return budget;
    }

    function _requestAt(address account, uint256 index) internal view returns (bool exists, uint256 id) {
        (bool success, bytes memory result) = account.staticcall(abi.encodeCall(ILidoAccount.requestIds, (index)));
        if (!success) {
            // Solidity's generated public-array getters can report an absent index with empty revert data.
            if (
                result.length > 0
                    && keccak256(result) != keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(0x32)))
            ) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            return (false, 0);
        }
        id = abi.decode(result, (uint64));
        if (id == 0) revert InvalidAccount();
        return (true, id);
    }
}

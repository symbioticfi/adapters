// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IClaimReadiness, MAX_CLAIM_SCAN} from "../../../interfaces/merkle-adapter/automations/IClaimReadiness.sol";
import {INoonWithdrawalHandler} from "../../../interfaces/ll-adapter/noon/INoonWithdrawalHandler.sol";
import {IParetoClaimState} from "../../../interfaces/ll-adapter/pareto/IParetoClaimState.sol";
import {IParetoCreditVault} from "../../../interfaces/ll-adapter/pareto/IParetoCreditVault.sol";
import {IParetoDepositQueue} from "../../../interfaces/ll-adapter/pareto/IParetoDepositQueue.sol";
import {IParetoWithdrawalQueue} from "../../../interfaces/ll-adapter/pareto/IParetoWithdrawalQueue.sol";
import {IThreeFRequest} from "../../../interfaces/3f-adapter/IThreeFRequest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ClaimReadiness
 * @notice Stateless owner-ledger selectors for native claim recipes.
 * @dev Queries return data only. The recipe must bind the same id to its
 * readiness checks and permissioned account-context claim, gate on the separate
 * entitlement word, and enforce the token/ledger effects after that claim.
 * Successive queries observe cleared owner entries and select further claims.
 * Failed required getters revert; no partial scope is presented as exhausted.
 * @custom:security-contact https://github.com/symbioticfi/adapters/security
 */
contract ClaimReadiness is IClaimReadiness {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IClaimReadiness
    function nextNoon(address handler, address account) public view returns (uint256 id, uint256 amount) {
        uint256 count = INoonWithdrawalHandler(handler).getUserNextRequestId(account);
        if (count > MAX_CLAIM_SCAN) revert ScanLimit();
        uint256 period = INoonWithdrawalHandler(handler).withdrawPeriod();
        for (uint256 i; i < count; ++i) {
            uint256 ready = _noonAmount(INoonWithdrawalHandler(handler).getWithdrawalRequest(account, i), period);
            if (ready != 0) return (i, ready);
        }
    }

    /// @inheritdoc IClaimReadiness
    function noonReady(address handler, address account, uint256 id) public view returns (uint256 amount) {
        if (id >= INoonWithdrawalHandler(handler).getUserNextRequestId(account)) return 0;
        return _noonAmount(
            INoonWithdrawalHandler(handler).getWithdrawalRequest(account, id),
            INoonWithdrawalHandler(handler).withdrawPeriod()
        );
    }

    /// @inheritdoc IClaimReadiness
    function nextPareto(address queue, address account, bool deposit)
        public
        view
        returns (uint256 epoch, uint256 entitlement)
    {
        uint256 current = IParetoCreditVault(IParetoWithdrawalQueue(queue).strategy()).epochNumber();
        if (current > MAX_CLAIM_SCAN - 2) revert ScanLimit();
        uint256 end = current + 2;
        for (uint256 i; i < end; ++i) {
            uint256 ready = paretoEpochReady(queue, account, deposit, i);
            if (ready != 0) return (i, ready);
        }
    }

    /// @inheritdoc IClaimReadiness
    function paretoEpochReady(address queue, address account, bool deposit, uint256 epoch)
        public
        view
        returns (uint256 entitlement)
    {
        if (deposit) {
            uint256 amount = IParetoDepositQueue(queue).userDepositsEpochs(account, epoch);
            if (
                amount != 0 && IParetoDepositQueue(queue).epochPrice(epoch) != 0
                    && IParetoDepositQueue(queue).epochPendingDeposits(epoch) == 0
                    && IParetoDepositQueue(queue).epochPrefundedDeposits(epoch) == 0
            ) return amount;
        } else {
            uint256 amount = IParetoWithdrawalQueue(queue).userWithdrawalsEpochs(account, epoch);
            if (
                amount != 0 && IParetoWithdrawalQueue(queue).epochWithdrawPrice(epoch) != 0
                    && IParetoWithdrawalQueue(queue).epochPendingClaims(epoch) == 0
            ) return amount;
        }
    }

    /// @inheritdoc IClaimReadiness
    function paretoReady(address cdo, address account, bool instant) public view returns (uint256 amount) {
        address strategy = IParetoClaimState(cdo).strategy();
        if (instant) {
            if (!IParetoClaimState(cdo).allowInstantWithdraw()) return 0;
            amount = IParetoClaimState(strategy).instantWithdrawsRequests(account);
        } else {
            uint256 epoch = IParetoCreditVault(strategy).epochNumber();
            if (
                IParetoClaimState(cdo).epochEndDate() != 0
                    && epoch <= IParetoClaimState(strategy).lastWithdrawRequest(account)
            ) return 0;
            (uint256 principal, uint256 requestEpoch, uint256 settledPrincipal, uint256 settledInterest) =
                IParetoClaimState(strategy).apr0Users(account);
            amount =
                IParetoClaimState(strategy).withdrawsRequests(account) + principal + settledPrincipal + settledInterest;
            if (principal != 0 && requestEpoch < epoch) {
                // Match the issuer's checked multiplication and floor rounding.
                amount += principal * IParetoClaimState(strategy).apr0RateByEpoch(requestEpoch) / 1e18;
            }
        }
        if (amount != 0 && IERC20(IParetoCreditVault(strategy).token()).balanceOf(strategy) < amount) return 0;
    }

    /// @inheritdoc IClaimReadiness
    function threeFReady(address request, address account) public view returns (uint256 amount) {
        if (!IThreeFRequest(request).canWithdraw()) return 0;
        (uint256 principal, uint256 yieldShares) = IThreeFRequest(request).balancesOf(account);
        if (principal == 0 && yieldShares == 0) return 0;
        (uint256 pAssets, uint256 yAssets) = IThreeFRequest(request).convertToAssets(principal, yieldShares);
        return pAssets + yAssets;
    }

    /* INTERNAL FUNCTIONS */

    function _noonAmount(INoonWithdrawalHandler.WithdrawalRequest memory request, uint256 period)
        internal
        view
        returns (uint256)
    {
        if (
            request.amount != 0 && !request.claimed && request.timestamp <= block.timestamp
                && period <= block.timestamp - request.timestamp
        ) return request.amount;
        return 0;
    }
}

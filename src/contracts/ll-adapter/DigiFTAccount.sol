// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {SettlementAccount, SettlementSubAccount} from "./common/SettlementAccount.sol";

import {IDigiFTAccount} from "../../interfaces/ll-adapter/digift/IDigiFTAccount.sol";
import {IDigiFTSubRedManagement} from "../../interfaces/ll-adapter/digift/IDigiFTSubRedManagement.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DigiFTAccount
/// @notice Account contract for DigiFT normal redemptions.
contract DigiFTAccount is SettlementAccount, IDigiFTAccount {
    /* IMMUTABLES */

    /// @inheritdoc IDigiFTAccount
    address public immutable SUB_RED_MANAGEMENT;

    /* CONSTRUCTOR */

    /// @notice Creates the DigiFT account implementation.
    constructor(
        address newOracle,
        address newFactory,
        address newTokenToRedeem,
        address newSubRedManagement,
        uint48 newSettlementDuration,
        address newCowSwapSettlement
    ) SettlementAccount(newOracle, newFactory, 0, newTokenToRedeem, 0, newSettlementDuration, newCowSwapSettlement) {
        SUB_RED_MANAGEMENT = newSubRedManagement;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Deploys a DigiFT request-holder subaccount.
    function _createSubAccount() internal override returns (address subAccount) {
        return address(new DigiFTSubAccount(_asset, address(this), TOKEN_TO_REDEEM, SUB_RED_MANAGEMENT));
    }

    /// @dev Additionally guards the legacy layout: pre-settlement-family DigiFTAccount extended
    /// `Account` directly, so its `subAccounts` array length lived at slot 15. The current
    /// storage-gap layout leaves that slot reserved, so a nonzero value there identifies legacy
    /// in-flight subaccounts that the current layout would otherwise strand. Without a deployed
    /// version discriminator, retain this conservative legacy check.
    function _migrate(uint64 oldVersion, uint64 newVersion, bytes calldata data) internal override {
        uint256 legacySubAccountsLength;
        assembly {
            legacySubAccountsLength := sload(15)
        }
        if (legacySubAccountsLength > 0) revert MigrationWithLiveSubAccounts();

        super._migrate(oldVersion, newVersion, data);
    }
}

/// @title DigiFTSubAccount
/// @notice Subaccount contract for one DigiFT normal redemption.
contract DigiFTSubAccount is SettlementSubAccount {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @dev DigiFT normal redemption manager.
    address internal immutable _SUB_RED_MANAGEMENT;

    /* CONSTRUCTOR */

    /// @notice Creates the DigiFT request-holder subaccount.
    constructor(address newAsset, address newAccount, address newTokenToRedeem, address newSubRedManagement)
        SettlementSubAccount(newAsset, newAccount, newTokenToRedeem)
    {
        _SUB_RED_MANAGEMENT = newSubRedManagement;
        IERC20(newTokenToRedeem).forceApprove(newSubRedManagement, type(uint256).max);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Submits held DigiFT tokens into a normal redemption.
    function _executeRedemption() internal override {
        IDigiFTSubRedManagement(_SUB_RED_MANAGEMENT)
            .redeem(_TOKEN_TO_REDEEM, _ASSET, IERC20(_TOKEN_TO_REDEEM).balanceOf(address(this)), block.timestamp);
    }
}

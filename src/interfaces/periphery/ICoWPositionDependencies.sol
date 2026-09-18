// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICoWSwapSettlement} from "src/interfaces/common/ICoWSwapConverter.sol";

/**
 * @title IPositionFlashLoanRouter
 * @notice Interface for the CoW flash-loan router used by the position executor.
 */
interface IPositionFlashLoanRouter {
    /* FUNCTIONS */

    /**
     * @notice Returns the settlement contract used by the router.
     */
    function settlementContract() external view returns (address);

    /**
     * @notice Resume the router's pending settlement after obtaining the flash loan.
     * @param data The unchanged callback data authenticated by the router.
     */
    function borrowerCallBack(bytes calldata data) external;
}

/**
 * @title IPositionFlashLender
 * @notice Interface for the Aave flash-loan pool used by the position executor.
 */
interface IPositionFlashLender {
    /* FUNCTIONS */

    /**
     * @notice Lend assets and collect repayment after the receiver's callback.
     * @param receiver The contract receiving the assets and executeOperation callback.
     * @param assets The assets to lend.
     * @param amounts The principal for each asset.
     * @param modes The debt modes; the executor uses zero to require flash repayment.
     * @param onBehalfOf The account used for debt-mode loans.
     * @param data The callback data forwarded to the receiver.
     * @param referralCode The Aave referral code.
     */
    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata data,
        uint16 referralCode
    ) external;
}

/**
 * @title IPositionSettlement
 * @notice Interface for reading the committed CoW sell order's fill amount.
 */
interface IPositionSettlement is ICoWSwapSettlement {
    /* FUNCTIONS */

    /**
     * @notice Returns the cumulative executed sell amount for a sell order UID.
     * @param uid The packed order digest, owner and expiry.
     */
    function filledAmount(bytes calldata uid) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOracle} from "../IOracle.sol";

/// @title INoonRedemptionOracle
/// @notice Prices sUSN in the collateral returned by the USN redeem handler.
interface INoonRedemptionOracle is IOracle {
    /// @notice Raised when the share's underlying is not the handler's USN token.
    error InvalidUnderlying();

    /// @notice Returns the sUSN token.
    /// @return token The share token.
    function TOKEN_TO_REDEEM() external view returns (address token);

    /// @notice Returns the native USN redeem handler.
    /// @return handler The redeem handler.
    function REDEEM_HANDLER() external view returns (address handler);

    /// @notice Returns the payment collateral used for the quote.
    /// @return token The collateral token.
    function QUOTE_TOKEN() external view returns (address token);
}

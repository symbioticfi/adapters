// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOracle} from "../../../ll-adapter/IOracle.sol";

/// @title INoonOracle
/// @notice Prices sUSN in the collateral returned by the USN redeem handler.
interface INoonOracle is IOracle {
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

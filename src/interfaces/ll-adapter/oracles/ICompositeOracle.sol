// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOracle} from "../IOracle.sol";

/// @title ICompositeOracle
/// @notice Converts a source price into the connector's quote using 1e18-scaled prices.
interface ICompositeOracle is IOracle {
    /// @notice Raised when the source oracle is not configured.
    error InvalidSource();

    /// @notice Returns the source oracle pricing the purchased token in its denomination.
    /// @return oracle The source oracle.
    function SOURCE_ORACLE() external view returns (address oracle);

    /// @notice Returns the denomination-to-common-quote oracle; zero means a 1:1 conversion.
    /// @return oracle The conversion oracle.
    function CONVERSION_ORACLE() external view returns (address oracle);

    /// @notice Returns the payment-token-to-common-quote oracle; zero means a 1:1 conversion.
    /// @return oracle The payment token oracle.
    function QUOTE_ORACLE() external view returns (address oracle);
}

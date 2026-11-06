// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOracle} from "../../../ll-adapter/IOracle.sol";

/// @title IOpenEdenTBILLOracle
/// @notice Prices TBILL through its native underlying conversion.
interface IOpenEdenTBILLOracle is IOracle {
    /// @notice Returns the TBILL vault/token.
    /// @return token The TBILL token.
    function TOKEN_TO_REDEEM() external view returns (address token);
}

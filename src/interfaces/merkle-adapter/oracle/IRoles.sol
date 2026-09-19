// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IRoles
 * @notice Role identifiers for MerkleAdapter oracle protection.
 */
abstract contract IRoles {
    /**
     * @notice Role allowed to freeze, unfreeze, and review an exact oracle report.
     */
    bytes32 public constant ORACLE_GUARD_ROLE = keccak256("ORACLE_GUARD_ROLE");
    /**
     * @notice Role allowed to configure NAV growth and loss limits.
     */
    bytes32 public constant ORACLE_LIMITS_ROLE = keccak256("ORACLE_LIMITS_ROLE");
    /**
     * @notice Role allowed to configure the maximum accepted NAV age.
     */
    bytes32 public constant ORACLE_AGE_ROLE = keccak256("ORACLE_AGE_ROLE");
}

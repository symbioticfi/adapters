// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICapability} from "./ICapability.sol";

/**
 * @title IBorrowCapability
 * @notice Interface for shared lending operations with curator-controlled health minimums.
 */
interface IBorrowCapability is ICapability {
    /* ERRORS */

    /**
     * @notice Raised when the position's health factor is below the curator's configured minimum.
     */
    error HealthFactorTooLow();

    /**
     * @notice Raised when the health query does not return exactly one ABI-encoded uint256.
     */
    error InvalidHealthFactorResponse();

    /**
     * @notice Raised when the curator attempts to set a zero minimum health factor.
     */
    error InvalidMinHealthFactor();

    /**
     * @notice Raised when no minimum has been configured for the exact health query.
     */
    error MinHealthFactorNotSet();

    /* EVENTS */

    /**
     * @notice Emitted when the lending call passes its health check.
     * @param target Lending contract called from the adapter.
     * @param healthFactorTarget Scalar health query target.
     * @param data Executed lending calldata, including the runtime amount.
     * @param healthFactorData Exact health query calldata identifying the curator's minimum.
     * @param value Health factor returned after the operation, scaled by 1e18.
     */
    event Borrow(address target, address healthFactorTarget, bytes data, bytes healthFactorData, uint256 value);

    /**
     * @notice Emitted when an authorized self-call updates the minimum for an exact health query.
     */
    event SetHealthFactor(bytes32 indexed healthFactorId, uint256 minHealthFactor);

    /* FUNCTIONS */

    /**
     * @notice Executes an approved lending call, then enforces its health minimum.
     * @dev Requires an adapter self-call through manage. The Merkle leaf must pin both targets,
     * the lending selector, market, account, recipient, ABI layout and the entire healthFactorData.
     * The adapter's action mask permits runtime amounts in data; no substitution is performed here.
     * Use this wrapper for borrowing and collateral withdrawals; other health-worsening operations must
     * also be checked or disallowed by the strategy. Native-currency calls are not supported.
     * The minimum is read before the protocol call and health is checked immediately afterward.
     * @param target Lending contract called from the adapter.
     * @param healthFactorTarget Fixed target returning a scalar health factor.
     * @param data Complete lending calldata, including the runtime amount.
     * @param healthFactorData Fixed query calldata returning one uint256 health factor scaled by 1e18.
     * @return result Unmodified protocol return data.
     */
    function borrow(address target, address healthFactorTarget, bytes calldata data, bytes calldata healthFactorData)
        external
        returns (bytes memory result);

    /**
     * @notice Sets the minimum for a health query without changing the strategy root.
     * @dev Requires an adapter self-call through manage with a valid Merkle proof and the caller's leaf role.
     * The leaf must fix healthFactorId while permitting the minimum to vary. Identical queries share one
     * floor across all borrowing and collateral-withdrawal leaves. It grants no lending permission.
     * @param healthFactorId keccak256(abi.encode(healthFactorTarget, healthFactorData)).
     * @param newMinHealthFactor Positive minimum health factor scaled by 1e18.
     */
    function setHealthFactor(bytes32 healthFactorId, uint256 newMinHealthFactor) external;

    /**
     * @notice Returns the adapter-local minimum for a health query; zero means execution is disabled.
     * @param healthFactorId keccak256(abi.encode(healthFactorTarget, healthFactorData)).
     */
    function minHealthFactor(bytes32 healthFactorId) external view returns (uint256);

    /**
     * @notice Returns the result of a scalar health query without enforcing a minimum.
     * @param healthFactorTarget Scalar health query target.
     * @param healthFactorData Query calldata returning exactly one uint256, scaled by 1e18.
     */
    function getHealthFactor(address healthFactorTarget, bytes calldata healthFactorData)
        external
        view
        returns (uint256);
}

/**
 * @title IBorrowCapabilityConstants
 * @notice Constants for the shared BorrowCapability storage namespace.
 */
abstract contract IBorrowCapabilityConstants {
    /// @dev keccak256(abi.encode(uint256(keccak256("symbiotic.storage.BorrowCapability")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 internal constant BORROW_STORAGE_LOCATION =
        0x14594e0b2a6dcf0d335223cd7b83327c553fe4ff39745016f5460d86c7a0dd00;
}

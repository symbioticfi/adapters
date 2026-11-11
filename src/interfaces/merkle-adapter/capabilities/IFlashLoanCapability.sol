// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

/**
 * @dev Namespaced transient request commitment shared by the loan entry point and callbacks.
 */
bytes32 constant FLASH_LOAN_SLOT = bytes32(erc7201("symbiotic.storage.FlashLoanCapability"));

/**
 * @title IFlashLoanCapability
 * @notice Interface for account-context Aave V3 and Morpho Blue flash loans.
 */
interface IFlashLoanCapability {
    /* ERRORS */

    /**
     * @notice Raised when a loan request is not an account self-call.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a callback does not match the pending request, is replayed,
     * has a foreign Aave initiator, or the lender returns without a callback.
     */
    error UnexpectedFlashLoan();

    /* STRUCTS */

    /**
     * @notice Supported flash loan protocols.
     */
    enum Type {
        Aave,
        Morpho
    }

    /* FUNCTIONS */

    /**
     * @notice Returns the fixed Aave V3 pool.
     */
    function AAVE_V3_POOL() external view returns (address);

    /**
     * @notice Returns the fixed Morpho Blue singleton.
     */
    function MORPHO_BLUE() external view returns (address);

    /**
     * @notice Borrows one asset, executes the committed account self-call, and repays the lender.
     * @dev Invoke through manage with this account as target. The outer leaf and caller's role
     * authorize the complete loan and callback; pin the protocol, token and all callback targets,
     * selectors and safety checks in that leaf. Mask only intentionally variable numerical inputs.
     * Encode IRecipeCapability.execute in data for a batch of external calls and assertions.
     * All three loan/callback selectors must be installed on the account. The capability's lender
     * addresses must be reviewed as the intended protocols before installation. Nested loans are
     * supported; inner manage calls remain forbidden by the account's reentrancy guard.
     * Any failure rolls back the loan and its actions. The account must cover Aave's premium.
     * @param providerType Aave V3 or Morpho Blue.
     * @param token Borrowed ERC-20 asset.
     * @param amount Borrowed principal in native token units.
     * @param data Calldata executed as an account self-call while holding the borrowed funds.
     */
    function flashLoan(Type providerType, address token, uint256 amount, bytes calldata data) external;

    /**
     * @notice Executes the pending Aave V3 callback and approves principal plus premium.
     * @dev Accepts only the exact pending request from the fixed pool with this account as initiator.
     * Authorization is consumed before executing params to prevent callback replay.
     * @param asset Borrowed token.
     * @param amount Borrowed principal.
     * @param premium Aave's additional repayment fee.
     * @param initiator Account that initiated the loan.
     * @param params Committed account self-call calldata.
     * @return True on successful execution.
     */
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);

    /**
     * @notice Executes the pending Morpho Blue callback and approves the principal.
     * @dev Authorization is consumed before executing the self-call to prevent callback replay.
     * @param assets Borrowed principal.
     * @param data ABI-encoded (address token, bytes selfCallData) from the pending request.
     */
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

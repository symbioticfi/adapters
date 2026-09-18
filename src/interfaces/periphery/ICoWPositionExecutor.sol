// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

/**
 * @title ICoWPositionExecutor
 * @notice Interface for atomic CoW position leverage and deleverage through a Merkle adapter.
 * @dev The fixed owner commits one full-fill sell order and one action batch.
 * Position calls run through accepted-root proofs and the executor's leaf roles. The immutable
 * Aave lender and CoW router must be trusted. Orders release the executor on completion or expiry;
 * there is no cancellation or standalone token recovery.
 */
interface ICoWPositionExecutor {
    /* ERRORS */

    /**
     * @notice Raised when an unexpired order is already armed.
     */
    error ActiveIntent();

    /**
     * @notice Raised when execution reduces the adapter's starting balance of either order token.
     */
    error AdapterBalanceReduced();

    /**
     * @notice Raised when the callback sender or initiator is invalid, or an entry is already executing.
     */
    error InvalidCallback();

    /**
     * @notice Raised when an order amount is zero or an action spends native value.
     */
    error InvalidIntent();

    /**
     * @notice Raised when the flash-loan premium exceeds the committed ceiling.
     */
    error InvalidLoan();

    /**
     * @notice Raised when settlement does not fill the UID and deliver the committed token amounts.
     */
    error OrderNotFilled();

    /**
     * @notice Raised when a caller is not the authorized owner or router.
     */
    error Unauthorized();

    /* STRUCTS */

    /**
     * @notice Exact parameters of a full-fill, zero-fee ERC-20 sell order received by this executor.
     * @param sellToken The token sold through CoW.
     * @param buyToken The token bought through CoW.
     * @param sellAmount The exact amount to sell.
     * @param buyAmount The minimum amount to receive.
     * @param validTo The final valid timestamp, inclusive.
     * @param appData The hash of the CoW order's application data.
     */
    struct Order {
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
    }

    /**
     * @notice Committed order, flash-loan terms and Merkle-authorized position changes.
     * @param order The exact CoW order parameters.
     * @param leverage True to swap debt for collateral before actions; false to repay and withdraw before swapping.
     * @param loanAmount The flash-loan principal in sellToken for leverage or buyToken for deleverage.
     * @param maxPremium The maximum flash-loan premium in the loan token.
     * @param actions The ordered adapter calls and proofs, including the transfer returning repayment funds.
     */
    struct Intent {
        Order order;
        bool leverage;
        uint256 loanAmount;
        uint256 maxPremium;
        IMerkleAdapter.Action[] actions;
    }

    /* EVENTS */

    /**
     * @notice Emitted when an exact order is armed and its sell allowance is established.
     * @param orderHash The EIP-712 order digest.
     * @param orderUid The packed order digest, executor address and expiry.
     * @param intent The committed order and execution configuration.
     */
    event Arm(bytes32 indexed orderHash, bytes orderUid, Intent intent);

    /**
     * @notice Emitted when position execution finishes and the lender has collected repayment.
     * @param orderHash The completed EIP-712 order digest.
     * @param principal The repaid flash-loan principal.
     * @param premium The paid flash-loan premium.
     */
    event FlashLoanAndCallBack(bytes32 indexed orderHash, uint256 principal, uint256 premium);

    /* FUNCTIONS */

    /**
     * @notice Returns the immutable account authorized to arm orders.
     */
    function owner() external view returns (address);

    /**
     * @notice Returns the immutable Merkle adapter holding the lending positions.
     */
    function adapter() external view returns (address);

    /**
     * @notice Returns the trusted CoW flash-loan router.
     */
    function router() external view returns (address);

    /**
     * @notice Returns the trusted Aave flash-loan pool.
     */
    function lender() external view returns (address);

    /**
     * @notice Returns the CoW settlement contract obtained from the router.
     */
    function settlement() external view returns (address);

    /**
     * @notice Returns the settlement's relayer approved to spend the exact sell amount.
     */
    function vaultRelayer() external view returns (address);

    /**
     * @notice Returns whether the latest order differs from the last completed order and has not expired.
     */
    function active() external view returns (bool);

    /**
     * @notice Returns the latest committed EIP-712 order digest, retained after completion or expiry.
     */
    function orderHash() external view returns (bytes32);

    /**
     * @notice Returns the digest of the last order completed after flash-loan repayment, or zero.
     */
    function lastCompletedOrderHash() external view returns (bytes32);

    /**
     * @notice Returns the latest packed order digest, executor address and expiry, or empty bytes before arming.
     */
    function orderUid() external view returns (bytes memory);

    /**
     * @notice Returns the latest committed intent, retained after completion or expiry.
     */
    function getIntent() external view returns (Intent memory);

    /**
     * @notice Commit an exact order after the previous order completes or expires.
     * @dev Only the idle owner may arm. Clears the previous sell allowance and approves the exact sell amount
     * only when the new order is active; expired or last-completed orders receive no allowance.
     * Downstream proof, loan and capability validation occurs during execution. There is no early cancellation.
     * Re-arming the last completed order does not reactivate its signature or prevent arming a fresh order.
     * @param newIntent The replacement order and execution configuration.
     * @return uid The packed order digest, executor address and expiry.
     */
    function arm(Intent calldata newIntent) external returns (bytes memory uid);

    /**
     * @notice Returns the ERC-1271 magic value for the active committed order, or 0xffffffff.
     * @param hash The EIP-712 order digest to validate.
     * @param signature Unused signature bytes; authorization comes from the committed order digest.
     */
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);

    /**
     * @notice Borrow the committed principal and complete one atomic CoW position adjustment.
     * @dev Only the trusted router may enter while idle. Records completion only after lender repayment.
     * The trusted Aave pool requires a successful callback and collects repayment before returning.
     * Any settlement, proof, role, health, balance or repayment failure reverts the entire transaction.
     * @param loanLender Unused router metadata; execution always uses the immutable lender.
     * @param token Unused router metadata; execution always uses the committed loan token.
     * @param amount Unused router metadata; execution always uses the committed principal.
     * @param data The router's callback data, forwarded unchanged through the lender.
     */
    function flashLoanAndCallBack(address loanLender, address token, uint256 amount, bytes calldata data) external;

    /**
     * @notice Execute settlement and lending actions, enforce balance checks and approve flash-loan repayment.
     * @dev Only the trusted lender may call during the pending loan with this executor as initiator.
     * The requested single-asset loan is fixed by flashLoanAndCallBack; callback asset and amount arrays are unused.
     * @param assets The loan assets supplied by the trusted lender.
     * @param amounts The loan principals supplied by the trusted lender.
     * @param premiums The loan premiums; the first premium must not exceed the committed ceiling.
     * @param initiator The account that initiated the loan, which must be this executor.
     * @param data The unchanged router callback data authenticated by the router during settlement.
     * @return True when the callback succeeds; the lender must still collect repayment before completion.
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata data
    ) external returns (bool);
}

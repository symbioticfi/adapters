// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

bytes32 constant IRIS_DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
bytes32 constant IRIS_QUOTE_TYPEHASH = keccak256(
    "Quote(address borrower,address solver,address receiver,address blm,address collateralToken,address debtToken,"
    "uint256 collateral,uint256 debt,uint256 fixedRate,uint256 duration,uint256 overdueRate,uint256 overduePeriod,"
    "uint256 bond,uint256 bondLltv,uint256 venueBitmap,uint256 venueId,uint256 deadline,uint256 nonce,bytes data)"
);

/**
 * @title IIris
 * @notice Interface for the solver quote schema and loan opening of the Iris fixed-rate protocol.
 */
interface IIris {
    /* STRUCTS */

    /**
     * @notice Fixed-rate loan terms signed by a solver and opened by the borrower.
     * @param borrower Owner of the opened loan.
     * @param solver Signer that posts the bond; Iris pulls the bond from this address.
     * @param receiver Recipient of the borrowed debt token.
     * @param blm Bond requirement model.
     * @param collateralToken Collateral posted by the borrower.
     * @param debtToken Borrowed token, also used for the bond.
     * @param collateral Collateral amount.
     * @param debt Borrowed amount.
     * @param fixedRate Annual fixed rate in WAD, a multiple of 1e14.
     * @param duration Loan term in seconds.
     * @param overdueRate Rate added after maturity, in WAD.
     * @param overduePeriod Grace period after maturity, in seconds.
     * @param bond Debt-token bond posted by the solver.
     * @param bondLltv Bond drawdown that allows distress liquidation, in WAD.
     * @param venueBitmap Venues the borrower allows.
     * @param venueId Venue index the loan opens on.
     * @param deadline Last timestamp at which the quote can be taken.
     * @param nonce Solver-owned nonce consumed on take.
     * @param data Venue market data.
     */
    struct Quote {
        address borrower;
        address solver;
        address receiver;
        address blm;
        address collateralToken;
        address debtToken;
        uint256 collateral;
        uint256 debt;
        uint256 fixedRate;
        uint256 duration;
        uint256 overdueRate;
        uint256 overduePeriod;
        uint256 bond;
        uint256 bondLltv;
        uint256 venueBitmap;
        uint256 venueId;
        uint256 deadline;
        uint256 nonce;
        bytes data;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns the EIP-712 domain separator for quotes.
     * @return separator keccak256(abi.encode(IRIS_DOMAIN_TYPEHASH, block.chainid, address(this))).
     */
    // forge-lint: disable-next-item(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32 separator);

    /**
     * @notice Returns whether a solver nonce has been taken.
     * @param solver Solver whose nonce is checked.
     * @param nonce Nonce to check.
     * @return used Whether the nonce can no longer be taken.
     */
    function isQuoteNonceUsed(address solver, uint256 nonce) external view returns (bool used);

    /**
     * @notice Opens a loan from a solver-signed quote and pulls the solver's bond.
     * @param quote Signed loan terms.
     * @param signature Solver signature, checked by ECDSA or ERC-1271.
     * @return pod Per-loan position contract.
     */
    function take(Quote calldata quote, bytes calldata signature) external returns (address pod);

    /**
     * @notice Returns an account's claimable balance of a token, credited when its loans settle.
     * @param token Token credited.
     * @param account Account credited.
     * @return amount Claimable amount.
     */
    function claimable(address token, address account) external view returns (uint256 amount);

    /**
     * @notice Transfers part of a claimable balance.
     * @param token Token to claim.
     * @param amount Amount to claim.
     * @param onBehalf Account whose balance is claimed; the caller must be it or authorized by it.
     * @param receiver Recipient of the tokens.
     */
    function claim(address token, uint256 amount, address onBehalf, address receiver) external;

    /**
     * @notice Withdraws bond above the loan's requirement; the caller must be the solver or authorized by it.
     * @param pod Loan whose bond is withdrawn.
     * @param amount Amount to withdraw.
     * @param receiver Recipient of the debt token.
     */
    function withdrawBond(address pod, uint256 amount, address receiver) external;
}

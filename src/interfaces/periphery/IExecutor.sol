// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMerkleAdapter} from "../IMerkleAdapter.sol";

/**
 * @title IExecutor
 * @notice Interface for preparing exact liquidity through Merkle leaves before a Liquid Lane swap or 3F push mint.
 */
interface IExecutor {
    /* ERRORS */

    /**
     * @notice Raised when available sources cannot cover the operation while retaining reserved idle assets.
     */
    error InsufficientLiquidity();

    /**
     * @notice Raised when an action has no proof in the adapter's accepted root.
     */
    error InvalidActionProof();

    /**
     * @notice Raised when the operation does not belong to the supplied adapter.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when an amount offset overlaps the selector, exceeds calldata, or is not entirely wildcard-masked.
     */
    error InvalidAmountOffset();

    /**
     * @notice Raised when a liquidity query does not return exactly one ABI-encoded uint256.
     */
    error InvalidLiquidityResult();

    /**
     * @notice Raised when the final action is not a supported, nonzero-funded action.
     */
    error InvalidOperation();

    /**
     * @notice Raised when a liquidity leaf does not increase the adapter balance by the requested amount.
     */
    error LiquidityMismatch();

    /**
     * @notice Raised when the final batch does not spend exactly the amount required by its final action.
     */
    error OperationBalanceMismatch();

    /**
     * @notice Raised when the operation's asset or live funding requirement changes during liquidity preparation.
     */
    error OperationChanged();

    /* STRUCTS */

    /**
     * @notice A query of available liquidity paired with its Merkle-authorized withdrawal or borrow.
     * @dev The query must return asset units available to the adapter. It runs as a STATICCALL from Executor;
     * encode any account argument explicitly. Exactly 32 zero-mask bytes at amountOffset are replaced
     * with min(remaining shortfall, available liquidity); all other calldata bytes remain unchanged.
     * @param liquidityTarget Contract queried for available liquidity.
     * @param liquidityData Complete query calldata.
     * @param action Normal Merkle leaf executed by the adapter to obtain funds.
     * @param amountOffset Byte offset from the start of action.data to its uint256 amount word.
     */
    struct LiquidityStep {
        address liquidityTarget;
        bytes liquidityData;
        IMerkleAdapter.Action action;
        uint256 amountOffset;
    }

    /* EVENTS */

    /**
     * @notice Emitted when a liquidity leaf supplies the exact requested amount.
     */
    event PrepareLiquidity(address indexed adapter, address indexed asset, uint256 indexed index, uint256 amount);

    /**
     * @notice Emitted when liquidity preparation and the final action finish atomically.
     */
    event Execute(address indexed adapter, address indexed actionContract, address indexed asset, uint256 amount);

    /* FUNCTIONS */

    /**
     * @notice Returns the funding asset and current amount for a supported action.
     * @dev Supports LiquidLaneConnector.swap(Swap) and ThreeFCapability.mintRequest(address,uint128,uint128,uint256).
     * The 3F amount comes from the Request's live authorization for the adapter, not its maximum argument.
     * @param adapter Merkle adapter that will execute the operation.
     * @param operation Final action call.
     * @return asset Funding token.
     * @return amount Required funding in token base units.
     */
    function getRequiredLiquidity(address adapter, IMerkleAdapter.Action calldata operation)
        external
        view
        returns (address asset, uint256 amount);

    /**
     * @notice Returns the token balance available after protecting the adapter's pending and deallocation reserves.
     * @param adapter Merkle adapter holding the tokens.
     * @param asset Token being spent.
     * @return amount Spendable token balance.
     */
    function availableBalance(address adapter, address asset) external view returns (uint256 amount);

    /**
     * @notice Obtains only missing liquidity, then executes the final batch, reverting every effect on mismatch.
     * @dev The caller must hold every supplied action's leaf role. All proofs, caller roles, and amount masks
     * are checked before dispatch. The adapter checks the Executor's role for each executed leaf. The last
     * action must call LiquidLaneConnector or the adapter's installed ThreeFCapability; earlier final
     * actions can approve the connector or the 3F request to spend the adapter's tokens.
     * Unneeded liquidity steps are skipped. Each adapter.manage call also enforces the adapter's idle reserve,
     * including intermediate steps.
     * @param adapter Merkle adapter to manage.
     * @param liquidity Ordered withdrawal/borrow candidates.
     * @param actions Final batch ending with one supported action call.
     * @return results Return data from the final managed batch.
     */
    function execute(address adapter, LiquidityStep[] calldata liquidity, IMerkleAdapter.Action[] calldata actions)
        external
        returns (bytes[] memory results);
}

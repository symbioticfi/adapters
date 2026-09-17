// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMerkleAdapter} from "../IMerkleAdapter.sol";

/**
 * @title IExecutor
 * @notice Interface for owner-configured Merkle execution plans triggered by one selected caller.
 */
interface IExecutor {
    /* ERRORS */

    /**
     * @notice Raised when available sources cannot cover the operation while retaining reserved idle assets.
     */
    error InsufficientLiquidity();

    /**
     * @notice Raised when the operation does not belong to the supplied adapter.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when an amount offset overlaps the selector, exceeds calldata, or is not entirely wildcard-masked.
     */
    error InvalidAmountOffset();

    /**
     * @notice Raised when execution is attempted by anyone other than the configured caller.
     */
    error InvalidCaller();

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
     * @notice Emitted when the owner selects or disables the caller.
     * @param caller New authorized caller; zero disables execution.
     */
    event SetCaller(address indexed caller);

    /**
     * @notice Emitted when the owner replaces an adapter's complete execution plan.
     * @param adapter Merkle adapter whose plan is replaced.
     * @param liquidity Ordered withdrawal or borrow candidates.
     * @param actions Final managed batch, including its exact calldata, masks, and proofs.
     */
    event SetActions(address indexed adapter, LiquidityStep[] liquidity, IMerkleAdapter.Action[] actions);

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
     * @notice Returns the sole account permitted to trigger stored execution plans.
     * @return authorizedCaller Authorized caller; zero disables execution.
     */
    function caller() external view returns (address authorizedCaller);

    /**
     * @notice Selects the sole account permitted to execute stored plans.
     * @dev Only the owner may call. Zero disables execution without clearing any plans.
     * The owner has no implicit execution permission and must also be selected to execute.
     * @param newCaller New caller address.
     */
    function setCaller(address newCaller) external;

    /**
     * @notice Replaces the complete liquidity and final-action plan for one adapter.
     * @dev Only the owner may call. Configuration grants no Merkle permissions: the adapter still
     * validates each executed proof and the Executor's leaf role. Empty final actions disable this
     * adapter's plan. The owner must update stored calldata or proofs when operation parameters,
     * deadlines, or the accepted Merkle root change. Configuration cannot change during execution.
     * @param adapter Merkle adapter that will execute this plan.
     * @param liquidity Ordered withdrawal or borrow candidates and liquidity queries.
     * @param actions Complete final batch ending with a supported Liquid Lane swap or 3F mint.
     */
    function setActions(address adapter, LiquidityStep[] calldata liquidity, IMerkleAdapter.Action[] calldata actions)
        external;

    /**
     * @notice Returns an adapter's stored liquidity steps and final actions.
     * @dev Returns empty arrays when no plan has been configured.
     * @param adapter Adapter whose plan is requested.
     * @return liquidity Stored withdrawal or borrow candidates.
     * @return actions Stored final managed batch.
     */
    function getActions(address adapter)
        external
        view
        returns (LiquidityStep[] memory liquidity, IMerkleAdapter.Action[] memory actions);

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
     * @notice Executes the owner's stored plan, obtaining missing liquidity and reverting every effect on mismatch.
     * @dev Only the configured caller may execute; the caller supplies no queries, actions, calldata, masks,
     * or proofs and needs no adapter leaf roles. The adapter checks every executed proof and the Executor's
     * roles. Liquidity amount words must be wildcard-masked and are patched only in memory, preserving the
     * stored templates. The last action must call LiquidLaneConnector or the adapter's ThreeFCapability;
     * earlier final actions can approve the connector or 3F request. Unneeded liquidity steps are skipped.
     * Each adapter.manage call enforces its idle reserve, including intermediate steps.
     * @param adapter Adapter whose stored plan to execute.
     * @return results Return data from the final managed batch.
     */
    function execute(address adapter) external returns (bytes[] memory results);
}

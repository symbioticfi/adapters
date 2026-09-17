// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMerkleAdapter} from "../IMerkleAdapter.sol";

/**
 * @title IExecutor
 * @notice Interface for owner-configured liquidity queries and ordered leaves bound to one Merkle adapter.
 */
interface IExecutor {
    /* ERRORS */

    /**
     * @notice Raised when available sources cannot cover the operation while retaining reserved idle assets.
     */
    error InsufficientLiquidity();

    /**
     * @notice Raised when a supplied call does not match its configured leaf.
     */
    error InvalidAction();

    /**
     * @notice Raised when a liquidity source is configured after a final-batch entry.
     */
    error InvalidActionOrder();

    /**
     * @notice Raised when the supplied calls do not match the configured action count.
     */
    error InvalidActionsLength();

    /**
     * @notice Raised when the operation does not belong to the supplied adapter.
     */
    error InvalidAdapter();

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
     * @notice An owner-configured Merkle leaf with an optional liquidity query.
     * @dev The query must return asset units available to the adapter. It runs as a STATICCALL from Executor;
     * encode any account argument explicitly. Funding entries must come first, in source priority order.
     * Zero-target entries follow them and form the final managed batch, ending in a supported operation.
     * @param liquidityTarget Contract queried for available liquidity, or zero for a final-batch entry.
     * @param liquidityCalldata Complete query calldata; unused when liquidityTarget is zero.
     * @param leaf Canonical masked Merkle leaf for the permitted call.
     */
    struct Action {
        address liquidityTarget;
        bytes liquidityCalldata;
        bytes32 leaf;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the owner selects or disables the caller.
     * @param caller New authorized caller; zero disables execution.
     */
    event SetCaller(address indexed caller);

    /**
     * @notice Emitted when the owner replaces the configured liquidity queries and ordered leaves.
     * @param actions Ordered liquidity sources and final-batch leaves.
     */
    event SetActions(Action[] actions);

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
     * @notice Returns the adapter permanently bound to this Executor at construction.
     * @return boundAdapter Adapter whose funds and Merkle permissions are used.
     */
    function adapter() external view returns (address boundAdapter);

    /**
     * @notice Returns the sole account permitted to execute operations.
     * @return authorizedCaller Authorized caller; zero disables execution.
     */
    function caller() external view returns (address authorizedCaller);

    /**
     * @notice Selects the sole account permitted to execute operations.
     * @dev Only the owner may call. Zero disables execution without clearing the configured liquidity actions.
     * The owner has no implicit execution permission and must also be selected to execute.
     * @param newCaller New caller address.
     */
    function setCaller(address newCaller) external;

    /**
     * @notice Replaces the ordered liquidity sources and final-batch leaves.
     * @dev Only the owner may call. Configuration grants no Merkle permissions: the adapter still
     * validates each executed proof and the Executor's leaf role. Empty actions disable execution.
     * Funding entries have a nonzero liquidityTarget and precede all final-batch entries, which have
     * a zero target. The caller supplies calldata, masks, and proofs matching these leaves at execution.
     * Native-currency value is caller-supplied; its zero/nonzero byte must match the configured leaf.
     * Configuration cannot change during execution.
     * @param actions Ordered liquidity sources and final-batch leaves.
     */
    function setActions(Action[] calldata actions) external;

    /**
     * @notice Returns the configured liquidity queries and Merkle leaves in execution order.
     * @return actions Stored configuration; empty when execution is disabled.
     */
    function getActions() external view returns (Action[] memory actions);

    /**
     * @notice Returns the funding asset and current amount for a supported action.
     * @dev Supports LiquidLaneConnector.swap(Swap) and ThreeFCapability.mintRequest(address,uint128,uint128,uint256).
     * The 3F amount comes from the Request's live authorization for the adapter, not its maximum argument.
     * Both supported operations require zero native-currency value.
     * @param operation Final action call.
     * @return asset Funding token.
     * @return amount Required funding in token base units.
     */
    function getRequiredLiquidity(IMerkleAdapter.Action calldata operation)
        external
        view
        returns (address asset, uint256 amount);

    /**
     * @notice Returns the token balance available after protecting the adapter's pending and deallocation reserves.
     * @param asset Token being spent.
     * @return amount Spendable token balance.
     */
    function availableBalance(address asset) external view returns (uint256 amount);

    /**
     * @notice Obtains missing liquidity from configured sources and executes a supported final operation atomically.
     * @dev Only the configured caller may execute and needs no adapter leaf roles. The caller supplies one
     * call per configured action in the same order. Every call must match its configured leaf;
     * liquidity queries always come from owner configuration. Calls execute exactly as supplied. Each
     * source must provide min(available liquidity, remaining funding needed), consuming its full capacity
     * before proceeding unless the remaining need is smaller. Zero-capacity and unneeded sources are
     * skipped. Zero-target entries form the final batch, whose leaves are also fixed by setActions.
     * Its last action must call LiquidLaneConnector or the bound adapter's ThreeFCapability. Earlier final actions can approve
     * the connector or 3F request. The adapter checks every executed proof and Executor role, and each
     * manage call enforces its idle reserve, including intermediate steps. Any mismatch rolls back all effects.
     * @param actions Merkle actions with encoded amounts and proofs, matching every configured leaf in order.
     * @return results Return data from the final managed batch.
     */
    function execute(IMerkleAdapter.Action[] calldata actions) external returns (bytes[] memory results);
}

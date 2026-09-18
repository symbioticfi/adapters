// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapter} from "../IMerkleAdapter.sol";

/**
 * @title IExecutor
 * @notice Interface for ordered, Merkle-authorized liquidity preparation in one adapter.
 */
interface IExecutor {
    /* ERRORS */

    /**
     * @notice Raised when the token rejects an adapter approval.
     */
    error ApprovalFailed();

    /**
     * @notice Raised when sources cannot fund the operation while retaining reserved assets.
     */
    error InsufficientLiquidity();

    /**
     * @notice Raised when a call does not match its configured leaf.
     */
    error InvalidAction();

    /**
     * @notice Raised when supplied funding calls do not match the configured count.
     */
    error InvalidActionsLength();

    /**
     * @notice Raised when execution is attempted by anyone other than the selected caller.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a liquidity query does not return exactly one ABI-encoded uint256.
     */
    error InvalidLiquidityResult();

    /**
     * @notice Raised when a source does not supply exactly the required amount.
     */
    error LiquidityMismatch();

    /**
     * @notice Raised when the operation does not spend exactly its prepared funding amount.
     */
    error OperationBalanceMismatch();

    /* STRUCTS */

    /**
     * @notice An ordered funding leaf and its available-liquidity query.
     * @param liquidityTarget Contract queried by STATICCALL from the executor.
     * @param liquidityCalldata Complete query returning available funding-token units; encode the adapter explicitly.
     * @param leaf Canonical masked Merkle leaf for the funding call.
     */
    struct Action {
        address liquidityTarget;
        bytes liquidityCalldata;
        bytes32 leaf;
    }

    /**
     * @notice Merkle authorization for calldata constructed by the executor.
     * @param dataMask Calldata mask committed by the accepted leaf.
     * @param proof Proof under the adapter's current root.
     */
    struct Permission {
        bytes dataMask;
        bytes32[] proof;
    }

    /**
     * @notice Current funding calls and proofs for a typed operation.
     * @param actions One call per configured source, in the same order, including skipped sources.
     * @param approval Authorization for funding-token approve(target,amount); mask the amount to allow zero resets.
     * @param operation Authorization for the specialized executor's constructed swap or mint call.
     */
    struct Execution {
        IMerkleAdapter.Action[] actions;
        Permission approval;
        Permission operation;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the owner selects the caller; zero disables execution.
     */
    event SetCaller(address indexed caller);
    /**
     * @notice Emitted when the owner replaces the sources and exact approval and operation permissions.
     */
    event SetActions(Action[] actions, bytes32 approvalLeaf, bytes32 operationLeaf);
    /**
     * @notice Emitted when a source supplies the exact requested amount to the adapter.
     */
    event PrepareLiquidity(address indexed adapter, address indexed asset, uint256 indexed index, uint256 amount);

    /* FUNCTIONS */

    /**
     * @notice Returns the adapter permanently bound to this executor.
     */
    function adapter() external view returns (address);
    /**
     * @notice Returns the sole account permitted to submit an operation.
     */
    function caller() external view returns (address);
    /**
     * @notice Returns a configured source by index; reverts when out of bounds.
     */
    function actions(uint256 index)
        external
        view
        returns (address liquidityTarget, bytes memory liquidityCalldata, bytes32 leaf);
    /**
     * @notice Returns the number of funding sources.
     */
    function actionsLength() external view returns (uint256);
    /**
     * @notice Returns the configured funding approval leaf.
     */
    function approvalLeaf() external view returns (bytes32);
    /**
     * @notice Returns the configured specialized operation leaf.
     */
    function operationLeaf() external view returns (bytes32);
    /**
     * @notice Selects or disables the execution caller.
     * @dev Owner-only; cannot change during execution. Ownership alone does not grant execution permission.
     */
    function setCaller(address newCaller) external;
    /**
     * @notice Replaces the funding order and approval and operation permissions.
     * @dev Owner-only; cannot change during execution. Empty sources allow idle-only funding.
     * Each executed call still requires the executor's adapter role and a current Merkle proof.
     * Sources supply min(live shortfall, queried liquidity), with reserved adapter assets protected.
     * Approval runs from the adapter, resetting a nonzero allowance before approving the exact amount.
     * No calldata is stored for the operation: subclasses construct it from their typed arguments.
     */
    function setActions(Action[] calldata newActions, bytes32 newApprovalLeaf, bytes32 newOperationLeaf) external;
    /**
     * @notice Returns the token balance available after protecting the adapter's vault-asset reserves.
     */
    function availableBalance(address asset) external view returns (uint256);
}

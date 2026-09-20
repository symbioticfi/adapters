// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IRecipeExecutor
 * @notice Interface for owner-configured leaf actions with dependent amounts and attached conditions.
 */
interface IRecipeExecutor {
    /* ERRORS */

    /**
     * @notice Raised when a token rejects an approval.
     */
    error ApprovalFailed();
    /**
     * @notice Raised when a configured comparison fails.
     */
    error CheckFailed();
    /**
     * @notice Raised when a final action differs from its stored leaf or carries native value.
     */
    error InvalidAction();
    /**
     * @notice Raised when a selector differs or bindings overlap or extend outside their calldata.
     */
    error InvalidCall();
    /**
     * @notice Raised when someone other than the selected caller executes the recipe.
     */
    error InvalidCaller();
    /**
     * @notice Raised when an operand refers to a result that has not been produced yet.
     */
    error InvalidReference();
    /**
     * @notice Raised when runtime/action counts differ or managed actions use noncanonical encoding.
     */
    error InvalidRuntime();

    /* ENUMS */

    /**
     * @notice Adapter-managed leaves, leaf-backed approvals, or a trusted local policy call.
     */
    enum Kind {
        Manage,
        Approve,
        Invoke
    }

    /**
     * @notice Calculation producing one uint256 result.
     * @dev Arithmetic is checked except SaturatingSubtract, which floors at zero; MulDiv rounds down.
     */
    enum Operation {
        Read,
        Add,
        Subtract,
        SaturatingSubtract,
        Minimum,
        MulDiv
    }

    /**
     * @notice Literal uint256, runtime input, or an already populated global result.
     */
    enum Source {
        Literal,
        Input,
        Result
    }

    /**
     * @notice Comparison of two resolved operands.
     */
    enum Comparison {
        Equal,
        GreaterOrEqual,
        LessOrEqual
    }

    /**
     * @notice Post-action value, or unsigned increase/decrease against a pre-action snapshot.
     */
    enum ObservationKind {
        After,
        Increase,
        Decrease
    }

    /* STRUCTS */

    /**
     * @notice One numeric operand.
     * @param source Operand source.
     * @param value Literal uint256, input index, or global result index according to source.
     */
    struct Value {
        Source source;
        uint256 value;
    }

    /**
     * @notice Replacement of a complete calldata word with a resolved operand.
     * @param offset Byte offset relative to the individual call, starting after its selector.
     * @param value Value to insert.
     * @dev Bindings must be sorted and nonoverlapping. They cannot change calldata length.
     */
    struct Binding {
        uint256 offset;
        Value value;
    }

    /**
     * @notice Static query returning one complete uint256 word.
     * @param target Contract queried from this executor.
     * @param data Fixed query template.
     * @param bindings Values to insert into the query.
     * @param offset Byte offset of the returned word; alignment is not required.
     */
    struct Query {
        address target;
        bytes data;
        Binding[] bindings;
        uint256 offset;
    }

    /**
     * @notice Calculation evaluated in order before or after an action.
     * @param operation Calculation to perform.
     * @param a First arithmetic operand; unused by Read.
     * @param b Second arithmetic operand; unused by Read.
     * @param c MulDiv denominator; otherwise unused.
     * @param data Read: abi.encode(Query). Empty for arithmetic.
     */
    struct Expression {
        Operation operation;
        Value a;
        Value b;
        Value c;
        bytes data;
    }

    /**
     * @notice Condition attached to an action; it produces no result slot.
     * @param a Left operand.
     * @param b Right operand.
     * @param comparison Required comparison.
     */
    struct Check {
        Value a;
        Value b;
        Comparison comparison;
    }

    /**
     * @notice Measurement across one action, producing one global result.
     * @param query Static query whose bindings are resolved before the action.
     * @param kind After value or checked unsigned delta; a delta in the opposite direction reverts.
     * @dev All observation queries are frozen before the action. Their bindings can refer only to
     * results available then, never another observation or after-expression of the same action.
     */
    struct Observation {
        Query query;
        ObservationKind kind;
    }

    /**
     * @notice Merkle authorization for an approval constructed by the executor.
     * @param dataMask Calldata mask committed by the approved leaf.
     * @param proof Proof under the adapter's current root.
     */
    struct Permission {
        bytes dataMask;
        bytes32[] proof;
    }

    /**
     * @notice One configured action, its calculations and its conditions.
     * @param kind Action execution context.
     * @param amount Manage: nonzero execution guard. Approve: allowance amount. Unused by Invoke.
     * @param data Manage: abi.encode(bytes32[] orderedLeaves, Binding[][] bindings), one list per action.
     * Approve: abi.encode(address token, address spender, bytes32 leaf).
     * Invoke: abi.encode(address trustedTarget, bytes4 selector, Binding[] bindings).
     * @param beforeExpressions Ordered calculations evaluated before the action.
     * @param checksBefore Conditions checked after before-expressions and before observation snapshots.
     * @param observations Queries frozen before the action and evaluated after it, in order.
     * @param afterExpressions Ordered calculations evaluated after observations.
     * @param checksAfter Conditions checked after after-expressions.
     * @dev Global results append in this order: before expressions, observations, after expressions.
     * Writes and checks do not allocate results. Manage guard zero skips only the managed call;
     * all calculations, observations and conditions still execute.
     */
    struct Step {
        Kind kind;
        Value amount;
        bytes data;
        Expression[] beforeExpressions;
        Check[] checksBefore;
        Observation[] observations;
        Expression[] afterExpressions;
        Check[] checksAfter;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the owner selects the sole execution caller; zero disables execution.
     */
    event SetCaller(address indexed caller);
    /**
     * @notice Emitted with all typed steps when the owner replaces the recipe.
     */
    event SetRecipe(Step[] recipe);
    /**
     * @notice Emitted after every action and condition succeeds.
     */
    event Execute();

    /* FUNCTIONS */

    /**
     * @notice Returns the adapter permanently bound to this executor.
     */
    function adapter() external view returns (address);
    /**
     * @notice Returns the sole caller permitted to execute.
     */
    function caller() external view returns (address);
    /**
     * @notice Returns abi.encode(Step) for the given action index.
     */
    function steps(uint256 index) external view returns (bytes memory);
    /**
     * @notice Selects the execution caller; owner-only and unavailable during execution.
     */
    function setCaller(address newCaller) external;
    /**
     * @notice Replaces the stored recipe; owner-only and unavailable during execution.
     * @param newRecipe Ordered actions, bindings, calculations and conditions.
     * @dev The owner must configure appropriate input bounds, economic checks and cumulative limits.
     * Empty recipes perform no actions. Configuration updates apply to pending executions too.
     */
    function setRecipe(Step[] calldata newRecipe) external;
    /**
     * @notice Executes the stored actions and conditions atomically.
     * @param inputs Runtime uint256 values constrained by the configured conditions.
     * @param runtime One entry per action: Manage decodes IMerkleAdapter.Action[], Approve decodes
     * Permission, Invoke receives complete calldata. Manage with guard zero skips runtime decoding.
     * @return values Global results from expressions and observations, in execution order.
     * @dev Manage accepts canonical abi.encode(actions), applies bindings to each action.data, checks
     * final leaves and calls adapter.manage. Approved leaves must pin selectors, accounts, assets and
     * nested ABI headers/lengths. Invoke trusts its fixed target's policy and signature validation;
     * it is not adapter Merkle authorization. Only fixed top-level ABI words are safe to bind there
     * unless the target itself validates nested layouts. Signatures must match final bound calldata.
     * Approve handles allowance resets and optional ERC20 return values through adapter leaves.
     * All result references must already be populated. Queries use STATICCALL from this executor;
     * state-changing calls never delegatecall or send native value. All failures roll back every action.
     */
    function execute(uint256[] calldata inputs, bytes[] calldata runtime) external returns (uint256[] memory values);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IRecipeExecutor
 * @notice Interface for curator-committed programs of approved actions and state conditions.
 */
interface IRecipeExecutor {
    /* ERRORS */

    /**
     * @notice Raised when a token returns false for an approval.
     */
    error ApprovalFailed();

    /**
     * @notice Raised when a required comparison fails.
     */
    error CheckFailed();

    /**
     * @notice Raised when the final action differs from its configured leaf or carries native value.
     */
    error InvalidAction();

    /**
     * @notice Raised when bindings overlap, replace the selector, or extend outside calldata.
     */
    error InvalidCall();

    /**
     * @notice Raised when the selected operator is not the caller.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the recipe differs from the curator's current commitment.
     */
    error InvalidRecipe();

    /**
     * @notice Raised when a result reference is not an earlier numerical instruction.
     */
    error InvalidReference();

    /**
     * @notice Raised when runtime or managed-action counts differ from the program.
     */
    error InvalidRuntime();

    /* ENUMS */

    /**
     * @notice Numerical instructions followed by assertions and effects.
     * @dev Read through MulDiv produce numbers. Equal through Call cannot be referenced.
     * Sub is checked; SaturatingSub floors at zero; MulDiv rounds down.
     */
    enum Operation {
        Read,
        Add,
        Sub,
        SaturatingSub,
        Min,
        Max,
        MulDiv,
        Equal,
        LessOrEqual,
        Manage,
        Approve,
        Call
    }

    /**
     * @notice Literal uint256, execution input, or earlier numerical instruction result.
     */
    enum Source {
        Literal,
        Input,
        Result
    }

    /* STRUCTS */

    /**
     * @notice One numerical operand.
     * @param source Meaning of value.
     * @param value Literal, input index, or absolute instruction index.
     */
    struct Value {
        Source source;
        uint256 value;
    }

    /**
     * @notice Replacement of a full calldata word, preserving selector and length.
     * @param offset Byte offset in the individual call; at least four.
     * @param value Numerical value to insert.
     * @dev Bindings must be sorted, nonoverlapping, and fully in bounds.
     */
    struct Binding {
        uint256 offset;
        Value value;
    }

    /**
     * @notice One chronological instruction with an operation-specific ABI payload.
     * @param operation Instruction to execute.
     * @param data Read: abi.encode(uint256 queryIndex).
     * Add/Sub/SaturatingSub/Min/Max/Equal/LessOrEqual: abi.encode(Value a, Value b).
     * MulDiv: abi.encode(Value a, Value b, Value denominator).
     * Manage: abi.encode(Value gate, bytes32[] orderedLeaves, Binding[][] bindings).
     * Approve: abi.encode(Value amount, address token, address spender, bytes32 leaf).
     * Call: abi.encode(address target, bytes template, Binding[] bindings).
     * @dev Manage keeps one atomic account group; zero gate skips only that group.
     * Call uses committed calldata from the executor, not account authorization or operator calldata.
     */
    struct Step {
        Operation operation;
        bytes data;
    }

    /**
     * @notice Memory-only state shared by operand resolution and calldata substitution.
     * @param inputs Immutable numerical inputs for this execution.
     * @param values Results indexed by instruction; nonnumerical entries cannot be referenced.
     * @param index Current instruction index, excluding all self and future references.
     * @param runtimeIndex Next Manage or Approve payload index.
     */
    struct Execution {
        uint256[] inputs;
        uint256[] values;
        uint256 index;
        uint256 runtimeIndex;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the owner selects an operator; zero disables execution.
     */
    event SetCaller(address indexed caller);
    /**
     * @notice Emitted when the owner replaces the commitment and publishes the complete recipe.
     */
    event SetRecipe(bytes32 indexed recipeHash, bytes[] queries, Step[] steps);
    /**
     * @notice Emitted after all calls and conditions succeed.
     */
    event Execute();

    /* FUNCTIONS */

    /**
     * @notice Returns the account permanently bound to this executor.
     */
    function account() external view returns (address);
    /**
     * @notice Returns the operator permitted to execute.
     */
    function caller() external view returns (address);
    /**
     * @notice Returns keccak256(abi.encode(queries, steps)), or zero before configuration.
     */
    function recipeHash() external view returns (bytes32);
    /**
     * @notice Returns the block containing the latest SetRecipe event, or zero before configuration.
     */
    function recipeBlock() external view returns (uint256);
    /**
     * @notice Selects the operator; owner-only and unavailable during execution.
     */
    function setCaller(address newCaller) external;
    /**
     * @notice Commits and publishes a recipe; owner-only and unavailable during execution.
     * @param queries Shared STATICCALL templates, each abi.encode(address target, bytes data,
     * Binding[] bindings, uint256 offset). Offset selects a complete return-data word in bytes;
     * alignment is not required. Each query is decoded afresh before applying its bindings.
     * @param steps Instructions in execution order.
     * @dev Stores no queries or instructions. Configuration uses two persistent slots, independent
     * of program size. An explicitly configured empty recipe is a no-op. Changes apply to pending
     * executions: previously supplied recipes fail unless their complete contents are unchanged.
     */
    function setRecipe(bytes[] calldata queries, Step[] calldata steps) external;
    /**
     * @notice Authenticates the supplied recipe and executes its instructions atomically.
     * @param queries Shared encoded queries recovered from SetRecipe or a verified cache.
     * @param steps Curator-committed instructions, authenticated together with queries.
     * @param inputs Numerical inputs constrained by the configured calls and assertions.
     * @param runtime One entry per Manage or Approve instruction, in order. Manage decodes
     * IMerkleAccount.Action[]; Approve decodes (bytes dataMask, bytes32[] proof). A zero Manage gate
     * still consumes its entry but does not decode it. Reads, arithmetic, assertions and Call need
     * no runtime entry.
     * @return values Results by instruction index; effects and assertions have unused zero slots.
     * @dev Checks caller and recipe hash before any external query or action. Only prior Read
     * through MulDiv results may be referenced. Managed actions are bound then matched against
     * their exact configured leaves; the account validates current proofs and roles; bridge push checks reserves.
     * Approval resets and optional bool return handling run through the account. Call uses a fixed
     * template and target from the executor. No native value or delegatecall is permitted.
     * Every failure rolls back the entire execution, including external policy and protocol state.
     */
    function execute(
        bytes[] calldata queries,
        Step[] calldata steps,
        uint256[] calldata inputs,
        bytes[] calldata runtime
    ) external returns (uint256[] memory values);
}

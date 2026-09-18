// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IRecipeExecutor
 * @notice Interface for curator-defined sequences of reads, authorized calls and numeric checks.
 */
interface IRecipeExecutor {
    /* ERRORS */

    /**
     * @notice Raised when a token rejects an approval.
     */
    error ApprovalFailed();

    /**
     * @notice Raised when an equality or upper-bound check fails.
     */
    error CheckFailed();

    /**
     * @notice Raised when an action differs from its configured leaf or carries native value.
     */
    error InvalidAction();

    /**
     * @notice Raised when a call targets a different selector from its configured executor entrypoint.
     */
    error InvalidCall();

    /**
     * @notice Raised when someone other than the selected caller executes the recipe.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the supplied recipe differs from the owner's current configuration.
     */
    error InvalidRecipe();

    /**
     * @notice Raised when an operand refers to its own or a later result.
     */
    error InvalidReference();

    /**
     * @notice Raised when execution data has a different length from the recipe or a managed group.
     */
    error InvalidRuntime();

    /**
     * @notice Raised when a read does not contain the requested complete 32-byte word.
     */
    error InvalidWord();

    /* ENUMS */

    /**
     * @notice Instructions evaluated sequentially, each producing one uint256 result.
     * @dev Arithmetic is checked; MulDiv rounds down. Checks and write instructions return zero.
     */
    enum Operation {
        Constant,
        Input,
        Read,
        Add,
        Subtract,
        Minimum,
        MulDiv,
        Equal,
        LessOrEqual,
        Manage,
        Approve,
        Invoke,
        Calldata
    }

    /* STRUCTS */

    /**
     * @notice One instruction and its curator-committed operands and configuration.
     * @param operation Instruction to execute.
     * @param a Constant: literal; Input: input index; Read: result byte offset; Calldata: runtime index.
     * Otherwise a prior result index (Manage uses it as a nonzero execution guard, Approve as its amount).
     * @param b Calldata: byte offset in runtime[a]; arithmetic/checks: second prior result index; otherwise unused.
     * @param c MulDiv: denominator's prior result index; otherwise unused.
     * @param data Read: abi.encode(address target, bytes query), with the adapter explicitly encoded in the query.
     * Manage: abi.encode(bytes32[] orderedLeaves). Approve: abi.encode(address token, address spender, bytes32 leaf).
     * Invoke: abi.encode(address trustedExecutor, bytes4 selector). Empty for other instructions.
     * @dev Read's STATICCALL comes from this executor. Invoke is a CALL from this executor to a trusted,
     * curator-configured typed executor which must enforce its own argument/signature policy. It is not
     * Merkle authorization for arbitrary calls. Manage/Approve execute from the adapter and require its roles.
     */
    struct Step {
        Operation operation;
        uint256 a;
        uint256 b;
        uint256 c;
        bytes data;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the owner replaces the sole execution caller; zero disables execution.
     */
    event SetCaller(address indexed caller);
    /**
     * @notice Emitted with the full recipe when the owner replaces its commitment.
     */
    event SetRecipe(bytes32 indexed recipeHash, Step[] recipe);
    /**
     * @notice Emitted after the committed recipe and every check complete successfully.
     */
    event Execute(bytes32 indexed recipeHash);

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
     * @notice Returns keccak256(abi.encode(recipe)) for the active configuration.
     */
    function recipeHash() external view returns (bytes32);
    /**
     * @notice Selects the execution caller; owner-only and unavailable during execution.
     */
    function setCaller(address newCaller) external;
    /**
     * @notice Replaces the active recipe; owner-only and unavailable during execution.
     * @dev The caller supplies this exact recipe on each execution. No per-instruction storage is required.
     * The owner must configure input bounds, economic checks and repeated-execution exposure limits.
     * Empty recipes perform no actions. Setting caller to zero disables execution.
     */
    function setRecipe(Step[] calldata recipe) external;
    /**
     * @notice Executes the current recipe atomically with the selected caller's inputs and proofs.
     * @param recipe Exact recipe committed by the owner.
     * @param inputs Runtime uint256 inputs; constrain them with recipe checks before use.
     * @param runtime One entry per step: Manage decodes IMerkleAdapter.Action[], Approve decodes
     * IExecutor.Permission, Invoke receives complete typed calldata. Other entries are normally empty.
     * Manage with a zero guard skips its group, including runtime decoding. Calldata may read a future
     * entry to constrain its actual ABI arguments; arithmetic may only reference completed results.
     * Calldata offsets must address top-level static ABI words: dynamic tails can be relocated by the caller,
     * so a fixed offset into nested/dynamic data does not authenticate that argument's decoded value.
     * @return values One result per instruction, including zero for checks and writes.
     * @dev Direct calls send no native value and never delegatecall. Invoke trusts the selected executor's
     * nested authority and policy. All managed leaves need current proofs and
     * this executor's roles. Invoked typed executors need their own roles and must select this executor
     * as their caller. Any failed operation/check rolls back all calls, including nested executors.
     */
    function execute(Step[] calldata recipe, uint256[] calldata inputs, bytes[] calldata runtime)
        external
        returns (uint256[] memory values);
}

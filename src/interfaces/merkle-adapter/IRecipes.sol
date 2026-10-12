// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @dev Operand sources: literal uint216, execution input, or earlier numerical instruction result.
 */
uint8 constant SRC_LITERAL = 0;
uint8 constant SRC_INPUT = 1;
uint8 constant SRC_RESULT = 2;

/**
 * @dev OP_READ through OP_MUL_DIV, OP_READ_IF, OP_READ_CACHED and OP_READ_WORD produce numbers;
 * other operations cannot be referenced.
 * OP_SUB is checked; OP_SATURATING_SUB floors at zero; OP_MUL_DIV checks multiplication for overflow,
 * then divides rounding down.
 */
uint8 constant OP_READ = 0;
uint8 constant OP_ADD = 1;
uint8 constant OP_SUB = 2;
uint8 constant OP_SATURATING_SUB = 3;
uint8 constant OP_MIN = 4;
uint8 constant OP_MAX = 5;
uint8 constant OP_MUL_DIV = 6;
uint8 constant OP_EQUAL = 7;
uint8 constant OP_LESS_OR_EQUAL = 8;
uint8 constant OP_MANAGE = 9;
uint8 constant OP_APPROVE = 10;
uint8 constant OP_CALL = 11;
uint8 constant OP_READ_IF = 12;
uint8 constant OP_CLEAR_APPROVAL = 13;
uint8 constant OP_READ_CACHED = 14;
uint8 constant OP_READ_WORD = 15;
uint8 constant OP_CALL_IF = 16;

/**
 * @dev Bit mask of numerical operations whose results may be referenced.
 */
uint256 constant NUMERICAL_OPERATIONS = (uint256(1) << (OP_MUL_DIV + 1)) - 1 | uint256(1) << OP_READ_IF | uint256(1)
    << OP_READ_CACHED | uint256(1) << OP_READ_WORD;

/**
 * @title IRecipes
 * @notice Interface for the shared instruction schema of committed executor and account capability recipes.
 * @dev Each step is bytes.concat(bytes1(operation), abi.encode(...)) with these payloads:
 * OP_READ: abi.encode(uint256 queryIndex).
 * OP_ADD/OP_SUB/OP_SATURATING_SUB/OP_MIN/OP_MAX/OP_EQUAL/OP_LESS_OR_EQUAL: abi.encode(uint256 a, uint256 b).
 * OP_MUL_DIV: abi.encode(uint256 a, uint256 b, uint256 denominator).
 * OP_MANAGE: abi.encode(uint256 gate, bytes32[] orderedLeaves, uint256[][] bindings).
 * OP_APPROVE: abi.encode(uint256 amount, address token, address spender, bytes32 leaf).
 * OP_CALL: abi.encode(address target, bytes template, uint256[] bindings).
 * OP_READ_IF: abi.encode(uint256 gate, uint256 queryIndex, uint256 fallbackValue).
 * OP_CLEAR_APPROVAL: abi.encode(address token, address spender, bytes32 leaf).
 * OP_READ_CACHED: abi.encode(uint256 queryIndex).
 * OP_READ_WORD: abi.encode(uint256 producerIndex, uint256 offset).
 * OP_CALL_IF: abi.encode(uint256 gate, address target, bytes template, uint256[] bindings).
 * Numerical operands occupy the lowest 28 bytes: (uint256(src) << 216) | value, where src is uint8
 * and the literal or index must fit uint216. Inputs and results retain all 256 bits.
 * Each binding packs a uint32 byte offset above the operand: (uint256(offset) << 224) | srcAndValue.
 * Offsets are at least four; bindings must be sorted, nonoverlapping, and fully in bounds for a 32-byte write.
 * Operand resolution ignores the highest four bytes, which contain the offset in bindings and are zero
 * in standalone operands produced by builders. OP_MANAGE keeps one atomic account group; a zero gate skips only that group.
 * OP_READ_IF resolves gate first. A zero gate resolves only fallbackValue and skips the query; a nonzero gate
 * executes the query without resolving fallbackValue. Its result retains all 256 bits in either branch.
 * OP_READ_CACHED executes a fresh query, returns its configured word and retains the complete return data.
 * OP_READ_WORD extracts a complete word at the byte offset from the latest OP_READ_CACHED instruction.
 * producerIndex is an unpacked instruction index and must reference an earlier cached read. Another cached
 * read replaces that snapshot; ordinary reads and calls do not. Previously extracted numerical values remain
 * usable. Cached words are immutable snapshots; use a fresh cached read to observe subsequent state changes.
 * OP_CLEAR_APPROVAL skips an already-zero allowance, including its action proof and role checks.
 * OP_CALL uses a committed template from the current execution address. OP_MANAGE, OP_APPROVE and
 * OP_CLEAR_APPROVAL are executor-only.
 * OP_CALL_IF resolves gate first. A zero gate skips decoding the remaining call payload and resolving
 * its bindings; a nonzero gate performs the same committed call as OP_CALL. It produces no numerical
 * result and consumes no runtime payload. Both call operations preserve the current execution address
 * as the target's caller.
 */
interface IRecipes {
    /* ERRORS */

    /**
     * @notice Raised when a required comparison fails.
     */
    error CheckFailed();

    /**
     * @notice Raised when bindings overlap, replace the selector, or extend outside calldata.
     */
    error InvalidCall();

    /**
     * @notice Raised when an instruction is not supported by this execution context.
     */
    error InvalidOperation();

    /**
     * @notice Raised when query or cached return data contains less than one complete word at the configured offset.
     */
    error InvalidQuery();

    /**
     * @notice Raised when an operand does not reference an earlier numerical instruction, or a cached read reference
     * is unknown, self, future or replaced.
     */
    error InvalidReference();

    /**
     * @notice Raised when runtime or managed-action counts differ from the program.
     */
    error InvalidRuntime();

    /* STRUCTS */

    /**
     * @notice Memory-only state shared by operand resolution and calldata substitution.
     * @param values Results indexed by instruction; nonnumerical entries cannot be referenced.
     * @param index Current instruction index, excluding all self and future references.
     * @param readData Complete return data from the latest cached read in this execution.
     * @param readIndex Cached producer instruction index plus one; zero means no cached read.
     */
    struct State {
        uint256[] values;
        uint256 index;
        bytes readData;
        uint256 readIndex;
    }
}

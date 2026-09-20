// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IGuardedCallsCapability
 * @notice Interface for Merkle-approved calls guarded by unsigned state observations.
 */
interface IGuardedCallsCapability {
    /* ERRORS */

    /**
     * @notice Raised when an observed value fails its approved comparison.
     */
    error CheckFailed();

    /**
     * @notice Raised when a capability operation is not called by the adapter itself.
     */
    error InvalidCaller();

    /* STRUCTS */

    /**
     * @notice Observation taken before calls, after calls, or as a checked unsigned delta.
     */
    enum Observation {
        Before,
        After,
        Increase,
        Decrease
    }

    /**
     * @notice Comparison between the observation and its bound.
     */
    enum Comparison {
        Equal,
        GreaterOrEqual,
        LessOrEqual
    }

    /**
     * @notice Bound read from a constant or an approved call's calldata.
     */
    enum Source {
        Constant,
        Calldata
    }

    /**
     * @notice Normal external call, or static query when used in a Check.
     */
    struct Call {
        address target;
        bytes data;
    }

    /**
     * @notice Immutable comparison bound from the approved calldata.
     * @param source Constant or Calldata.
     * @param value Literal value or zero-based index into calls.
     * @param offset Byte offset of a uint256 word in calls[value].data for Calldata; otherwise unused.
     */
    struct Bound {
        Source source;
        uint256 value;
        uint256 offset;
    }

    /**
     * @notice One state condition enforced atomically with the approved calls.
     * @param query STATICCALL target and calldata; must return a complete uint256 word at offset.
     * @param offset Byte offset of the observed uint256 word in the query's return data.
     * @param observation When to observe; Increase and Decrease revert if the delta has the opposite sign.
     * @param comparison Comparison to apply.
     * @param bound Merkle-committed literal bound or an amount from an approved call.
     */
    struct Check {
        Call query;
        uint256 offset;
        Observation observation;
        Comparison comparison;
        Bound bound;
    }

    /* FUNCTIONS */

    /**
     * @notice Executes approved calls and reverts the entire sequence if any condition fails.
     * @dev Requires an adapter self-call through manage. Merkle leaves must pin targets, selectors,
     * ABI layouts, complete checks and queries, and bound sources/indices/offsets. Only intended call
     * amounts should be masked. Calls use CALL with no native value; queries use STATICCALL.
     * Delta baselines are captured before writes. Before checks run before any calls;
     * other checks run after the complete sequence. Empty checks intentionally mean unguarded calls.
     * No storage, setters, arithmetic program, ABI substitution or per-call intermediate checks are used.
     * Literal thresholds belong to the leaf; changing one requires a new accepted root and leaf role.
     * @param calls Ordered protocol calls made by the adapter.
     * @param checks Approved conditions.
     * @return results Unmodified return data for each call, in order.
     */
    function execute(Call[] calldata calls, Check[] calldata checks) external returns (bytes[] memory results);
}

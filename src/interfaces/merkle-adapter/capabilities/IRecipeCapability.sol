// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRecipes} from "../IRecipes.sol";

/**
 * @title IRecipeCapability
 * @notice Interface for account-context recipes authorized by an outer Merkle action.
 */
interface IRecipeCapability is IRecipes {
    /* ERRORS */

    /**
     * @notice Raised when the caller is not the account itself.
     */
    error InvalidCaller();

    /* FUNCTIONS */

    /**
     * @notice Executes a Merkle-committed recipe as the account.
     * @dev Requires an account self-call through manage. Pin queries, operations, targets,
     * selectors, layouts, bindings and safety thresholds in the outer leaf; mask only intended
     * variable inputs. Reads use STATICCALL; Call uses CALL without native value. Manage and
     * Approve are unsupported. For delta checks use before/after Read and checked Sub.
     * Every failure rolls back the entire execution. The account provides reentrancy protection.
     * @param queries Shared encoded static queries, using the IRecipes instruction schema.
     * @param steps Chronological reads, arithmetic, assertions and direct calls.
     * @param inputs Numerical inputs constrained by the committed calls and assertions.
     * @return values Numerical results by instruction index; calls and assertions return zero slots.
     */
    function execute(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs)
        external
        returns (uint256[] memory values);
}

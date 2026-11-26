// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IOptimismPortal
 * @notice Minimal interface for the OP Stack portal that sends Ethereum-to-L2 deposit transactions.
 */
interface IOptimismPortal {
    /**
     * @notice Returns whether deposits and withdrawals are paused.
     * @return status Whether the portal is paused.
     */
    function paused() external view returns (bool status);

    /**
     * @notice Sends a deposit transaction to the L2. A contract sender is aliased on the L2 by adding
     * 0x1111000000000000000000000000000000001111 to its address.
     * @param to L2 call target.
     * @param value ETH value forwarded on the L2.
     * @param gasLimit L2 gas limit, burned on Ethereum through the portal resource market.
     * @param isCreation Whether the deposit creates a contract.
     * @param data L2 calldata.
     */
    function depositTransaction(address to, uint256 value, uint64 gasLimit, bool isCreation, bytes memory data)
        external
        payable;
}

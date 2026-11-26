// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ISafeModules
 * @notice Minimal interface for the Safe v1.4.1 module manager.
 */
interface ISafeModules {
    /**
     * @notice Emitted when a module call fails. `execTransactionFromModule` returns false instead of reverting.
     * @param module Module that made the call.
     */
    event ExecutionFromModuleFailure(address indexed module);

    /**
     * @notice Emitted when a module call succeeds.
     * @param module Module that made the call.
     */
    event ExecutionFromModuleSuccess(address indexed module);

    /**
     * @notice Enables a module. Only the Safe itself can call this.
     * @param module Module to enable.
     */
    function enableModule(address module) external;

    /**
     * @notice Executes a call or delegatecall from the Safe. Only an enabled module can call this.
     * @param to Call target.
     * @param value ETH value.
     * @param data Calldata.
     * @param operation 0 for call, 1 for delegatecall.
     * @return success Whether the call succeeded.
     */
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success);

    /**
     * @notice Returns whether a module is enabled.
     * @param module Module to query.
     * @return enabled Whether the module is enabled.
     */
    function isModuleEnabled(address module) external view returns (bool enabled);
}

/**
 * @title ISafeProxyFactory
 * @notice Minimal interface for the Safe v1.4.1 proxy factory.
 */
interface ISafeProxyFactory {
    /**
     * @notice Deploys a Safe proxy with CREATE2 and calls its initializer.
     * @param singleton Safe implementation.
     * @param initializer Calldata for `setup`.
     * @param saltNonce Salt nonce mixed with the initializer hash.
     * @return proxy Deployed Safe.
     */
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/**
 * @title IMultiSend
 * @notice Minimal interface for Safe's MultiSendCallOnly, delegatecalled from a Safe to batch its calls.
 */
interface IMultiSend {
    /**
     * @notice Executes packed `(uint8 operation, address to, uint256 value, uint256 length, bytes data)` calls.
     * @param transactions Packed calls.
     */
    function multiSend(bytes memory transactions) external payable;
}

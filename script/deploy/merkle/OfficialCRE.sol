// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Published CRE deployed-workflow endpoints, never simulation forwarders.
library OfficialCRE {
    // https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-go
    address internal constant MAINNET_FORWARDER = 0x0b93082D9b3C7C97fAcd250082899BAcf3af3885;
    address internal constant SEPOLIA_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    // smartcontractkit/cre-cli internal/environments/environments.yaml: PRODUCTION / STAGING.
    address internal constant MAINNET_REGISTRY = 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5;
    address internal constant SEPOLIA_REGISTRY = 0xaE55eB3EDAc48a1163EE2cbb1205bE1e90Ea1135;

    error InvalidCRE();

    function forwarder(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return MAINNET_FORWARDER;
        if (chainId == 11_155_111) return SEPOLIA_FORWARDER;
        revert InvalidCRE();
    }

    function registry(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return MAINNET_REGISTRY;
        if (chainId == 11_155_111) return SEPOLIA_REGISTRY;
        revert InvalidCRE();
    }

    function validate(uint256 chainId, address workflowRegistry, address reportForwarder) internal view {
        if (block.chainid != chainId || reportForwarder != forwarder(chainId) || workflowRegistry != registry(chainId))
        {
            revert InvalidCRE();
        }
        _version(workflowRegistry, "WorkflowRegistry 2.0.0");
        _version(reportForwarder, "KeystoneForwarder 1.0.0");
    }

    function _version(address target, string memory expected) private view {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSignature("typeAndVersion()"));
        if (
            !success || result.length < 64
                || keccak256(bytes(abi.decode(result, (string)))) != keccak256(bytes(expected))
        ) {
            revert InvalidCRE();
        }
    }
}

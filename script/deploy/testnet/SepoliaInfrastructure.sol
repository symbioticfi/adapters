// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {OfficialCRE} from "../merkle/OfficialCRE.sol";
import {WorkflowRegistry} from "test/mocks/chainlink-cre/WorkflowRegistry.sol";

/**
 * @title SepoliaInfrastructure
 * @notice Library for the official deployments compatible with the live 3F Sepolia auction API.
 * @dev Do not mix this factory/facility generation with the newer deployments.json generation.
 * CRE's Sepolia deployed-workflow forwarder is published in Chainlink's forwarder directory.
 * Local acceptance uses a Sepolia replica of the upstream Workflow Registry.
 */
library SepoliaInfrastructure {
    uint256 internal constant CHAIN_ID = 11_155_111;
    address internal constant FORWARDER = OfficialCRE.SEPOLIA_FORWARDER;
    address internal constant REQUESTS_FACTORY = 0x56834F241E4A4D6e5C4207B03bB16b2B3FfCc5fb;
    address internal constant FACILITY = 0x68129DbAEefA7eB88fc0276b9C27A5169c43d675;
    address internal constant WHITELIST = 0xA80b976A357aC24f3c38F7E5ED3Dd5b813bb09E1;
    address internal constant USDC = 0x809e6c18bC13Cc7C9F7b8000d74243BAaccE84d7;

    error InvalidInfrastructure();

    /**
     * @notice Checks the official contracts and the supplied same-chain WorkflowRegistry before any deployment.
     */
    function validate(address registry) internal view {
        validateThreeF();
        validateCRE(registry);
    }

    /**
     * @notice Checks the official 3F bundle.
     */
    function validateThreeF() internal view {
        if (
            block.chainid != CHAIN_ID || REQUESTS_FACTORY.code.length == 0 || FACILITY.code.length == 0
                || WHITELIST.code.length == 0 || USDC.code.length == 0
        ) revert InvalidInfrastructure();
        (bool success, bytes memory result) = USDC.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success || result.length != 32 || abi.decode(result, (uint8)) != 6) revert InvalidInfrastructure();
    }

    /**
     * @notice Checks the Sepolia replica of the upstream Workflow Registry and official report forwarder.
     */
    function validateCRE(address registry) internal view {
        validateForwarder();
        if (registry.codehash != keccak256(type(WorkflowRegistry).runtimeCode)) revert InvalidInfrastructure();
    }

    function validateForwarder() internal view {
        if (block.chainid != CHAIN_ID) revert InvalidInfrastructure();
        (bool success, bytes memory result) = FORWARDER.staticcall(abi.encodeWithSignature("typeAndVersion()"));
        if (
            !success || result.length < 64
                || keccak256(bytes(abi.decode(result, (string)))) != keccak256("KeystoneForwarder 1.0.0")
        ) revert InvalidInfrastructure();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title BaseChain
 * @notice Library of the external Ethereum and Base addresses used by the Base Safe deployment and its actions.
 * @dev Sources: Safe v1.4.1 deployments, Circle CCTP v2 EVM contracts, Base's L1 contract list and
 * https://docs.3f.xyz/protocol/deployments/?chain=base. Each address was checked onchain before use.
 */
library BaseChain {
    /* CONSTANTS */

    /// @dev Chain IDs.
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    /// @dev CCTP v2 domains and the Standard Transfer finality threshold; Standard Transfer has no fee.
    uint32 internal constant ETHEREUM_DOMAIN = 0;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant STANDARD_FINALITY = 2000;

    /// @dev CCTP v2 contracts share one address on Ethereum and Base.
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    /// @dev Native USDC.
    address internal constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Base OptimismPortal proxy on Ethereum.
    address internal constant BASE_PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e;

    /// @dev Offset that the portal adds to a contract sender's address on the L2.
    uint160 internal constant ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);

    /// @dev L2 gas limit pinned into every portal leaf. The executor must use the same value as the leaf builder.
    uint64 internal constant PORTAL_GAS_LIMIT = 1_000_000;

    /// @dev Safe v1.4.1 contracts on Base.
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant SAFE_MULTI_SEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

    /// @dev Multicall3, at its canonical address. Recipe queries use it to read a runtime-selected 3F request.
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    /// @dev 3F contracts on Base.
    address internal constant THREE_F_REQUESTS_FACTORY = 0x5A5641b43Fb4479Ae09c97AEc8588f9887E75943;
    address internal constant THREE_F_FACILITY = 0x3f6909F4742cc30F9AcA4131690B4404aC73b180;

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Returns the address that a contract on Ethereum has on Base when it sends a portal deposit.
     * @dev Adds the OP Stack alias offset with wrapping arithmetic. Use it to find the module that the Ethereum
     * MerkleAccount controls on the Base Safe.
     */
    function l2Alias(address ethereumSender) internal pure returns (address) {
        unchecked {
            // Address aliasing is defined modulo 2^160.
            return address(uint160(ethereumSender) + ALIAS_OFFSET);
        }
    }
}

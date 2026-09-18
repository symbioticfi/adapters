// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVaultFactory} from "@symbioticfi/core/src/interfaces/IVaultFactory.sol";

library SymbioticCoreConstants {
    struct Core {
        IVaultFactory vaultFactory;
    }

    /// @notice Reports whether the current chain has a configured Symbiotic core deployment.
    /// @dev Matches the supported chain IDs used by the original deployment fixture.
    function coreSupported() internal view returns (bool) {
        return block.chainid == 1 || block.chainid == 17_000 || block.chainid == 11_155_111 || block.chainid == 560_048;
    }

    /// @notice Returns the configured core vault factory for the current supported chain.
    /// @dev Preserves the original addresses and reverts for unsupported chain IDs.
    function core() internal view returns (Core memory) {
        if (block.chainid == 1) {
            return Core({vaultFactory: IVaultFactory(0xAEb6bdd95c502390db8f52c8909F703E9Af6a346)});
        }
        if (block.chainid == 17_000 || block.chainid == 11_155_111 || block.chainid == 560_048) {
            return Core({vaultFactory: IVaultFactory(0x407A039D94948484D356eFB765b3c74382A050B4)});
        }
        revert("SymbioticCoreConstants.core(): chainid not supported");
    }
}

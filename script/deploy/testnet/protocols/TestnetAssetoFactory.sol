// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IAssetoAccount} from "src/interfaces/ll-adapter/asseto/IAssetoAccount.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title TestnetAssetoFactory
/// @notice Factory helper that supplies a fixture destination to the production Asseto account.
/// @dev Liquid Lane supplies only vault and adapter. The production initializer also requires an
/// off-chain destination; expanding that payload here keeps the account implementation unchanged.
contract TestnetAssetoFactory is MigratablesFactory {
    /* IMMUTABLES */

    bytes32 public immutable offChainDestination;

    /* CONSTRUCTOR */

    constructor(address newOwner, bytes32 newOffChainDestination) MigratablesFactory(newOwner) {
        offChainDestination = newOffChainDestination;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc MigratablesFactory
    function create(uint64 version, address newOwner, bytes calldata data) public override returns (address) {
        if (data.length == 64) {
            (address vault, address adapter) = abi.decode(data, (address, address));
            return this.create(
                version,
                newOwner,
                abi.encode(
                    IAssetoAccount.InitParams({
                        vault: vault, adapter: adapter, offChainDestination: offChainDestination
                    })
                )
            );
        }
        return super.create(version, newOwner, data);
    }
}

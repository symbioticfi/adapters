// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/* Native Morpho Vault V2/adapter read subsets used by the copied VaultV2LiquidityLib. */
interface IVaultV2 is IERC4626 {
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function canSendShares(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);
}

interface IMorphoMarketV1AdapterV2 {
    function morpho() external view returns (address);
    function supplyShares(bytes32 id) external view returns (uint256);
}

interface IMorphoVaultV1Adapter {
    function morphoVaultV1() external view returns (address);
}

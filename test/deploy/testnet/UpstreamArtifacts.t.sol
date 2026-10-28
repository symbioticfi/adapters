// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {UpstreamArtifacts} from "../../../script/deploy/testnet/protocols/UpstreamArtifacts.sol";

import {Test} from "forge-std/Test.sol";

interface IUpstreamProvider {
    function getMarketId() external view returns (string memory);
    function owner() external view returns (address);
}

interface IUpstreamPool {
    function ADDRESSES_PROVIDER() external view returns (address);
}

contract UpstreamArtifactHarness is UpstreamArtifacts {
    function deploy(string memory profile, string memory name, bytes memory args) public returns (address) {
        return _deployArtifact(profile, name, args);
    }
}

contract UpstreamArtifactsTest is Test {
    function test_DeploysRealLinkedPoolWithPinnedCompiler() public {
        address loader = address(new UpstreamArtifactHarness());
        address provider = UpstreamArtifactHarness(loader)
            .deploy("aave-v3", "PoolAddressesProvider", abi.encode("Aave", address(this)));
        address strategy = UpstreamArtifactHarness(loader)
            .deploy("aave-v3", "DefaultReserveInterestRateStrategyV2", abi.encode(provider));
        address pool = UpstreamArtifactHarness(loader).deploy("aave-v3", "PoolInstance", abi.encode(provider, strategy));
        assertEq(IUpstreamProvider(provider).getMarketId(), "Aave");
        assertEq(IUpstreamProvider(provider).owner(), address(this));
        assertEq(IUpstreamPool(pool).ADDRESSES_PROVIDER(), provider);
        assertLe(pool.code.length, 24_576);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";
import {TestnetThreeFRequest} from "./protocols/TestnetThreeF.sol";

import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SeedThreeFTestnetScript
/// @notice Funds signed offers through each production 3F adapter's just-in-time callback.
contract SeedThreeFTestnetScript is TestnetPhaseScript {
    error AlreadySeeded();

    function run() public {
        DeployRealisticTestnetScript.Deployment memory deployed = load();
        string[] memory values = vm.envString("TESTNET_THREE_F_SIGNATURES", ",");
        bytes[] memory signatures = new bytes[](values.length);
        for (uint256 i; i < values.length; ++i) {
            signatures[i] = vm.parseBytes(values[i]);
        }
        runBase(deployed, signatures);
    }

    function runBase(DeployRealisticTestnetScript.Deployment memory deployed, bytes[] memory signatures) public {
        if (signatures.length != deployed.markets.length) revert InvalidManifest();
        _start(deployed.owner);
        for (uint256 i; i < deployed.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory market = deployed.markets[i];
            if (IThreeFAdapter(market.threeFAdapter).requestIndex(market.request) > 0) revert AlreadySeeded();
            Offer memory offer = seedOffer(deployed, i);
            IERC20(market.asset).approve(market.request, offer.expectedReturn);
            TestnetThreeFRequest(market.request).fundAndConsume(offer, signatures[i]);
        }
        _stop();
    }

    function seedOffer(DeployRealisticTestnetScript.Deployment memory deployed, uint256 index)
        public
        view
        returns (Offer memory)
    {
        DeployRealisticTestnetScript.Market memory market = deployed.markets[index];
        uint256 price = index == 5 ? 3000e18 : index >= 2 && index <= 4 ? 60_000e18 : 1e18;
        uint256 amount = deployed.seedAssets * 10 ** IERC20Metadata(market.asset).decimals() * 1e18 / price;
        return Offer({
            maker: market.threeFAdapter,
            amount: amount / 50,
            expectedReturn: amount / 500,
            nonce: TestnetThreeFRequest(market.request).nonce(market.threeFAdapter),
            expiration: TestnetThreeFRequest(market.request).maturity(),
            useCallback: true
        });
    }
}

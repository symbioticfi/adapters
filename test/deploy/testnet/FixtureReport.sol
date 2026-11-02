// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {IUpstreamAavePool} from "script/deploy/testnet/protocols/UpstreamAave.sol";
import {TestnetPhaseScript} from "script/deploy/testnet/base/TestnetPhase.s.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFRequest} from "src/interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";

/// @notice Fixture-only report routing and valuation for the closed unit-test portfolio.
contract FixtureReport is TestnetPhaseScript {
    using Math for uint256;
    error DeliveryFailed();
    error LocalReportingUnavailable();

    function runBase(DeployRealisticTestnetScript.Deployment memory deployed, uint48 snapshot, uint256[] memory assets)
        public
    {
        if (block.chainid != 31_337) revert LocalReportingUnavailable();
        if (assets.length != deployed.markets.length) revert InvalidManifest();
        _start(deployed.owner);
        for (uint256 i; i < assets.length; ++i) {
            address adapter = deployed.markets[i].merkle.adapter;
            address oracle = IMerkleAdapter(adapter).oracle();
            address registry = deployed.markets[i].merkle.workflowRegistry;
            bytes memory metadata = abi.encodePacked(
                ICREWorkflowRegistry(registry).workflowId(oracle),
                bytes10(
                    Bytes.slice(
                        bytes(Strings.toHexString(uint256(sha256(bytes(Strings.toHexString(oracle)))), 32)), 2, 12
                    )
                ),
                registry,
                bytes2(0)
            );
            bytes memory report = abi.encode(
                ICREOracle.Report({
                    chainId: block.chainid, adapter: adapter, totalAssets: assets[i], snapshotBlock: snapshot
                })
            );
            bytes32 id = keccak256(abi.encode(oracle, snapshot));
            // Keystone checks entry gas independently of the gas consumed by a successful report.
            if (!KeystoneForwarder(deployed.forwarder).route{gas: 500_000}(
                    id, deployed.owner, oracle, metadata, report
                )) revert DeliveryFailed();
            if (ICREOracle(oracle).reportBlock() != vm.getBlockNumber()) revert DeliveryFailed();
            IUniversalDelegator(IVaultV2(IMerkleAdapter(adapter).vault()).delegator()).sweepPending();
        }
        _stop();
    }

    function nav(DeployRealisticTestnetScript.Market memory market) public view returns (uint256) {
        return navWithRequests(market, new address[](0));
    }

    function navWithRequests(DeployRealisticTestnetScript.Market memory market, address[] memory requests)
        public
        view
        returns (uint256 assets)
    {
        address account = IMerkleAdapter(market.merkle.adapter).account();
        assets = IERC20(market.asset).balanceOf(account);
        assets += IERC20(IUpstreamAavePool(market.aave).getReserveAToken(market.asset)).balanceOf(account);
        if (market.request != address(0)) {
            (uint256 pt, uint256 yt) = IThreeFVaultController(market.request).balancesOf(account);
            if (IThreeFVaultController(market.request).canWithdraw()) {
                (uint256 principal, uint256 yieldAssets) =
                    IThreeFVaultController(market.request).convertToAssets(pt, yt);
                assets += principal + yieldAssets;
            } else {
                assets += pt;
            }
        }
        for (uint256 i; i < requests.length; ++i) {
            address request = requests[i];
            if (request == market.request) continue;
            for (uint256 j; j < i; ++j) {
                if (requests[j] == request) revert InvalidManifest();
            }
            if (
                !IThreeFRequestFactory(market.threeF).isRequest(request)
                    || IThreeFRequest(request).asset() != market.asset
            ) revert InvalidManifest();
            (uint256 pt, uint256 yt) = IThreeFVaultController(request).balancesOf(account);
            if (IThreeFVaultController(request).canWithdraw()) {
                (uint256 principal, uint256 yieldAssets) = IThreeFVaultController(request).convertToAssets(pt, yt);
                assets += principal + yieldAssets;
            } else {
                assets += pt;
            }
        }
        uint256 debt =
            IERC20(IUpstreamAavePool(market.aave).getReserveVariableDebtToken(market.asset)).balanceOf(account);
        return IMerkleAdapter(market.merkle.adapter).lockedLiquidity() + assets.saturatingSub(debt);
    }
}

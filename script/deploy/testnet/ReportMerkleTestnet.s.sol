// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {SepoliaInfrastructure} from "./SepoliaInfrastructure.sol";
import {TestnetAavePool, TestnetCreditVault} from "./protocols/TestnetLending.sol";
import {TestnetAaveV4, TestnetCollateralOracle} from "./protocols/TestnetNativeLending.sol";
import {TestnetMidnight} from "./protocols/upstream/TestnetMidnight.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {IOracle} from "src/interfaces/ll-adapter/IOracle.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";
import {IThreeFRequest} from "src/interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Id, MarketParams, IMorpho, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

import {Market} from "morpho-midnight/src/interfaces/IMidnight.sol";

import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";

/// @title ReportMerkleTestnetScript
/// @notice Values the deployed portfolio on a pinned completed block and routes reports through the real forwarder.
/// @dev Owner-authorized routing simulates DON delivery; it does not run Chainlink CRE consensus.
contract ReportMerkleTestnetScript is TestnetPhaseScript {
    using Math for uint256;
    using MorphoBalancesLib for IMorpho;
    using Strings for uint256;
    error DeliveryFailed();
    error LocalReportingUnavailable();

    function run() public {
        if (block.chainid == 11_155_111) revert LocalReportingUnavailable();
        DeployRealisticTestnetScript.Deployment memory deployed = load();
        uint256 liveFork = vm.activeFork();
        uint256 snapshot = vm.envOr("TESTNET_SNAPSHOT_BLOCK", block.number);
        // Script simulation starts at the latest completed RPC block. Routing is simulated one block later.
        vm.createSelectFork(vm.envString("TESTNET_RPC_URL"), snapshot);
        uint256[] memory assets = new uint256[](deployed.markets.length);
        for (uint256 i; i < assets.length; ++i) {
            string memory key = string.concat("TESTNET_MERKLE_THREEF_REQUESTS_", i.toString());
            address[] memory requests = new address[](0);
            if (bytes(vm.envOr(key, string(""))).length > 0) requests = vm.envAddress(key, ",");
            assets[i] = navWithRequests(deployed.markets[i], requests);
        }
        vm.selectFork(liveFork);
        if (snapshot == block.number) vm.roll(block.number + 1);
        runBase(deployed, uint48(snapshot), assets);
    }

    function runBase(DeployRealisticTestnetScript.Deployment memory deployed, uint48 snapshot, uint256[] memory assets)
        public
    {
        if (block.chainid == 11_155_111) revert LocalReportingUnavailable();
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

    function nav(DeployRealisticTestnetScript.Market memory market) public view returns (uint256 assets) {
        return _nav(market, new address[](0));
    }

    function navWithRequests(DeployRealisticTestnetScript.Market memory market, address[] memory requests)
        public
        view
        returns (uint256 assets)
    {
        return _nav(market, requests);
    }

    function _nav(DeployRealisticTestnetScript.Market memory market, address[] memory requests)
        internal
        view
        returns (uint256 assets)
    {
        address adapter = market.merkle.adapter;
        address account = IMerkleAdapter(adapter).account();
        assets = IERC20(market.asset).balanceOf(account);
        assets += IERC20(TestnetAavePool(market.aave).aToken()).balanceOf(account);
        assets += IERC4626(market.euler).convertToAssets(IERC20(market.euler).balanceOf(account));
        assets += IERC4626(market.morpho).convertToAssets(IERC20(market.morpho).balanceOf(account));
        assets += IERC4626(market.erc4626).convertToAssets(IERC20(market.erc4626).balanceOf(account));
        uint256 liabilities = TestnetAavePool(market.aave).debtOf(account);
        address[2] memory creditVaults = [market.euler, market.morpho];
        uint256 assetUnit = 10 ** IERC20Metadata(market.asset).decimals();
        for (uint256 i; i < creditVaults.length; ++i) {
            assets += TestnetCreditVault(creditVaults[i])
                .collateral(account)
                .mulDiv(TestnetCreditVault(creditVaults[i]).collateralPrice() * assetUnit, 1e36);
            liabilities += TestnetCreditVault(creditVaults[i]).debtOf(account);
        }
        MarketParams memory params = abi.decode(market.nativeLending.blueParams, (MarketParams));
        assets += IMorpho(market.nativeLending.blue).expectedSupplyAssets(params, account);
        Position memory position =
            IMorpho(market.nativeLending.blue).position(Id.wrap(market.nativeLending.blueId), account);
        uint256 price = TestnetCollateralOracle(market.nativeLending.oracle).price();
        assets += uint256(position.collateral).mulDiv(price, 1e36);
        liabilities += IMorpho(market.nativeLending.blue).expectedBorrowAssets(params, account);
        (uint128 credit, uint128 pendingFee,) = TestnetMidnight(market.nativeLending.midnight)
            .updatePositionView(
                abi.decode(market.nativeLending.midnightParams, (Market)), market.nativeLending.midnightId, account
            );
        assets += uint256(credit) - pendingFee;
        assets += uint256(
                TestnetMidnight(market.nativeLending.midnight).collateral(market.nativeLending.midnightId, account, 0)
            )
            .mulDiv(price, 1e36);
        liabilities += TestnetMidnight(market.nativeLending.midnight).debt(market.nativeLending.midnightId, account);
        assets += TestnetAaveV4(market.nativeLending.aaveV4).getUserSuppliedAssets(0, account);
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
        address factory =
            block.chainid == SepoliaInfrastructure.CHAIN_ID ? SepoliaInfrastructure.REQUESTS_FACTORY : market.threeF;
        for (uint256 i; i < requests.length; ++i) {
            address request = requests[i];
            if (request == market.request) continue;
            for (uint256 j; j < i; ++j) {
                if (requests[j] == request) revert InvalidManifest();
            }
            if (!IThreeFRequestFactory(factory).isRequest(request) || IThreeFRequest(request).asset() != market.asset) {
                revert InvalidManifest();
            }
            (uint256 pt, uint256 yt) = IThreeFVaultController(request).balancesOf(account);
            if (IThreeFVaultController(request).canWithdraw()) {
                (uint256 principal, uint256 yieldAssets) = IThreeFVaultController(request).convertToAssets(pt, yt);
                assets += principal + yieldAssets;
            } else {
                assets += pt;
            }
        }
        for (uint256 i; i < market.rwas.length; ++i) {
            uint256 balance = IERC20(market.rwas[i].token).balanceOf(account);
            if (balance > 0) {
                assets += balance.mulDiv(
                    IOracle(market.rwas[i].oracle).getPrice() * assetUnit,
                    1e18 * 10 ** IERC20Metadata(market.rwas[i].token).decimals()
                );
            }
        }
        assets = IMerkleAdapter(adapter).lockedLiquidity() + assets.saturatingSub(liabilities);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IUpstreamAavePool, IUpstreamSpoke} from "script/deploy/testnet/protocols/UpstreamAave.sol";
import {IUpstreamEVault, IUpstreamEVC} from "script/deploy/testnet/protocols/UpstreamEuler.sol";

import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {LiquidLaneAdapter} from "src/contracts/LiquidLaneAdapter.sol";
import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ActivateMerkleTestnetScript} from "script/deploy/testnet/ActivateMerkleTestnet.s.sol";
import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {FixtureReport} from "test/deploy/testnet/FixtureReport.sol";
import {SeedRealisticTestnetScript} from "script/deploy/testnet/SeedRealisticTestnet.s.sol";
import {SeedThreeFTestnetScript} from "script/deploy/testnet/SeedThreeFTestnet.s.sol";
import {TestnetCatalog} from "script/deploy/testnet/catalog/TestnetCatalog.sol";
import {TestnetThreeFRequest} from "script/deploy/testnet/protocols/TestnetThreeF.sol";
import {ValidateRealisticTestnetScript} from "script/deploy/testnet/ValidateRealisticTestnet.s.sol";

contract RealisticDeployHarness is DeployRealisticTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract RealisticActivateHarness is ActivateMerkleTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract RealisticSeedHarness is SeedRealisticTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract RealisticReportHarness is FixtureReport {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract RealisticThreeFHarness is SeedThreeFTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract RealisticTestnetTest is Test {
    DeployRealisticTestnetScript.Deployment internal _deployed;
    address internal _owner;
    uint256 internal _key;
    address internal _seed;
    address internal _report;
    address internal _deploy;
    address internal _threeF;
    mapping(address token => bool executed) internal _swapped;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        (_owner, _key) = makeAddrAndKey("ephemeral local testnet signer");
        _deploy = deployCode("RealisticTestnet.t.sol:RealisticDeployHarness");
        _deployed = RealisticDeployHarness(_deploy)
            .runBase(DeployRealisticTestnetScript.Config({owner: _owner, seedAssets: 100_000}));
        vm.deal(_owner, 1000 ether);
        address activate = deployCode("RealisticTestnet.t.sol:RealisticActivateHarness");
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 proof = keccak256("testnet ownership proof");
        bytes32 hash = RealisticActivateHarness(activate).linkHash(_deployed, expiry, proof);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(_key, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        RealisticActivateHarness(activate).runBase(_deployed, expiry, proof, abi.encodePacked(r, s, v));
        _report = deployCode("RealisticTestnet.t.sol:RealisticReportHarness");
        RealisticReportHarness(_report).runBase(_deployed, 999, new uint256[](_deployed.markets.length));
        _seed = deployCode("RealisticTestnet.t.sol:RealisticSeedHarness");
        vm.recordLogs();
        RealisticSeedHarness(_seed).runBase(_deployed);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("DoSwap((address,address,uint256,uint256))")
            ) {
                ILiquidLaneAdapter.Swap memory swap = abi.decode(logs[i].data, (ILiquidLaneAdapter.Swap));
                _swapped[swap.tokenIn] = true;
            }
        }
        _threeF = deployCode("RealisticTestnet.t.sol:RealisticThreeFHarness");
        bytes[] memory signatures = new bytes[](_deployed.markets.length);
        for (uint256 i; i < signatures.length; ++i) {
            Offer memory offer = RealisticThreeFHarness(_threeF).seedOffer(_deployed, i);
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(_key, TestnetThreeFRequest(_deployed.markets[i].request).offerDigest(offer));
            signatures[i] = abi.encodePacked(r, s, v);
        }
        RealisticThreeFHarness(_threeF).runBase(_deployed, signatures);
    }

    function test_LiquidLaneFactoryRegistersAdaptersAndVersionTwoConnectors() public view {
        for (uint256 i; i < _deployed.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory market = _deployed.markets[i];
            assertEq(LiquidLaneAdapter(market.liquidLaneAdapter).FACTORY(), market.connectorFactory);
            assertEq(LiquidLaneAdapter(market.liquidLaneAdapter).version(), 1);
            assertEq(LiquidLaneConnector(market.connector).FACTORY(), market.connectorFactory);
            assertEq(LiquidLaneConnector(market.connector).version(), 2);
            assertTrue(IRegistry(market.connectorFactory).isEntity(market.liquidLaneAdapter));
            assertTrue(IRegistry(market.connectorFactory).isEntity(market.connector));
        }
    }

    function test_FromZeroCreatesRegisteredFundedMarketsAndClearsRecipeAllowance() public view {
        for (uint256 i; i < _deployed.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory market = _deployed.markets[i];
            uint256 price = i == 5 ? 3000e18 : i >= 2 && i <= 4 ? 60_000e18 : 1e18;
            uint256 amount = 100_000 * 10 ** IERC20Metadata(market.asset).decimals() * 1e18 / price;
            // Discounted RWA swaps earn a small, real spread whose pending value uses each native account's rules.
            assertApproxEqRel(IERC4626(market.vault).totalAssets(), amount, 1e16);
            assertEq(IERC4626(market.vault).asset(), market.asset);
            address account = IMerkleAdapter(market.merkle.adapter).account();
            assertEq(IERC20(market.asset).allowance(account, market.aave), 0);
            assertEq(
                IERC20(IUpstreamAavePool(market.aave).getReserveAToken(market.asset)).balanceOf(account), amount / 10
            );
            assertGt(_aaveDebt(market, _owner), 0);
            assertGt(IUpstreamEVault(market.euler).debtOf(address(uint160(_owner) ^ uint160(i + 1))), 0);
            assertGt(IMerkleAccount(account).getCapabilities().length, 0);
            assertEq(IThreeFAdapter(market.threeFAdapter).requestsLength(), 1);
            assertEq(IThreeFAdapter(market.threeFAdapter).pendingAssets(market.request), amount / 50);
        }
    }

    function test_ReportExcludesUntrackedCashAndPreservesPullNAV() public {
        DeployRealisticTestnetScript.Market memory market = _deployed.markets[0];
        address adapter = market.merkle.adapter;
        address account = IMerkleAdapter(adapter).account();
        uint256 navBefore = RealisticReportHarness(_report).nav(market);
        uint256 lockedBefore = IMerkleAdapter(adapter).lockedLiquidity();
        uint256 returned = IERC20(market.asset).balanceOf(account) / 2;
        assertGt(returned, 0);

        deal(market.asset, address(this), 1);
        IERC20(market.asset).transfer(adapter, 1);
        assertEq(RealisticReportHarness(_report).nav(market), navBefore);

        vm.startPrank(account);
        IERC20(market.asset).approve(adapter, returned);
        IMerkleAdapter(adapter).pull(returned);
        IMerkleAdapter(adapter).pull(0);
        vm.stopPrank();

        assertEq(IMerkleAdapter(adapter).lockedLiquidity(), lockedBefore + returned);
        assertEq(RealisticReportHarness(_report).nav(market), navBefore);

        vm.mockCall(
            IUpstreamAavePool(market.aave).getReserveVariableDebtToken(market.asset),
            abi.encodeCall(IERC20.balanceOf, (account)),
            abi.encode(type(uint128).max)
        );
        assertEq(RealisticReportHarness(_report).nav(market), lockedBefore + returned);
    }

    function test_ReportReconcilesFundedPortfolioAtCompletedBlock() public {
        uint256[] memory navs = new uint256[](_deployed.markets.length);
        for (uint256 i; i < navs.length; ++i) {
            navs[i] = RealisticReportHarness(_report).nav(_deployed.markets[i]);
        }
        vm.roll(1001);
        vm.warp(block.timestamp + 12);
        RealisticReportHarness(_report).runBase(_deployed, 1000, navs);
        vm.roll(1002);
        for (uint256 i; i < navs.length; ++i) {
            assertEq(ICREOracle(IMerkleAdapter(_deployed.markets[i].merkle.adapter).oracle()).totalAssets(), navs[i]);
            assertEq(IMerkleAdapter(_deployed.markets[i].merkle.adapter).totalAssets(), navs[i]);
        }
    }

    function test_CatalogCoversEveryProfileWithFundedInventoryAndFactory() public view {
        bool[] memory seen = new bool[](TestnetCatalog.count());
        uint256 count;
        for (uint256 i; i < _deployed.markets.length; ++i) {
            for (uint256 j; j < _deployed.markets[i].rwas.length; ++j) {
                DeployRealisticTestnetScript.RWA memory rwa = _deployed.markets[i].rwas[j];
                assertFalse(seen[rwa.profile]);
                seen[rwa.profile] = true;
                assertEq(rwa.symbol, TestnetCatalog.profile(rwa.profile).symbol);
                assertGt(rwa.token.code.length, 0);
                assertGt(rwa.redemption.code.length, 0);
                assertGt(rwa.accountFactory.code.length, 0);
                assertGt(IERC20(rwa.token).balanceOf(_owner), 0);
                address account = ILiquidLaneAdapter(_deployed.markets[i].liquidLaneAdapter).accounts(rwa.token);
                assertEq(IAccount(account).TOKEN_TO_REDEEM(), rwa.token);
                // Synchronous redemptions are swept by subsequent just-in-time allocations.
                assertTrue(_swapped[rwa.token], rwa.symbol);
                if (rwa.mechanism == 6) assertGt(IAccount(account).totalAssets(), 0, rwa.symbol);
                ++count;
            }
        }
        assertEq(count, 52);
    }

    function test_SeedRejectsRerun() public {
        vm.expectRevert(SeedRealisticTestnetScript.AlreadySeeded.selector);
        RealisticSeedHarness(_seed).runBase(_deployed);
    }

    function test_ManifestRoundTripAndPersistedValidation() public {
        string memory path = "script/deploy/testnet/manifests/test-roundtrip.json";
        string memory previousWitness = vm.envOr("TESTNET_MANIFEST_WITNESS", string(""));
        string memory witness = string.concat(path, ".hash");
        vm.setEnv("TESTNET_MANIFEST_WITNESS", witness);
        RealisticDeployHarness(_deploy).writeManifest(_deployed, path);
        assertEq(vm.parseBytes32(vm.readFile(witness)), keccak256(bytes(vm.readFile(path))));
        vm.setEnv("TESTNET_MANIFEST", path);
        address validator = address(new ValidateRealisticTestnetScript());
        DeployRealisticTestnetScript.Deployment memory loaded = RealisticSeedHarness(_seed).load();
        assertEq(loaded.owner, _owner);
        assertEq(loaded.chainId, block.chainid);
        assertEq(loaded.markets.length, _deployed.markets.length);
        for (uint256 i; i < loaded.markets.length; ++i) {
            assertEq(loaded.markets[i].merkle.adapter, _deployed.markets[i].merkle.adapter);
            assertEq(loaded.markets[i].recipe, _deployed.markets[i].recipe);
            assertEq(loaded.markets[i].actions[0].proof, _deployed.markets[i].actions[0].proof);
            assertEq(loaded.markets[i].rwas.length, _deployed.markets[i].rwas.length);
        }
        assertEq(vm.parseJsonAddress(vm.readFile(path), ".markets[0].asset"), _deployed.markets[0].asset);
        ValidateRealisticTestnetScript(validator).run();
        vm.removeFile(path);
        vm.removeFile(witness);
        vm.setEnv("TESTNET_MANIFEST_WITNESS", previousWitness);
    }

    function test_ThreeFSeedRejectsAlreadyConsumedRequest() public {
        vm.expectRevert(SeedThreeFTestnetScript.AlreadySeeded.selector);
        RealisticThreeFHarness(_threeF).runBase(_deployed, new bytes[](_deployed.markets.length));
    }

    function _aaveDebt(DeployRealisticTestnetScript.Market memory market, address account)
        internal
        view
        returns (uint256)
    {
        return IERC20(IUpstreamAavePool(market.aave).getReserveVariableDebtToken(market.asset)).balanceOf(account);
    }
}

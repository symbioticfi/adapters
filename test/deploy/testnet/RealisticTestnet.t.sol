// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

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
import {ReportMerkleTestnetScript} from "script/deploy/testnet/ReportMerkleTestnet.s.sol";
import {SeedRealisticTestnetScript} from "script/deploy/testnet/SeedRealisticTestnet.s.sol";
import {SeedThreeFTestnetScript} from "script/deploy/testnet/SeedThreeFTestnet.s.sol";
import {TestnetAavePool, TestnetCreditVault} from "script/deploy/testnet/protocols/TestnetLending.sol";
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

contract RealisticReportHarness is ReportMerkleTestnetScript {
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
        _deploy = address(new RealisticDeployHarness());
        _deployed = RealisticDeployHarness(_deploy)
            .runBase(DeployRealisticTestnetScript.Config({owner: _owner, seedAssets: 100_000}));
        vm.deal(_owner, 1000 ether);
        address activate = address(new RealisticActivateHarness());
        bytes[] memory signatures = new bytes[](_deployed.markets.length);
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 proof = keccak256("testnet ownership proof");
        for (uint256 i; i < signatures.length; ++i) {
            bytes32 hash = RealisticActivateHarness(activate).linkHash(_deployed, i, expiry, proof);
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(_key, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
            signatures[i] = abi.encodePacked(r, s, v);
        }
        RealisticActivateHarness(activate).runBase(_deployed, expiry, proof, signatures);
        _report = address(new RealisticReportHarness());
        RealisticReportHarness(_report)
            .runBase(_deployed, 999, uint48(block.timestamp - 1), new uint256[](_deployed.markets.length));
        _seed = address(new RealisticSeedHarness());
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
        _threeF = address(new RealisticThreeFHarness());
        signatures = new bytes[](_deployed.markets.length);
        for (uint256 i; i < signatures.length; ++i) {
            Offer memory offer = RealisticThreeFHarness(_threeF).seedOffer(_deployed, i);
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(_key, TestnetThreeFRequest(_deployed.markets[i].request).offerDigest(offer));
            signatures[i] = abi.encodePacked(r, s, v);
        }
        RealisticThreeFHarness(_threeF).runBase(_deployed, signatures);
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
            assertEq(IERC20(TestnetAavePool(market.aave).aToken()).balanceOf(account), amount / 10);
            assertGt(TestnetAavePool(market.aave).debtOf(_owner), 0);
            assertGt(TestnetCreditVault(market.euler).totalBorrows(), 0);
            assertGt(IMerkleAccount(account).getCapabilities().length, 0);
            assertEq(IThreeFAdapter(market.threeFAdapter).requestsLength(), 1);
            assertEq(IThreeFAdapter(market.threeFAdapter).pendingAssets(market.request), amount / 50);
        }
    }

    function test_ReportReconcilesFundedPortfolioAtCompletedBlock() public {
        uint256[] memory navs = new uint256[](_deployed.markets.length);
        for (uint256 i; i < navs.length; ++i) {
            navs[i] = RealisticReportHarness(_report).nav(_deployed.markets[i]);
        }
        vm.roll(1001);
        vm.warp(block.timestamp + 12);
        RealisticReportHarness(_report).runBase(_deployed, 1000, uint48(block.timestamp - 12), navs);
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
                if (rwa.mechanism != 7) assertTrue(_swapped[rwa.token], rwa.symbol);
                if (rwa.mechanism == 6) assertGt(IAccount(account).totalAssets(), 0, rwa.symbol);
                ++count;
            }
        }
        assertEq(count, 53);
    }

    function test_SeedRejectsRerun() public {
        vm.expectRevert(SeedRealisticTestnetScript.AlreadySeeded.selector);
        RealisticSeedHarness(_seed).runBase(_deployed);
    }

    function test_ManifestRoundTripAndPersistedValidation() public {
        string memory path = "script/deploy/testnet/manifests/test-roundtrip.json";
        RealisticDeployHarness(_deploy).writeManifest(_deployed, path);
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
    }

    function test_ThreeFSeedRejectsAlreadyConsumedRequest() public {
        vm.expectRevert(SeedThreeFTestnetScript.AlreadySeeded.selector);
        RealisticThreeFHarness(_threeF).runBase(_deployed, new bytes[](_deployed.markets.length));
    }
}

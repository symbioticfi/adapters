// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {encodeWorkflowName} from "test/helpers/CREWorkflowName.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {IThreeFFacility} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFRequest} from "src/interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {ActivateMerkleTestnetScript} from "script/deploy/testnet/ActivateMerkleTestnet.s.sol";
import {SyncMerkleTestnetScript} from "script/deploy/testnet/SyncMerkleTestnet.s.sol";
import {SeedRealisticTestnetScript} from "script/deploy/testnet/SeedRealisticTestnet.s.sol";
import {SepoliaInfrastructure} from "script/deploy/testnet/SepoliaInfrastructure.sol";

import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";
import {WorkflowRegistry} from "test/mocks/chainlink-cre/WorkflowRegistry.sol";
import {IRouter} from "test/mocks/chainlink-cre/interfaces/IRouter.sol";

contract SepoliaInfrastructureHarness is Test {
    function validateSelfHosted(address registry, address forwarder, address owner, address publisher) external view {
        SepoliaInfrastructure.validateSelfHosted(registry, forwarder, owner, publisher);
    }
}

contract SepoliaActivateHarness is ActivateMerkleTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract SepoliaSyncHarness is SyncMerkleTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

/// @notice Models the official Sepolia token's public testnet faucet.
contract SepoliaFaucetToken is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address recipient, uint256 amount) public {
        _mint(recipient, amount);
    }
}

contract SepoliaDeployHarness is DeployRealisticTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract SepoliaSeedHarness is SeedRealisticTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract SepoliaInfrastructureTest is Test {
    function setUp() public {
        vm.setEnv("TESTNET_ORACLE_MODE", "official-cre");
        vm.setEnv("TESTNET_REPORT_PUBLISHER", vm.toString(address(0)));
    }

    function test_SelfHostedSepoliaOwnsOracleInfrastructureAndRetainsOfficialThreeF() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        (address owner, uint256 ownerKey) = makeAddrAndKey("self-hosted owner");
        address publisher = makeAddr("dedicated NAV publisher");
        vm.setEnv("TESTNET_ORACLE_MODE", "self-hosted");
        vm.setEnv("TESTNET_REPORT_PUBLISHER", vm.toString(publisher));
        vm.setEnv("TESTNET_CHAINLINK_REGISTRY", "");
        vm.etch(SepoliaInfrastructure.USDC, address(new SepoliaFaucetToken()).code);
        vm.etch(SepoliaInfrastructure.REQUESTS_FACTORY, hex"00");
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeWithSelector(IThreeFRequestFactory.isRequest.selector),
            abi.encode(false)
        );
        vm.etch(SepoliaInfrastructure.FACILITY, hex"00");
        vm.etch(SepoliaInfrastructure.WHITELIST, hex"00");
        DeployRealisticTestnetScript.Deployment memory deployed = SepoliaDeployHarness(
                address(new SepoliaDeployHarness())
            )
            .runBase(DeployRealisticTestnetScript.Config({owner: owner, seedAssets: 100_000}));
        assertEq(deployed.oracleMode, "self-hosted");
        assertEq(deployed.reportPublisher, publisher);
        assertTrue(deployed.forwarder != SepoliaInfrastructure.FORWARDER);
        assertEq(WorkflowRegistry(deployed.chainlinkRegistry).owner(), owner);
        assertEq(KeystoneForwarder(deployed.forwarder).owner(), owner);
        assertTrue(KeystoneForwarder(deployed.forwarder).isForwarder(publisher));
        assertFalse(KeystoneForwarder(deployed.forwarder).isForwarder(owner));
        address activate = address(new SepoliaActivateHarness());
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        string memory path = "script/deploy/testnet/manifests/self-hosted-test.json";
        SepoliaDeployHarness(address(new SepoliaDeployHarness())).writeManifest(deployed, path);
        vm.setEnv("TESTNET_MANIFEST", path);
        DeployRealisticTestnetScript.Deployment memory loaded = SepoliaActivateHarness(activate).load();
        assertEq(loaded.oracleMode, "self-hosted");
        assertEq(loaded.reportPublisher, publisher);
        assertEq(loaded.forwarder, deployed.forwarder);
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
        bytes[] memory signatures = new bytes[](deployed.markets.length);
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 proof = keccak256("self-hosted proof");
        for (uint256 i; i < signatures.length; ++i) {
            bytes32 hash = SepoliaActivateHarness(activate).linkHash(deployed, i, expiry, proof);
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(ownerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
            signatures[i] = abi.encodePacked(r, s, v);
        }
        SepoliaActivateHarness(activate).runBase(deployed, expiry, proof, signatures);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        SepoliaActivateHarness(activate)
            .runOfficialBase(deployed, new ActivateMerkleTestnetScript.WorkflowArtifact[](0));
        // Repeating activation keeps the accepted workflows instead of consuming fresh proofs.
        SepoliaActivateHarness(activate).runBase(deployed, expiry, proof, signatures);
        for (uint256 i; i < deployed.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory market = deployed.markets[i];
            assertEq(market.threeF, SepoliaInfrastructure.FACILITY);
            assertEq(market.request, address(0));
            assertEq(IThreeFPolicy(market.policy).REQUESTS_FACTORY(), SepoliaInfrastructure.REQUESTS_FACTORY);
            assertEq(IThreeFPolicy(market.policy).FACILITY(), SepoliaInfrastructure.FACILITY);
            assertEq(IThreeFAdapter(market.threeFAdapter).REQUEST_WHITELIST(), SepoliaInfrastructure.WHITELIST);
            address oracle = IMerkleAdapter(market.merkle.adapter).oracle();
            bytes32 workflow = ICREWorkflowRegistry(market.merkle.workflowRegistry).workflowId(oracle);
            bytes memory metadata =
                abi.encodePacked(workflow, encodeWorkflowName(oracle), market.merkle.workflowRegistry, bytes2(0));
            bytes memory report = abi.encode(
                ICREOracle.Report({
                    chainId: block.chainid, adapter: market.merkle.adapter, totalAssets: 0, snapshotBlock: 999
                })
            );
            vm.prank(owner);
            vm.expectRevert(IRouter.UnauthorizedForwarder.selector);
            KeystoneForwarder(deployed.forwarder).route(bytes32(i + 1), owner, oracle, metadata, report);
            vm.prank(publisher);
            assertTrue(
                KeystoneForwarder(deployed.forwarder).route{gas: 500_000}(
                    bytes32(i + 1), publisher, oracle, metadata, report
                )
            );
        }
        address sync = address(new SepoliaSyncHarness());
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        SepoliaSyncHarness(sync).runBase(deployed);
        vm.roll(1001);
        SepoliaSyncHarness(sync).runBase(deployed);
        vm.deal(owner, 1000 ether);
        SepoliaSeedHarness(address(new SepoliaSeedHarness())).runBase(deployed);
        assertGt(IERC20(deployed.markets[0].vault).totalSupply(), 0);
        for (uint256 i; i < deployed.markets.length; ++i) {
            assertEq(IThreeFAdapter(deployed.markets[i].threeFAdapter).requestsLength(), 0);
        }
        vm.setEnv("TESTNET_ORACLE_MODE", "official-cre");
        vm.setEnv("TESTNET_REPORT_PUBLISHER", vm.toString(address(0)));
    }

    function test_SelfHostedInfrastructureRejectsSourceOwnershipOrPublisherMismatch() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        address owner = makeAddr("oracle infrastructure owner");
        address publisher = makeAddr("oracle report publisher");
        vm.startPrank(owner);
        address registry = address(new WorkflowRegistry());
        address forwarder = address(new KeystoneForwarder());
        address[] memory signers = new address[](1);
        signers[0] = owner;
        WorkflowRegistry(registry).updateAllowedSigners(signers, true);
        KeystoneForwarder(forwarder).addForwarder(publisher);
        vm.stopPrank();
        SepoliaInfrastructureHarness harness = new SepoliaInfrastructureHarness();
        harness.validateSelfHosted(registry, forwarder, owner, publisher);
        vm.expectRevert(SepoliaInfrastructure.InvalidInfrastructure.selector);
        harness.validateSelfHosted(registry, forwarder, publisher, publisher);
        vm.expectRevert(SepoliaInfrastructure.InvalidInfrastructure.selector);
        harness.validateSelfHosted(registry, forwarder, owner, owner);
        vm.etch(forwarder, hex"00");
        vm.expectRevert(SepoliaInfrastructure.InvalidInfrastructure.selector);
        harness.validateSelfHosted(registry, forwarder, owner, publisher);
    }

    function test_OfficialBundleMatchesLiveNativeInterfaces() public {
        string memory rpc = vm.envOr("SEPOLIA_INFRASTRUCTURE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // A fixed observed request avoids racing the auction's current funding/settlement status.
        vm.createSelectFork(rpc, 11_871_531);
        SepoliaInfrastructure.validate(SepoliaInfrastructure.WORKFLOW_REGISTRY);
        address request = 0x2c6F509DCd2A6009A9bA38fADd644E6461a29913;
        assertGt(SepoliaInfrastructure.FORWARDER.code.length, 0);
        assertTrue(IThreeFRequestFactory(SepoliaInfrastructure.REQUESTS_FACTORY).isRequest(request));
        assertEq(uint256(IThreeFWhitelist(SepoliaInfrastructure.WHITELIST).isWhitelisted(request)), 1);
        assertEq(IThreeFRequest(request).asset(), SepoliaInfrastructure.USDC);
        assertEq(IERC20Metadata(SepoliaInfrastructure.USDC).decimals(), 6);
        (IThreeFFacility.IntentProperties memory properties,, address boundRequest,) =
            IThreeFFacility(SepoliaInfrastructure.FACILITY).getIntent(16_393);
        assertEq(boundRequest, request);
        assertEq(properties.depositAsset.asset, SepoliaInfrastructure.USDC);
        assertTrue(properties.targetAsset.isPositionManager);
    }

    function test_RejectsMissingRegistryBeforeDeployingCore() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        vm.setEnv("TESTNET_CHAINLINK_REGISTRY", vm.toString(address(0)));
        address script = address(new SepoliaDeployHarness());
        vm.expectRevert(SepoliaInfrastructure.InvalidInfrastructure.selector);
        SepoliaDeployHarness(script)
            .runBase(DeployRealisticTestnetScript.Config({owner: address(this), seedAssets: 100_000}));
    }

    function test_SepoliaDeployBindsOfficialDependenciesAndSeedUsesFaucetWithoutFakeRequests() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        address owner = makeAddr("Sepolia test broadcaster");
        address registry = address(new WorkflowRegistry());
        vm.setEnv("TESTNET_CHAINLINK_REGISTRY", vm.toString(registry));
        vm.etch(SepoliaInfrastructure.USDC, address(new SepoliaFaucetToken()).code);
        vm.etch(SepoliaInfrastructure.FORWARDER, address(new KeystoneForwarder()).code);
        vm.etch(SepoliaInfrastructure.REQUESTS_FACTORY, hex"00");
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeWithSelector(IThreeFRequestFactory.isRequest.selector),
            abi.encode(false)
        );
        vm.etch(SepoliaInfrastructure.FACILITY, hex"00");
        vm.etch(SepoliaInfrastructure.WHITELIST, hex"00");
        address script = address(new SepoliaDeployHarness());
        DeployRealisticTestnetScript.Deployment memory deployed = SepoliaDeployHarness(script)
            .runBase(DeployRealisticTestnetScript.Config({owner: owner, seedAssets: 100_000}));
        assertEq(deployed.chainlinkRegistry, registry);
        assertEq(deployed.forwarder, SepoliaInfrastructure.FORWARDER);
        assertEq(deployed.markets[0].asset, SepoliaInfrastructure.USDC);
        for (uint256 i; i < deployed.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory market = deployed.markets[i];
            assertEq(market.threeF, SepoliaInfrastructure.FACILITY);
            assertEq(IThreeFAdapter(market.threeFAdapter).REQUEST_WHITELIST(), SepoliaInfrastructure.WHITELIST);
            assertEq(IThreeFPolicy(market.policy).REQUESTS_FACTORY(), SepoliaInfrastructure.REQUESTS_FACTORY);
            assertEq(IThreeFPolicy(market.policy).FACILITY(), SepoliaInfrastructure.FACILITY);
            assertEq(IThreeFPolicy(market.policy).remainingAssets(market.asset, deployed.collateral), 0);
            assertEq(market.request, address(0));
            assertEq(market.recipe.length, 3);
            for (uint256 j; j < market.actions.length; ++j) {
                assertTrue(market.actions[j].target != address(0));
            }
            address oracle = IMerkleAdapter(market.merkle.adapter).oracle();
            assertEq(ICREOracle(oracle).FORWARDER(), SepoliaInfrastructure.FORWARDER);
            assertEq(ICREWorkflowRegistry(market.merkle.workflowRegistry).CHAINLINK_WORKFLOW_REGISTRY(), registry);
            // Unit-test delivery; the Sepolia scripts cannot impersonate this sender.
            bytes32 id = keccak256(abi.encode(i));
            vm.mockCall(
                market.merkle.workflowRegistry,
                abi.encodeCall(ICREWorkflowRegistry.workflowId, (oracle)),
                abi.encode(id)
            );
            bytes10 workflowName = encodeWorkflowName(oracle);
            vm.prank(SepoliaInfrastructure.FORWARDER);
            ICREOracle(oracle)
                .onReport(
                    abi.encodePacked(id, workflowName, market.merkle.workflowRegistry, bytes2(0)),
                    abi.encode(
                        ICREOracle.Report({
                            chainId: block.chainid, adapter: market.merkle.adapter, totalAssets: 0, snapshotBlock: 999
                        })
                    )
                );
        }
        vm.deal(owner, 1000 ether);
        SepoliaSeedHarness(address(new SepoliaSeedHarness())).runBase(deployed);
        assertGt(IERC20(deployed.markets[0].vault).totalSupply(), 0);
        assertGt(IERC20(SepoliaInfrastructure.USDC).totalSupply(), 0);
        for (uint256 i; i < deployed.markets.length; ++i) {
            assertEq(IThreeFAdapter(deployed.markets[i].threeFAdapter).requestsLength(), 0);
        }
    }
}

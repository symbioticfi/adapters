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
import {OfficialCRE} from "script/deploy/merkle/OfficialCRE.sol";

import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";
import {WorkflowRegistry} from "test/mocks/chainlink-cre/WorkflowRegistry.sol";

contract SepoliaInfrastructureHarness is Test {
    function validateCRE(address registry) external view {
        SepoliaInfrastructure.validateCRE(registry);
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
        address script = address(new SepoliaDeployHarness());
        vm.expectRevert(SepoliaInfrastructure.InvalidInfrastructure.selector);
        SepoliaDeployHarness(script)
            .runBase(DeployRealisticTestnetScript.Config({owner: address(this), seedAssets: 100_000}));
    }

    function test_RejectsUnofficialRegistry() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        address harness = address(new SepoliaInfrastructureHarness());
        address registry = address(new WorkflowRegistry());
        vm.expectRevert(OfficialCRE.InvalidCRE.selector);
        SepoliaInfrastructureHarness(harness).validateCRE(registry);
    }

    function test_SepoliaDeployBindsOfficialDependenciesAndSeedUsesFaucetWithoutFakeRequests() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        address owner = makeAddr("Sepolia test broadcaster");
        address registry = SepoliaInfrastructure.WORKFLOW_REGISTRY;
        vm.etch(registry, address(new WorkflowRegistry()).code);
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
        DeployRealisticTestnetScript.Deployment memory deployed =
            SepoliaDeployHarness(script).runBase(DeployRealisticTestnetScript.Config({owner: owner, seedAssets: 2000}));
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
        vm.deal(owner, 3 ether);
        SepoliaSeedHarness(address(new SepoliaSeedHarness())).runBase(deployed);
        assertGt(IERC20(deployed.markets[0].vault).totalSupply(), 0);
        assertGt(IERC20(SepoliaInfrastructure.USDC).totalSupply(), 0);
        for (uint256 i; i < deployed.markets.length; ++i) {
            assertEq(IThreeFAdapter(deployed.markets[i].threeFAdapter).requestsLength(), 0);
        }
    }
}

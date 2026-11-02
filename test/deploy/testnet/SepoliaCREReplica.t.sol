// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ActivateMerkleTestnetScript} from "script/deploy/testnet/ActivateMerkleTestnet.s.sol";
import {SepoliaCRE, SepoliaCRERegistrationOwner} from "script/deploy/testnet/protocols/SepoliaCRE.sol";
import {OfficialCRE} from "script/deploy/merkle/OfficialCRE.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";
import {TestnetCreate2Factory} from "test/helpers/TestnetCreate2Factory.sol";
import {WorkflowRegistry} from "test/mocks/chainlink-cre/WorkflowRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Test} from "forge-std/Test.sol";

contract SepoliaCREPairHarness {
    function deploy(address owner, address replica) public returns (address) {
        return SepoliaCRE.deploy(owner, replica);
    }
}

contract SepoliaCREReplicaTest is Test {
    address internal _harness;

    function setUp() public {
        _harness = address(new SepoliaCREPairHarness());
        vm.etch(SepoliaCRE.CREATE2_DEPLOYER, address(new TestnetCreate2Factory()).code);
    }

    function test_SameOwnerAddressAcrossChainsWithDifferentRuntimeAndIdempotentDeployment() public {
        address replica = address(new WorkflowRegistry());
        uint256 initial = vm.snapshotState();
        vm.chainId(11_155_111);
        address sepolia = SepoliaCREPairHarness(_harness).deploy(address(this), replica);
        bytes32 sepoliaCode = sepolia.codehash;
        assertEq(CREWorkflowRegistry(sepolia).CHAINLINK_WORKFLOW_REGISTRY(), replica);
        assertEq(SepoliaCREPairHarness(_harness).deploy(address(this), replica), sepolia);
        assertTrue(vm.revertToState(initial));
        vm.chainId(1);
        address mainnet = SepoliaCREPairHarness(_harness).deploy(address(this), replica);
        assertEq(mainnet, sepolia);
        assertNotEq(mainnet.codehash, sepoliaCode);
        assertEq(Ownable(mainnet).owner(), address(this));
        assertEq(SepoliaCREPairHarness(_harness).deploy(address(this), replica), mainnet);
    }

    function test_StandAndOwnerIsolation() public {
        vm.chainId(11_155_111);
        address first = SepoliaCREPairHarness(_harness).deploy(address(this), address(1));
        assertNotEq(SepoliaCREPairHarness(_harness).deploy(address(this), address(2)), first);
        assertNotEq(SepoliaCREPairHarness(_harness).deploy(makeAddr("other owner"), address(1)), first);
        vm.chainId(10);
        vm.expectRevert(SepoliaCRE.InvalidPair.selector);
        SepoliaCREPairHarness(_harness).deploy(address(this), address(3));
    }

    function test_MissingDeterministicDeployerStopsPairCreation() public {
        vm.chainId(11_155_111);
        vm.etch(SepoliaCRE.CREATE2_DEPLOYER, "");
        vm.expectRevert(SepoliaCRE.InvalidPair.selector);
        SepoliaCREPairHarness(_harness).deploy(address(this), address(1));
    }

    function test_MainnetRegistrationMustMatchSepoliaArtifactsAndOwnerCanUnlink() public {
        vm.chainId(1);
        address upstream = address(new WorkflowRegistry());
        vm.etch(OfficialCRE.MAINNET_REGISTRY, upstream.code);
        vm.copyStorage(upstream, OfficialCRE.MAINNET_REGISTRY);
        upstream = OfficialCRE.MAINNET_REGISTRY;
        address authority = SepoliaCREPairHarness(_harness).deploy(address(this), address(1));
        address[] memory signers = new address[](1);
        signers[0] = vm.addr(0xC0DE);
        WorkflowRegistry(upstream).updateAllowedSigners(signers, true);
        WorkflowRegistry(upstream).setDONLimit("don", 100, 100);
        uint256 expiry = block.timestamp + 1 days;
        bytes32 proof = keccak256("test owner link");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(uint8(0), authority, block.chainid, upstream, "WorkflowRegistry 2.0.0", expiry, proof)
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xC0DE, digest);
        SepoliaCRERegistrationOwner(authority)
            .execute(abi.encodeCall(IChainlinkWorkflowRegistry.linkOwner, (expiry, proof, abi.encodePacked(r, s, v))));
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts =
            new ActivateMerkleTestnetScript.WorkflowArtifact[](1);
        artifacts[0] = ActivateMerkleTestnetScript.WorkflowArtifact({
            oracle: makeAddr("Sepolia oracle"),
            workflowId: keccak256("actual registered workflow"),
            params: ICREWorkflowRegistry.WorkflowParams({
                tag: "default",
                status: IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                donFamily: "don",
                binaryUrl: "https://example.com/nav.wasm.br",
                configUrl: "https://example.com/config.json",
                attributes: hex"1234"
            })
        });
        SepoliaCRERegistrationOwner(authority)
            .execute(
                abi.encodeCall(
                    IChainlinkWorkflowRegistry.upsertWorkflow,
                    (
                        Strings.toHexString(artifacts[0].oracle),
                        "default",
                        artifacts[0].workflowId,
                        artifacts[0].params.status,
                        "don",
                        artifacts[0].params.binaryUrl,
                        artifacts[0].params.configUrl,
                        hex"1234",
                        false
                    )
                )
            );
        address activation = address(new ActivateMerkleTestnetScript());
        ActivateMerkleTestnetScript(activation).verifyRegistration(authority, artifacts);
        artifacts[0].workflowId = keccak256("fabricated ID");
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        ActivateMerkleTestnetScript(activation).verifyRegistration(authority, artifacts);
        artifacts[0].workflowId = keccak256("actual registered workflow");
        artifacts[0].params.binaryUrl = "https://example.com/changed.wasm.br";
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        ActivateMerkleTestnetScript(activation).verifyRegistration(authority, artifacts);
        vm.expectRevert();
        SepoliaCRERegistrationOwner(authority).execute(hex"ffffffff");
        address unauthorized = makeAddr("unauthorized");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        vm.prank(unauthorized);
        SepoliaCRERegistrationOwner(authority).execute("");
        bytes32 unlinkProof = proof;
        digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        uint8(1), authority, block.chainid, upstream, "WorkflowRegistry 2.0.0", expiry, unlinkProof
                    )
                )
            )
        );
        (v, r, s) = vm.sign(0xC0DE, digest);
        SepoliaCRERegistrationOwner(authority)
            .execute(
                abi.encodeWithSignature(
                    "unlinkOwner(address,uint256,bytes)", authority, expiry, abi.encodePacked(r, s, v)
                )
            );
        assertFalse(WorkflowRegistry(upstream).isOwnerLinked(authority));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "script/base-chain/BaseChain.sol";
import {BaseSafePayloads} from "script/base-chain/BaseSafePayloads.sol";
import {BridgeUsdcToBaseBaseScript} from "script/actions/base-chain/base/BridgeUsdcToBaseBase.s.sol";
import {MintThreeFOnBaseBaseScript} from "script/actions/base-chain/base/MintThreeFOnBaseBase.s.sol";
import {TestnetPermissions} from "script/deploy/testnet/TestnetPermissions.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Test} from "forge-std/Test.sol";

import {IOptimismPortal} from "script/utils/interfaces/IOptimismPortal.sol";
import {ISafeModules} from "script/utils/interfaces/ISafeModules.sol";

/// @dev Checks each action's proof against a fixed root like MerkleAccount.manage, then records the call.
contract MerkleAccountRecorder {
    bytes32 public root;
    uint256 public calls;

    error InvalidMerkleProof();

    /// @dev Stores the root that every action proof must reach.
    constructor(bytes32 newRoot) {
        root = newRoot;
    }

    /// @dev Verifies each action leaf against the root as MerkleAccount does, then counts the call.
    function manage(IMerkleAccount.Action[] calldata actions) public returns (bytes[] memory results) {
        for (uint256 i; i < actions.length; ++i) {
            IMerkleAccount.Action calldata action = actions[i];
            bytes32 leaf = ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
            if (!MerkleProof.verifyCalldata(action.proof, root, leaf)) revert InvalidMerkleProof();
        }
        ++calls;
        results = new bytes[](actions.length);
    }
}

contract BaseSafePayloadsTest is Test {
    BaseSafePayloads.Deployment private _deployment;

    /// @dev Uses arbitrary deployment addresses; the payload builders only encode them.
    function setUp() public {
        _deployment = BaseSafePayloads.Deployment({
            ethereumAccount: makeAddr("ethereum account"),
            safe: makeAddr("safe"),
            recipeCapability: makeAddr("recipe capability"),
            policy: makeAddr("policy")
        });
    }

    /// @dev Runtime values sit only in masked bytes, so the executor's leaves equal the builder's templates.
    function testFuzz_LeavesIgnoreRuntimeValues(
        uint256 amount,
        address request,
        uint256 assets,
        uint256 yieldAssets,
        address underlyingAsset,
        uint48 duration
    ) public view {
        BaseSafePayloads.Deployment memory deployment = _deployment;
        assertEq(_leaf(BaseSafePayloads.approveBridge(amount)), _leaf(BaseSafePayloads.approveBridge(0)));
        assertEq(
            _leaf(BaseSafePayloads.bridgeToBase(deployment, amount)),
            _leaf(BaseSafePayloads.bridgeToBase(deployment, 0))
        );
        assertEq(
            _leaf(BaseSafePayloads.bridgeToEthereum(deployment, amount)),
            _leaf(BaseSafePayloads.bridgeToEthereum(deployment, 0))
        );
        assertEq(
            _leaf(BaseSafePayloads.mintThreeF(deployment, request, assets)),
            _leaf(BaseSafePayloads.mintThreeF(deployment, address(0), 0))
        );
        assertEq(
            _leaf(BaseSafePayloads.redeemThreeF(deployment, request)),
            _leaf(BaseSafePayloads.redeemThreeF(deployment, address(0)))
        );
        assertEq(
            _leaf(BaseSafePayloads.setMaxAssetsPerDuration(deployment, underlyingAsset, assets, duration)),
            _leaf(BaseSafePayloads.setMaxAssetsPerDuration(deployment, address(0), 0, 0))
        );
        assertEq(
            _leaf(BaseSafePayloads.setMinYieldPerRequest(deployment, underlyingAsset, yieldAssets)),
            _leaf(BaseSafePayloads.setMinYieldPerRequest(deployment, address(0), 0))
        );
    }

    /// @dev A leaf built for one Safe, policy, capability or Ethereum recipient does not authorize another.
    function test_LeavesPinDeployment() public {
        BaseSafePayloads.Deployment memory other = _deployment;
        other.safe = makeAddr("other safe");
        assertNotEq(
            _leaf(BaseSafePayloads.bridgeToBase(_deployment, 1)), _leaf(BaseSafePayloads.bridgeToBase(other, 1))
        );
        assertNotEq(
            _leaf(BaseSafePayloads.redeemThreeF(_deployment, address(1))),
            _leaf(BaseSafePayloads.redeemThreeF(other, address(1)))
        );
        other = _deployment;
        other.policy = makeAddr("other policy");
        assertNotEq(
            _leaf(BaseSafePayloads.mintThreeF(_deployment, address(1), 1)),
            _leaf(BaseSafePayloads.mintThreeF(other, address(1), 1))
        );
        assertNotEq(
            _leaf(BaseSafePayloads.setMinYieldPerRequest(_deployment, address(1), 1)),
            _leaf(BaseSafePayloads.setMinYieldPerRequest(other, address(1), 1))
        );
        other = _deployment;
        other.recipeCapability = makeAddr("other capability");
        assertNotEq(
            _leaf(BaseSafePayloads.bridgeToEthereum(_deployment, 1)), _leaf(BaseSafePayloads.bridgeToEthereum(other, 1))
        );
        other = _deployment;
        other.ethereumAccount = makeAddr("other ethereum account");
        assertNotEq(
            _leaf(BaseSafePayloads.bridgeToEthereum(_deployment, 1)), _leaf(BaseSafePayloads.bridgeToEthereum(other, 1))
        );
    }

    /// @dev Flipping any pinned byte changes the leaf; only the documented runtime words are free. The mint frees
    /// the request and the principal cap, the redeem frees only the request, and the bridge frees only the amount.
    function test_RecipeLeavesFreeOnlyTheirInputs() public view {
        _assertFreeBytes(BaseSafePayloads.bridgeToEthereum(_deployment, 7), 32);
        _assertFreeBytes(BaseSafePayloads.mintThreeF(_deployment, address(7), 7), 64);
        _assertFreeBytes(BaseSafePayloads.redeemThreeF(_deployment, address(7)), 32);
    }

    /// @dev The message approval leaf pins every byte, so a leaf for one digest cannot approve another.
    function test_MessageLeafPinsTheDigest() public view {
        _assertFreeBytes(BaseSafePayloads.approveMessage(_deployment, keccak256("a")), 0);
        assertNotEq(
            _leaf(BaseSafePayloads.approveMessage(_deployment, keccak256("a"))),
            _leaf(BaseSafePayloads.approveMessage(_deployment, keccak256("b")))
        );
    }

    /// @dev The mint and redeem recipes take the request from one input; no call target or other word is free.
    function test_ThreeFRecipesBindOneRequestInput() public {
        address request = makeAddr("request");
        (, uint256[] memory inputs) = _recipeOf(BaseSafePayloads.mintThreeF(_deployment, request, 5e6));
        assertEq(inputs.length, 2);
        assertEq(inputs[0], uint160(request));
        assertEq(inputs[1], 5e6);
        (, inputs) = _recipeOf(BaseSafePayloads.redeemThreeF(_deployment, request));
        assertEq(inputs.length, 1);
        assertEq(inputs[0], uint160(request));
    }

    /// @dev The portal deposit targets the Safe with the pinned gas limit and nests a self-call that delegatecalls
    /// @dev RecipeCapability.execute.
    function test_RecipeNestsSafeSelfDelegatecall() public view {
        IMerkleAccount.Action memory action = BaseSafePayloads.bridgeToEthereum(_deployment, 7);
        assertEq(action.target, BaseChain.BASE_PORTAL);
        assertEq(bytes4(action.data), IOptimismPortal.depositTransaction.selector);
        (address to, uint256 value, uint64 gasLimit, bool isCreation, bytes memory module) =
            abi.decode(_arguments(action.data), (address, uint256, uint64, bool, bytes));
        assertEq(to, _deployment.safe);
        assertEq(value, 0);
        assertEq(gasLimit, BaseChain.PORTAL_GAS_LIMIT);
        assertFalse(isCreation);
        assertEq(bytes4(module), ISafeModules.execTransactionFromModule.selector);
        uint8 operation;
        (to, value, module, operation) = abi.decode(_arguments(module), (address, uint256, bytes, uint8));
        assertEq(to, _deployment.safe);
        assertEq(operation, BaseSafePayloads.CALL);
        (to, value, module, operation) = abi.decode(_arguments(module), (address, uint256, bytes, uint8));
        assertEq(to, _deployment.recipeCapability);
        assertEq(operation, BaseSafePayloads.DELEGATECALL);
        assertEq(bytes4(module), IRecipeCapability.execute.selector);
        (,, uint256[] memory inputs) = abi.decode(_arguments(module), (bytes[], bytes[], uint256[]));
        assertEq(inputs.length, 1);
        assertEq(inputs[0], 7);
    }

    /// @dev Builder templates, a proofs file keyed by leaf and the action script produce proofs MerkleAccount accepts.
    function test_ActionScriptsAttachProofsFromFile() public {
        vm.chainId(BaseChain.ETHEREUM_CHAIN_ID);
        IMerkleAccount.Action[] memory templates = new IMerkleAccount.Action[](3);
        templates[0] = BaseSafePayloads.approveBridge(0);
        templates[1] = BaseSafePayloads.bridgeToBase(_deployment, 0);
        templates[2] = BaseSafePayloads.mintThreeF(_deployment, address(0), 0);
        (bytes32 root, bytes32[] memory leaves) = TestnetPermissions.authorize(templates);
        MerkleAccountRecorder account = new MerkleAccountRecorder(root);
        _deployment.ethereumAccount = address(account);
        string memory manifest = "cache/base-safe-payloads-manifest.json";
        string memory proofs = "cache/base-safe-payloads-proofs.json";
        _writeManifest(manifest);
        string memory json;
        for (uint256 i; i < leaves.length; ++i) {
            json = vm.serializeBytes32("proofs", vm.toString(leaves[i]), templates[i].proof);
        }
        vm.writeJson(json, proofs);

        new BridgeUsdcToBaseBaseScript().runBase(manifest, proofs, 5e6);
        new MintThreeFOnBaseBaseScript().runBase(manifest, proofs, makeAddr("request"), 5e6);
        assertEq(account.calls(), 2);
        vm.removeFile(manifest);
        vm.removeFile(proofs);
    }

    /// @dev Writes a minimal Base manifest with the fields the action scripts read.
    function _writeManifest(string memory path) private {
        vm.serializeUint("manifest", "chainId", BaseChain.BASE_CHAIN_ID);
        vm.serializeString("manifest", "threeF", "");
        vm.serializeAddress("manifest", "ethereumAccount", _deployment.ethereumAccount);
        vm.serializeAddress("manifest", "safe", _deployment.safe);
        vm.writeJson(vm.serializeAddress("manifest", "recipeCapability", _deployment.recipeCapability), path);
        vm.writeJson(vm.serializeAddress("policy", "policy", _deployment.policy), path, ".threeF");
    }

    /// @dev Checks that an action frees exactly `expected` bytes and that flipping any pinned byte changes its leaf.
    function _assertFreeBytes(IMerkleAccount.Action memory action, uint256 expected) private pure {
        uint256 free;
        for (uint256 i; i < action.dataMask.length; ++i) {
            if (action.dataMask[i] != 0) ++free;
        }
        assertEq(free, expected);
        bytes32 leaf = _leaf(action);
        for (uint256 i; i < action.data.length; ++i) {
            if (action.dataMask[i] != 0) continue;
            action.data[i] = bytes1(uint8(action.data[i]) ^ 1);
            assertNotEq(_leaf(action), leaf);
            action.data[i] = bytes1(uint8(action.data[i]) ^ 1);
        }
    }

    /// @dev Unwraps a recipe action down to the RecipeCapability `execute` arguments.
    function _recipeOf(IMerkleAccount.Action memory action)
        private
        pure
        returns (bytes[] memory steps, uint256[] memory inputs)
    {
        (,,,, bytes memory module) = abi.decode(_arguments(action.data), (address, uint256, uint64, bool, bytes));
        (,, module,) = abi.decode(_arguments(module), (address, uint256, bytes, uint8));
        (,, module,) = abi.decode(_arguments(module), (address, uint256, bytes, uint8));
        (, steps, inputs) = abi.decode(_arguments(module), (bytes[], bytes[], uint256[]));
    }

    /// @dev Returns the leaf MerkleAccount derives for an action.
    function _leaf(IMerkleAccount.Action memory action) private pure returns (bytes32) {
        return ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
    }

    /// @dev Returns calldata without its selector, for ABI decoding.
    function _arguments(bytes memory data) private pure returns (bytes memory arguments) {
        arguments = new bytes(data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = data[i + 4];
        }
    }
}

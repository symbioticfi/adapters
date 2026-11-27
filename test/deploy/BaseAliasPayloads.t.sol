// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {BridgeUsdcFromBaseAliasBaseScript} from "script/actions/base-alias/base/BridgeUsdcFromBaseAliasBase.s.sol";
import {BridgeUsdcToBaseAliasBaseScript} from "script/actions/base-alias/base/BridgeUsdcToBaseAliasBase.s.sol";
import {MintThreeFFromAliasBaseScript} from "script/actions/base-alias/base/MintThreeFFromAliasBase.s.sol";
import {RedeemThreeFFromAliasBaseScript} from "script/actions/base-alias/base/RedeemThreeFFromAliasBase.s.sol";
import {
    SetThreeFMaxAssetsFromAliasBaseScript
} from "script/actions/base-alias/base/SetThreeFMaxAssetsFromAliasBase.s.sol";
import {
    SetThreeFMinYieldFromAliasBaseScript
} from "script/actions/base-alias/base/SetThreeFMinYieldFromAliasBase.s.sol";
import {BaseAliasPayloads} from "script/base-chain/BaseAliasPayloads.sol";
import {BaseChain} from "script/base-chain/BaseChain.sol";
import {TestnetPermissions} from "script/deploy/testnet/TestnetPermissions.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ITokenMessengerV2} from "script/utils/interfaces/ICCTPv2.sol";
import {IOptimismPortal} from "script/utils/interfaces/IOptimismPortal.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Receives script calls and verifies the same action leaves as MerkleAccount.manage.
contract AliasAccountRecorder {
    bytes32 public root;
    uint256 public calls;
    uint256 public lastActionCount;

    error InvalidMerkleProof();

    function manage(IMerkleAccount.Action[] calldata actions) public returns (bytes[] memory) {
        for (uint256 i; i < actions.length; ++i) {
            if (!MerkleProof.verifyCalldata(actions[i].proof, root, BaseAliasPayloads.leaf(actions[i]))) {
                revert InvalidMerkleProof();
            }
        }
        ++calls;
        lastActionCount = actions.length;
        return new bytes[](actions.length);
    }
}

contract BaseAliasPayloadsTest is Test {
    using Bytes for bytes;

    BaseAliasPayloads.Deployment private _deployment;

    function setUp() public {
        _deployment = BaseAliasPayloads.Deployment({
            ethereumAccount: makeAddr("Ethereum MerkleAccount"),
            manager: makeAddr("Base manager"),
            policy: makeAddr("Base policy")
        });
    }

    function testFuzz_LeavesIgnoreOnlyRuntimeValues(
        uint256 amount,
        address request,
        address underlyingAsset,
        uint128 principal,
        uint128 minYield,
        uint48 duration
    ) public view {
        IMerkleAccount.Action[] memory runtime =
            _actions(request, underlyingAsset, amount, principal, minYield, duration);
        IMerkleAccount.Action[] memory templates = _actions(address(0), address(0), 0, 0, 0, 0);
        for (uint256 i; i < runtime.length; ++i) {
            assertEq(BaseAliasPayloads.leaf(runtime[i]), BaseAliasPayloads.leaf(templates[i]));
        }
    }

    function test_LeavesAreDistinctAndPinEveryOtherByte() public view {
        IMerkleAccount.Action[] memory actions = _actions(address(0), address(0), 0, 0, 0, 0);
        uint256[7] memory expectedFree = [uint256(32), 32, 96, 64, 288, 32, 64];
        for (uint256 i; i < actions.length; ++i) {
            IMerkleAccount.Action memory action = actions[i];
            bytes32 leaf = BaseAliasPayloads.leaf(action);
            for (uint256 j; j < i; ++j) {
                assertNotEq(leaf, BaseAliasPayloads.leaf(actions[j]));
            }
            uint256 free;
            for (uint256 j; j < action.data.length; ++j) {
                if (action.dataMask[j] != 0) {
                    ++free;
                    continue;
                }
                action.data[j] ^= bytes1(uint8(1));
                assertNotEq(BaseAliasPayloads.leaf(action), leaf);
                action.data[j] ^= bytes1(uint8(1));
            }
            assertEq(free, expectedFree[i]);
        }
    }

    function test_MintPinsTheManagerAndPolicyAndCarriesOfferBounds() public view {
        address request = address(0x3F);
        bytes[] memory calls = _batch(BaseAliasPayloads.mintThreeF(_deployment, request, 10e6, 1e6));
        assertEq(calls.length, 5);
        _assertExecute(
            calls[0],
            _deployment.policy,
            abi.encodeCall(IThreeFPolicy.beginPushMint, (BaseChain.BASE_USDC, request, 10e6, 1e6))
        );
        _assertExecute(calls[1], BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, 10e6)));
        _assertExecute(calls[2], request, abi.encodeCall(IThreeFPushRequest.mint, (10e6, 1e6)));
        _assertExecute(calls[3], BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, 0)));
        _assertExecute(
            calls[4], _deployment.policy, abi.encodeCall(IThreeFPolicy.finishPushMint, (BaseChain.BASE_USDC))
        );
    }

    function test_BridgeRoutesFundsBetweenTheMerkleAccountAndManager() public view {
        IMerkleAccount.Action memory intoBase = BaseAliasPayloads.bridgeToBase(_deployment, 30e6);
        assertEq(intoBase.target, BaseChain.TOKEN_MESSENGER);
        assertEq(
            intoBase.data,
            abi.encodeCall(
                ITokenMessengerV2.depositForBurn,
                (
                    30e6,
                    BaseChain.BASE_DOMAIN,
                    bytes32(uint256(uint160(_deployment.manager))),
                    BaseChain.ETHEREUM_USDC,
                    bytes32(0),
                    0,
                    BaseChain.STANDARD_FINALITY
                )
            )
        );

        bytes[] memory calls = _batch(BaseAliasPayloads.bridgeToEthereum(_deployment, 30e6));
        assertEq(calls.length, 3);
        _assertExecute(calls[0], BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (BaseChain.TOKEN_MESSENGER, 30e6)));
        _assertExecute(
            calls[1],
            BaseChain.TOKEN_MESSENGER,
            abi.encodeCall(
                ITokenMessengerV2.depositForBurn,
                (
                    30e6,
                    BaseChain.ETHEREUM_DOMAIN,
                    bytes32(uint256(uint160(_deployment.ethereumAccount))),
                    BaseChain.BASE_USDC,
                    bytes32(0),
                    0,
                    BaseChain.STANDARD_FINALITY
                )
            )
        );
        _assertExecute(calls[2], BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (BaseChain.TOKEN_MESSENGER, 0)));
    }

    function test_ActionScriptsAttachProofsFromFile() public {
        vm.chainId(BaseChain.ETHEREUM_CHAIN_ID);
        IMerkleAccount.Action[] memory templates = _actions(address(0), address(0), 0, 0, 0, 0);
        (bytes32 root, bytes32[] memory leaves) = TestnetPermissions.authorize(templates);
        vm.etch(_deployment.ethereumAccount, address(new AliasAccountRecorder()).code);
        vm.store(_deployment.ethereumAccount, bytes32(0), root);

        string memory manifest = "cache/base-alias-payloads-manifest.json";
        string memory proofs = "cache/base-alias-payloads-proofs.json";
        vm.serializeUint("manifest", "chainId", BaseChain.BASE_CHAIN_ID);
        vm.serializeString("manifest", "threeF", "");
        vm.serializeAddress("manifest", "alias", BaseAliasPayloads.aliasOf(_deployment));
        vm.serializeAddress("manifest", "manager", _deployment.manager);
        vm.writeJson(vm.serializeAddress("manifest", "ethereumAccount", _deployment.ethereumAccount), manifest);
        vm.writeJson(vm.serializeAddress("policy", "policy", _deployment.policy), manifest, ".threeF");
        string memory json;
        for (uint256 i; i < leaves.length; ++i) {
            json = vm.serializeBytes32("proofs", vm.toString(leaves[i]), templates[i].proof);
        }
        vm.writeJson(json, proofs);

        new BridgeUsdcToBaseAliasBaseScript().runBase(manifest, proofs, 5e6);
        assertEq(AliasAccountRecorder(_deployment.ethereumAccount).lastActionCount(), 2);
        new SetThreeFMaxAssetsFromAliasBaseScript().runBase(manifest, proofs, address(0xBEEF), 5e6, 1 days);
        new SetThreeFMinYieldFromAliasBaseScript().runBase(manifest, proofs, address(0xBEEF), 1);
        address executor = address(new RecipeExecutor(address(this), _deployment.ethereumAccount));
        ExecutingRecipe.Recipe memory recipe = BaseAliasPayloads.mintRecipe(_deployment, 100e6);
        RecipeExecutor(executor).setRecipe(recipe.queries, recipe.steps);
        RecipeExecutor(executor).setCaller(DEFAULT_SENDER);
        new MintThreeFFromAliasBaseScript().runBase(manifest, proofs, executor, 100e6, address(0x3F), 10e6, 1e6);
        assertEq(AliasAccountRecorder(_deployment.ethereumAccount).lastActionCount(), 1);
        new RedeemThreeFFromAliasBaseScript().runBase(manifest, proofs, address(0x3F));
        new BridgeUsdcFromBaseAliasBaseScript().runBase(manifest, proofs, 5e6);
        assertEq(AliasAccountRecorder(_deployment.ethereumAccount).lastActionCount(), 1);
        assertEq(AliasAccountRecorder(_deployment.ethereumAccount).calls(), 6);

        vm.removeFile(manifest);
        vm.removeFile(proofs);
    }

    function _actions(
        address request,
        address underlying,
        uint256 amount,
        uint128 principal,
        uint128 minYield,
        uint48 duration
    ) private view returns (IMerkleAccount.Action[] memory actions) {
        actions = new IMerkleAccount.Action[](7);
        actions[0] = BaseAliasPayloads.approveBridge(amount);
        actions[1] = BaseAliasPayloads.bridgeToBase(_deployment, amount);
        actions[2] = BaseAliasPayloads.setMaxAssetsPerDuration(_deployment, underlying, amount, duration);
        actions[3] = BaseAliasPayloads.setMinYieldPerRequest(_deployment, underlying, amount);
        actions[4] = BaseAliasPayloads.mintThreeF(_deployment, request, principal, minYield);
        actions[5] = BaseAliasPayloads.redeemThreeF(_deployment, request);
        actions[6] = BaseAliasPayloads.bridgeToEthereum(_deployment, amount);
    }

    function _batch(IMerkleAccount.Action memory action) private view returns (bytes[] memory) {
        assertEq(action.target, BaseChain.BASE_PORTAL);
        assertEq(bytes4(action.data), IOptimismPortal.depositTransaction.selector);
        (address to, uint256 value, uint64 gasLimit, bool isCreation, bytes memory data) =
            abi.decode(action.data.slice(4), (address, uint256, uint64, bool, bytes));
        assertEq(to, _deployment.manager);
        assertEq(value, 0);
        assertEq(gasLimit, BaseChain.PORTAL_GAS_LIMIT);
        assertFalse(isCreation);
        assertEq(bytes4(data), Multicall.multicall.selector);
        return abi.decode(data.slice(4), (bytes[]));
    }

    function _assertExecute(bytes memory entry, address expectedTarget, bytes memory expectedData) private pure {
        assertEq(bytes4(entry), IAccessManager.execute.selector);
        (address target, bytes memory data) = abi.decode(entry.slice(4), (address, bytes));
        assertEq(target, expectedTarget);
        assertEq(data, expectedData);
    }
}

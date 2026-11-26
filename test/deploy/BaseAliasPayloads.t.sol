// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "script/base-chain/BaseChain.sol";
import {BaseAliasPayloads} from "script/base-chain/BaseAliasPayloads.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {BridgeUsdcFromBaseAliasBaseScript} from "script/actions/base-alias/base/BridgeUsdcFromBaseAliasBase.s.sol";
import {BridgeUsdcToBaseAliasBaseScript} from "script/actions/base-alias/base/BridgeUsdcToBaseAliasBase.s.sol";
import {MintThreeFFromAliasBaseScript} from "script/actions/base-alias/base/MintThreeFFromAliasBase.s.sol";
import {RedeemThreeFFromAliasBaseScript} from "script/actions/base-alias/base/RedeemThreeFFromAliasBase.s.sol";
import {
    ResetThreeFApprovalFromAliasBaseScript
} from "script/actions/base-alias/base/ResetThreeFApprovalFromAliasBase.s.sol";
import {
    SetThreeFMaxAssetsFromAliasBaseScript
} from "script/actions/base-alias/base/SetThreeFMaxAssetsFromAliasBase.s.sol";
import {
    SetThreeFMinYieldFromAliasBaseScript
} from "script/actions/base-alias/base/SetThreeFMinYieldFromAliasBase.s.sol";
import {
    SetThreeFRequestUnderlyingFromAliasScript
} from "script/actions/base-alias/SetThreeFRequestUnderlyingFromAlias.s.sol";
import {TestnetPermissions} from "script/deploy/testnet/TestnetPermissions.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IBaseAliasThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IBaseAliasThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Checks each action's proof against a fixed root like MerkleAccount.manage, then records the actions.
contract AliasAccountRecorder {
    bytes32 public root;
    uint256 public calls;
    IMerkleAccount.Action[] private _actions;

    error InvalidMerkleProof();

    /// @dev Stores the root that every action proof must reach.
    constructor(bytes32 newRoot) {
        root = newRoot;
    }

    /// @dev Verifies each action leaf against the root as MerkleAccount does, then records the actions.
    function manage(IMerkleAccount.Action[] calldata actions) public returns (bytes[] memory results) {
        delete _actions;
        for (uint256 i; i < actions.length; ++i) {
            if (!MerkleProof.verifyCalldata(actions[i].proof, root, BaseAliasPayloads.leaf(actions[i]))) {
                revert InvalidMerkleProof();
            }
            _actions.push(actions[i]);
        }
        ++calls;
        results = new bytes[](actions.length);
    }

    /// @dev Returns the calldata of the recorded action at `index`.
    function dataOf(uint256 index) public view returns (bytes memory) {
        return _actions[index].data;
    }

    /// @dev Returns the number of recorded actions in the last call.
    function count() public view returns (uint256) {
        return _actions.length;
    }
}

contract BaseAliasPayloadsTest is Test {
    BaseAliasPayloads.Deployment private _deployment;

    /// @dev Uses arbitrary deployment addresses; the payload builders only encode them.
    function setUp() public {
        _deployment =
            BaseAliasPayloads.Deployment({ethereumAccount: makeAddr("ethereum account"), policy: makeAddr("policy")});
    }

    /// @dev Runtime values sit only in masked bytes, so the executor's leaves equal the builder's templates.
    function testFuzz_LeavesIgnoreRuntimeValues(
        uint256 amount,
        address request,
        uint128 principal,
        uint128 yieldAssets,
        address underlyingAsset,
        uint48 duration
    ) public view {
        BaseAliasPayloads.Deployment memory deployment = _deployment;
        IMerkleAccount.Action[] memory runtime =
            _all(deployment, amount, request, principal, yieldAssets, underlyingAsset, duration);
        IMerkleAccount.Action[] memory templates = _all(deployment, 0, address(0), 0, 0, address(0), 0);
        for (uint256 i; i < runtime.length; ++i) {
            assertEq(BaseAliasPayloads.leaf(runtime[i]), BaseAliasPayloads.leaf(templates[i]));
        }
    }

    /// @dev The twelve leaves are distinct, so a role on one leaf never authorizes another.
    function test_LeavesAreDistinct() public view {
        IMerkleAccount.Action[] memory actions = _all(_deployment, 0, address(0), 0, 0, address(0), 0);
        for (uint256 i; i < actions.length; ++i) {
            for (uint256 j; j < i; ++j) {
                assertNotEq(BaseAliasPayloads.leaf(actions[i]), BaseAliasPayloads.leaf(actions[j]));
            }
        }
    }

    /// @dev The leaves pin the account (through its alias) and the policy.
    function test_LeavesPinDeployment() public view {
        BaseAliasPayloads.Deployment memory other =
            BaseAliasPayloads.Deployment({ethereumAccount: address(0xA11CE), policy: address(0xB0B)});
        IMerkleAccount.Action[] memory actions = _all(_deployment, 0, address(0), 0, 0, address(0), 0);
        IMerkleAccount.Action[] memory moved = _all(other, 0, address(0), 0, 0, address(0), 0);
        // approveBridge, approveThreeF, mintThreeF, resetThreeFApproval and approveBurn name no deployed address.
        bool[12] memory pinsDeployment = [false, true, true, true, true, false, false, false, true, false, true, true];
        for (uint256 i; i < actions.length; ++i) {
            assertEq(
                BaseAliasPayloads.leaf(actions[i]) != BaseAliasPayloads.leaf(moved[i]),
                pinsDeployment[i],
                vm.toString(i)
            );
        }
    }

    /// @dev Each leaf frees exactly its documented runtime words, and every other byte changes the leaf.
    function test_LeavesFreeOnlyTheirRuntimeWords() public view {
        IMerkleAccount.Action[] memory actions = _all(_deployment, 0, address(0), 0, 0, address(0), 0);
        uint8[12] memory free = [32, 32, 96, 64, 96, 64, 96, 32, 32, 32, 32, 64];
        for (uint256 i; i < actions.length; ++i) {
            _assertFreeBytes(actions[i], free[i]);
        }
    }

    /// @dev The deposits carry the documented Base calls from the alias, with the alias as maker and recipient.
    function test_DepositsCarryTheBaseCalls() public view {
        address l2Alias = BaseAliasPayloads.aliasOf(_deployment);
        address request = address(0x3F);
        (address to, bytes memory data) = _l2Call(BaseAliasPayloads.redeemThreeF(_deployment, request));
        assertEq(to, request);
        assertEq(data, abi.encodeWithSignature("burnAll(address,address)", l2Alias, l2Alias));
        (to, data) = _l2Call(BaseAliasPayloads.mintThreeF(request, 10e6, 1e6));
        assertEq(to, request);
        assertEq(data, abi.encodeCall(IThreeFPushRequest.mint, (10e6, 1e6)));
        IMerkleAccount.Action memory bridge = BaseAliasPayloads.bridgeToBase(_deployment, 1e6);
        assertEq(_word(bridge.data, 68), bytes32(uint256(uint160(l2Alias))));
    }

    /// @dev The recipe writes one request, principal and yield into the policy call and three deposits, whatever
    /// values the executor bot put in the runtime actions.
    function test_MintRecipeBindsOneSetOfValues() public {
        (RecipeExecutor executor, AliasAccountRecorder account, IMerkleAccount.Action[] memory actions) =
            _executor(100e6);
        address request = address(0x3F);
        IMerkleAccount.Action[] memory forged = BaseAliasPayloads.mintActions(_deployment, address(0xBAD), 1, 1);
        for (uint256 i; i < forged.length; ++i) {
            forged[i].proof = actions[i].proof;
        }
        _execute(executor, request, 10e6, 1e6, forged);
        assertEq(account.calls(), 1);
        assertEq(account.count(), 4);
        assertEq(account.dataOf(0), abi.encodeCall(IBaseAliasThreeFPolicy.consume, (request, 10e6, 1e6)));
        _assertDeposit(account.dataOf(1), BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, 10e6)));
        _assertDeposit(account.dataOf(2), request, abi.encodeCall(IThreeFPushRequest.mint, (10e6, 1e6)));
        _assertDeposit(account.dataOf(3), BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, 0)));
    }

    /// @dev The recipe refuses a zero principal, a principal above the cap and a yield above `uint128`.
    function test_MintRecipeRejectsOutOfRangeInputs() public {
        (RecipeExecutor executor,, IMerkleAccount.Action[] memory actions) = _executor(100e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(executor, address(0x3F), 0, 0, actions);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(executor, address(0x3F), 100e6 + 1, 1e6, actions);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(executor, address(0x3F), 10e6, uint256(type(uint128).max) + 1, actions);
    }

    /// @dev The recipe refuses actions in another order: each position only accepts its own leaf. Swapping the
    /// approval and the approval reset would leave the request approved after the mint.
    function test_MintRecipeRejectsReorderedDeposits() public {
        (RecipeExecutor executor,, IMerkleAccount.Action[] memory actions) = _executor(100e6);
        (actions[1], actions[3]) = (actions[3], actions[1]);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(executor, address(0x3F), 10e6, 1e6, actions);
    }

    /// @dev The cap must be nonzero and fit the `uint128` amounts of 3F `mint`.
    function test_MintRecipeRejectsInvalidCap() public {
        vm.expectRevert(BaseAliasPayloads.InvalidMaxPrincipal.selector);
        this.buildRecipe(0);
        vm.expectRevert(BaseAliasPayloads.InvalidMaxPrincipal.selector);
        this.buildRecipe(uint256(type(uint128).max) + 1);
    }

    /// @dev Builder templates, a proofs file keyed by leaf and the action scripts produce proofs that the account
    /// accepts; the mint script goes through the executor that holds the recipe.
    function test_ActionScriptsAttachProofsFromFile() public {
        vm.chainId(BaseChain.ETHEREUM_CHAIN_ID);
        IMerkleAccount.Action[] memory templates = _all(_deployment, 0, address(0), 0, 0, address(0), 0);
        (bytes32 root, bytes32[] memory leaves) = TestnetPermissions.authorize(templates);
        // Some leaves pin the account (through its alias), so put the recorder at the account address.
        vm.etch(_deployment.ethereumAccount, address(new AliasAccountRecorder(root)).code);
        vm.store(_deployment.ethereumAccount, bytes32(0), root);
        AliasAccountRecorder account = AliasAccountRecorder(_deployment.ethereumAccount);

        string memory manifest = "cache/base-alias-payloads-manifest.json";
        string memory proofs = "cache/base-alias-payloads-proofs.json";
        _writeManifest(manifest);
        string memory json;
        for (uint256 i; i < leaves.length; ++i) {
            json = vm.serializeBytes32("proofs", vm.toString(leaves[i]), templates[i].proof);
        }
        vm.writeJson(json, proofs);

        new BridgeUsdcToBaseAliasBaseScript().runBase(manifest, proofs, 5e6);
        new SetThreeFMaxAssetsFromAliasBaseScript().runBase(manifest, proofs, address(0xBEEF), 5e6, 1 days);
        new SetThreeFMinYieldFromAliasBaseScript().runBase(manifest, proofs, address(0xBEEF), 1);
        new SetThreeFRequestUnderlyingFromAliasScript().runBase(manifest, proofs, address(0x3F), address(0xBEEF));
        new RedeemThreeFFromAliasBaseScript().runBase(manifest, proofs, address(0x3F));
        new ResetThreeFApprovalFromAliasBaseScript().runBase(manifest, proofs, address(0x3F));
        new BridgeUsdcFromBaseAliasBaseScript().runBase(manifest, proofs, 5e6);

        RecipeExecutor executor = new RecipeExecutor(address(this), address(account));
        ExecutingRecipe.Recipe memory recipe = BaseAliasPayloads.mintRecipe(_deployment, 100e6);
        executor.setRecipe(recipe.queries, recipe.steps);
        executor.setCaller(DEFAULT_SENDER);
        MintThreeFFromAliasBaseScript mint = new MintThreeFFromAliasBaseScript();
        vm.expectRevert(MintThreeFFromAliasBaseScript.RecipeMismatch.selector);
        mint.runBase(manifest, proofs, address(executor), 50e6, address(0x3F), 10e6, 1e6);
        mint.runBase(manifest, proofs, address(executor), 100e6, address(0x3F), 10e6, 1e6);
        assertEq(account.calls(), 8);
        assertEq(account.count(), 4);
        vm.removeFile(manifest);
        vm.removeFile(proofs);
    }

    /// @dev Exposes the recipe builder as an external call so its revert can be expected.
    function buildRecipe(uint256 maxPrincipal) external view returns (ExecutingRecipe.Recipe memory) {
        return BaseAliasPayloads.mintRecipe(_deployment, maxPrincipal);
    }

    /// @dev Deploys an account recorder whose root holds the four mint leaves and an executor with the mint recipe
    /// for `maxPrincipal`. Returns the mint templates with their proofs.
    function _executor(uint256 maxPrincipal)
        private
        returns (RecipeExecutor executor, AliasAccountRecorder account, IMerkleAccount.Action[] memory actions)
    {
        actions = BaseAliasPayloads.mintActions(_deployment, address(0), 0, 0);
        (bytes32 root,) = TestnetPermissions.authorize(actions);
        account = new AliasAccountRecorder(root);
        executor = new RecipeExecutor(address(this), address(account));
        ExecutingRecipe.Recipe memory recipe = BaseAliasPayloads.mintRecipe(_deployment, maxPrincipal);
        executor.setRecipe(recipe.queries, recipe.steps);
        executor.setCaller(address(this));
    }

    /// @dev Runs the committed mint recipe with one set of inputs and the given runtime actions.
    function _execute(
        RecipeExecutor executor,
        address request,
        uint256 principal,
        uint256 yieldAssets,
        IMerkleAccount.Action[] memory actions
    ) private {
        ExecutingRecipe.Recipe memory recipe = BaseAliasPayloads.mintRecipe(_deployment, 100e6);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        executor.execute(
            recipe.queries, recipe.steps, BaseAliasPayloads.mintInputs(request, principal, yieldAssets), runtime
        );
    }

    /// @dev Returns the twelve alias actions in the leaf builder's order.
    function _all(
        BaseAliasPayloads.Deployment memory deployment,
        uint256 amount,
        address request,
        uint256 principal,
        uint256 yieldAssets,
        address underlyingAsset,
        uint48 duration
    ) private pure returns (IMerkleAccount.Action[] memory actions) {
        actions = new IMerkleAccount.Action[](12);
        actions[0] = BaseAliasPayloads.approveBridge(amount);
        actions[1] = BaseAliasPayloads.bridgeToBase(deployment, amount);
        actions[2] = BaseAliasPayloads.setMaxAssetsPerDuration(deployment, underlyingAsset, amount, duration);
        actions[3] = BaseAliasPayloads.setMinYieldPerRequest(deployment, underlyingAsset, amount);
        actions[4] = BaseAliasPayloads.consumeThreeF(deployment, request, principal, yieldAssets);
        actions[5] = BaseAliasPayloads.approveThreeF(request, principal);
        actions[6] = BaseAliasPayloads.mintThreeF(request, principal, yieldAssets);
        actions[7] = BaseAliasPayloads.resetThreeFApproval(request);
        actions[8] = BaseAliasPayloads.redeemThreeF(deployment, request);
        actions[9] = BaseAliasPayloads.approveBurn(amount);
        actions[10] = BaseAliasPayloads.bridgeToEthereum(deployment, amount);
        actions[11] = BaseAliasPayloads.setRequestUnderlying(deployment, request, underlyingAsset);
    }

    /// @dev Writes a minimal alias manifest with the fields the action scripts read.
    function _writeManifest(string memory path) private {
        vm.serializeUint("manifest", "chainId", BaseChain.BASE_CHAIN_ID);
        vm.serializeUint("manifest", "policyChainId", BaseChain.ETHEREUM_CHAIN_ID);
        vm.serializeString("manifest", "threeF", "");
        vm.serializeAddress("manifest", "alias", BaseAliasPayloads.aliasOf(_deployment));
        vm.writeJson(vm.serializeAddress("manifest", "ethereumAccount", _deployment.ethereumAccount), path);
        vm.writeJson(vm.serializeAddress("policy", "policy", _deployment.policy), path, ".threeF");
    }

    /// @dev Checks that a recorded portal action deposits `expected` to `to` with the fixed portal arguments.
    function _assertDeposit(bytes memory portal, address to, bytes memory expected) private pure {
        assertEq(
            portal,
            abi.encodeWithSignature(
                "depositTransaction(address,uint256,uint64,bool,bytes)",
                to,
                uint256(0),
                BaseChain.PORTAL_GAS_LIMIT,
                false,
                expected
            )
        );
    }

    /// @dev Checks that an action frees exactly `expected` bytes and that flipping any pinned byte changes its leaf.
    function _assertFreeBytes(IMerkleAccount.Action memory action, uint256 expected) private pure {
        uint256 free;
        for (uint256 i; i < action.dataMask.length; ++i) {
            if (action.dataMask[i] != 0) ++free;
        }
        assertEq(free, expected);
        bytes32 leaf = BaseAliasPayloads.leaf(action);
        for (uint256 i; i < action.data.length; ++i) {
            if (action.dataMask[i] != 0) continue;
            action.data[i] = bytes1(uint8(action.data[i]) ^ 1);
            assertNotEq(BaseAliasPayloads.leaf(action), leaf);
            action.data[i] = bytes1(uint8(action.data[i]) ^ 1);
        }
    }

    /// @dev Returns the L2 target and calldata carried by a portal deposit.
    function _l2Call(IMerkleAccount.Action memory action) private pure returns (address to, bytes memory data) {
        (to,,,, data) = abi.decode(_arguments(action.data), (address, uint256, uint64, bool, bytes));
    }

    /// @dev Reads one word of calldata.
    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 32), offset))
        }
    }

    /// @dev Returns calldata without its selector, for ABI decoding.
    function _arguments(bytes memory data) private pure returns (bytes memory arguments) {
        arguments = new bytes(data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = data[i + 4];
        }
    }
}

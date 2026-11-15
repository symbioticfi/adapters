// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL, SRC_INPUT} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ThreeFGuardedMint
 * @notice Library building the guarded leaf that charges ThreeFPolicy in the same sequence as the mint.
 * @dev The mask and the recipe's binding offsets are both derived here so they cannot drift apart.
 * The leaf pins the policy, funding asset and call sequence. Consume, approval and mint share the
 * principal and yield inputs. Native mint enforces its principal cap and yield floor; the policy
 * enforces request provenance and the collateral budget. The executor reads mintAuthorization and
 * binds both request occurrences. Grant the leaf only to that executor or a trusted curator.
 */
library ThreeFGuardedMint {
    /* ERRORS */

    /// @notice Raised when a sentinel amount is absent from the encoded payload.
    error SentinelNotFound();

    /* CONSTANTS */

    /// @dev Byte offsets of consume's two amount words: selector plus request.
    uint256 internal constant ASSETS_ARGUMENT = 36;
    uint256 internal constant YIELD_ARGUMENT = 68;

    uint256 private constant _ASSETS = uint256(keccak256("ThreeFGuardedMint.assets"));
    uint256 private constant _YIELD = uint256(keccak256("ThreeFGuardedMint.yieldAssets"));

    /* STRUCTS */

    /**
     * @notice Fixed funding asset and policy, plus the default runtime request.
     * @param asset Funding token approved for minting.
     * @param policy ThreeFPolicy charged by the sequence; only the bound account can consume it.
     * @param request Default native 3F request; the executor binds its runtime address.
     * @param resetApproval Whether the funding token needs a zero approval before a nonzero approval.
     */
    struct Config {
        address asset;
        address policy;
        address request;
        bool resetApproval;
    }

    /**
     * @notice Encoded guarded call with its mask and the byte offsets of its variable words.
     * @dev The offsets are strictly ascending, as RecipeExecutor bindings require.
     */
    struct Leaf {
        bytes data;
        bytes dataMask;
        uint256 assets;
        uint256 yieldAssets;
        uint256[] requestOffsets;
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Builds the guarded `execute` payload, its mask and its variable-word offsets.
    function build(Config memory config) internal pure returns (Leaf memory leaf) {
        uint256 request = uint160(uint256(keccak256("ThreeFGuardedMint.request")));
        uint256 reset = config.resetApproval ? 1 : 0;
        bytes[] memory steps = new bytes[](4 + reset);
        uint256[] memory callBindings = new uint256[](3);
        callBindings[0] = ExecutingRecipe.binding(4, _input(2));
        callBindings[1] = ExecutingRecipe.binding(ASSETS_ARGUMENT, _input(0));
        callBindings[2] = ExecutingRecipe.binding(YIELD_ARGUMENT, _input(1));
        steps[0] = abi.encodePacked(
            OP_CALL,
            abi.encode(
                config.policy, abi.encodeCall(IThreeFPolicy.consume, (address(0), uint256(0), uint256(0))), callBindings
            )
        );
        callBindings = new uint256[](1);
        callBindings[0] = ExecutingRecipe.binding(4, _input(2));
        steps[3 + reset] = abi.encodePacked(
            OP_CALL, abi.encode(config.asset, abi.encodeCall(IERC20.approve, (address(0), uint256(0))), callBindings)
        );
        if (config.resetApproval) steps[1] = steps[3 + reset];
        callBindings = new uint256[](2);
        callBindings[0] = ExecutingRecipe.binding(4, _input(2));
        callBindings[1] = ExecutingRecipe.binding(36, _input(0));
        steps[1 + reset] = abi.encodePacked(
            OP_CALL, abi.encode(config.asset, abi.encodeCall(IERC20.approve, (address(0), uint256(0))), callBindings)
        );
        callBindings[0] = ExecutingRecipe.binding(4, _input(0));
        callBindings[1] = ExecutingRecipe.binding(36, _input(1));
        steps[2 + reset] = abi.encodePacked(
            OP_CALL,
            abi.encode(
                address(uint160(request)),
                abi.encodeCall(IThreeFPushRequest.mint, (uint128(0), uint128(0))),
                callBindings
            )
        );
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = _ASSETS;
        inputs[1] = _YIELD;
        inputs[2] = request;
        leaf.data = abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, inputs));
        leaf.assets = _find(leaf.data, bytes32(_ASSETS));
        leaf.yieldAssets = _find(leaf.data, bytes32(_YIELD));
        leaf.dataMask = new bytes(leaf.data.length);
        _mask(leaf.dataMask, leaf.assets);
        _mask(leaf.dataMask, leaf.yieldAssets);
        uint256 length = leaf.data.length;
        leaf.requestOffsets = new uint256[](2);
        uint256 requestIndex;
        for (uint256 i; i + 32 <= length; ++i) {
            bytes32 word;
            bytes memory data = leaf.data;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), i))
            }
            if (word != bytes32(request)) continue;
            leaf.requestOffsets[requestIndex++] = i;
            _mask(leaf.dataMask, i);
            write(leaf.data, i, uint160(config.request));
        }
        if (requestIndex != leaf.requestOffsets.length) revert SentinelNotFound();
    }

    /// @notice Binds every request occurrence and all charged and minted amounts in ascending offset order.
    function bindings(Leaf memory leaf, uint256 assets, uint256 yieldAssets, uint256 request)
        internal
        pure
        returns (uint256[] memory values)
    {
        uint256 length = leaf.requestOffsets.length;
        values = new uint256[](length + 2);
        for (uint256 i; i < length; ++i) {
            values[i] = ExecutingRecipe.binding(leaf.requestOffsets[i], request);
        }
        values[length] = ExecutingRecipe.binding(leaf.assets, assets);
        values[length + 1] = ExecutingRecipe.binding(leaf.yieldAssets, yieldAssets);
        for (uint256 i = 1; i < values.length; ++i) {
            uint256 value = values[i];
            uint256 j = i;
            while (j > 0 && values[j - 1] > value) {
                values[j] = values[j - 1];
                --j;
            }
            values[j] = value;
        }
    }

    /// @notice Writes one complete word into an encoded payload, for callers submitting the action directly.
    function write(bytes memory data, uint256 offset, uint256 value) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), value)
        }
    }

    /* PRIVATE FUNCTIONS */

    function _input(uint216 index) private pure returns (uint256) {
        return uint256(SRC_INPUT) << 216 | index;
    }

    /// @dev Locates a sentinel word; masked bytes are zeroed by the leaf hash, so its value never binds.
    function _find(bytes memory data, bytes32 sentinel) private pure returns (uint256) {
        uint256 length = data.length;
        for (uint256 i; i + 32 <= length; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), i))
            }
            if (word == sentinel) return i;
        }
        revert SentinelNotFound();
    }

    function _mask(bytes memory dataMask, uint256 offset) private pure {
        for (uint256 i = offset; i < offset + 32; ++i) {
            dataMask[i] = 0xff;
        }
    }
}

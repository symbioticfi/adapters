// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {
    OP_CALL,
    OP_EQUAL,
    OP_READ,
    OP_READ_CACHED,
    OP_READ_WORD,
    OP_SUB,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ThreeFGuardedMint
 * @notice Library building the guarded leaf that charges ThreeFPolicy in the same sequence as the mint.
 * @dev The mask and the recipe's binding offsets are both derived here so they cannot drift apart.
 * The leaf pins the policy, funding asset, request and every check; only the four amount words vary.
 * Those words are bound to the observed principal, yield and cash movements, so an understated
 * charge reverts the whole sequence. Offsets are located by searching for sentinel values rather
 * than computed by hand, because they sit inside a nested ABI encoding.
 */
library ThreeFGuardedMint {
    /* ERRORS */

    /// @notice Raised when a sentinel amount is absent from the encoded payload.
    error SentinelNotFound();

    /* CONSTANTS */

    /// @dev Byte offsets of consume's two amount words within its own calldata: selector plus request.
    uint256 internal constant ASSETS_ARGUMENT = 36;
    uint256 internal constant YIELD_ARGUMENT = 68;

    uint256 private constant _ASSETS = uint256(keccak256("ThreeFGuardedMint.assets"));
    uint256 private constant _YIELD = uint256(keccak256("ThreeFGuardedMint.yieldAssets"));
    uint128 private constant _PRINCIPAL = uint128(uint256(keccak256("ThreeFGuardedMint.principal")));
    uint128 private constant _MINT_YIELD = uint128(uint256(keccak256("ThreeFGuardedMint.mintYield")));

    /* STRUCTS */

    /**
     * @notice Addresses the leaf pins; none of them can vary at execution time.
     * @param account Custody address holding the PT/YT and the funding cash.
     * @param asset Funding token whose cash debit is verified after minting.
     * @param policy ThreeFPolicy charged by the sequence; the account must be its sole consumer.
     * @param request Native 3F request that is minted and queried for share balances.
     */
    struct Config {
        address account;
        address asset;
        address policy;
        address request;
    }

    /**
     * @notice Encoded guarded call with its mask and the byte offsets of its four variable words.
     * @dev The offsets are strictly ascending, as RecipeExecutor bindings require.
     */
    struct Leaf {
        bytes data;
        bytes dataMask;
        uint256 consumeAssets;
        uint256 consumeYield;
        uint256 mintPrincipal;
        uint256 mintYield;
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Builds the guarded `execute` payload, its mask and its variable-word offsets.
    function build(Config memory config) internal pure returns (Leaf memory leaf) {
        return build(config, false);
    }

    /// @dev Optionally extracts PT/YT from one call per snapshot.
    function build(Config memory config, bool reuseTupleReads) internal pure returns (Leaf memory leaf) {
        bytes[] memory queries = new bytes[](reuseTupleReads ? 2 : 3);
        queries[0] = _query(config.request, abi.encodeCall(IThreeFVaultController.balancesOf, (config.account)), 0);
        if (!reuseTupleReads) {
            queries[1] = _query(config.request, abi.encodeCall(IThreeFVaultController.balancesOf, (config.account)), 32);
        }
        queries[reuseTupleReads ? 1 : 2] = _query(config.asset, abi.encodeCall(IERC20.balanceOf, (config.account)), 0);
        bytes[] memory steps = new bytes[](14);
        steps[0] = reuseTupleReads ? abi.encodePacked(OP_READ_CACHED, abi.encode(uint256(0))) : _read(0);
        steps[1] = reuseTupleReads ? abi.encodePacked(OP_READ_WORD, abi.encode(uint256(0), uint256(32))) : _read(1);
        steps[2] = _read(reuseTupleReads ? 1 : 2);
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = ExecutingRecipe.binding(ASSETS_ARGUMENT, _input(0));
        bindings[1] = ExecutingRecipe.binding(YIELD_ARGUMENT, _input(1));
        steps[3] = abi.encodePacked(
            OP_CALL,
            abi.encode(
                config.policy, abi.encodeCall(IThreeFPolicy.consume, (config.request, uint256(0), uint256(0))), bindings
            )
        );
        bindings[0] = ExecutingRecipe.binding(4, _input(2));
        bindings[1] = ExecutingRecipe.binding(36, _input(3));
        steps[4] = abi.encodePacked(
            OP_CALL,
            abi.encode(config.request, abi.encodeCall(IThreeFPushRequest.mint, (uint128(0), uint128(0))), bindings)
        );
        steps[5] = steps[0];
        steps[6] = reuseTupleReads ? abi.encodePacked(OP_READ_WORD, abi.encode(uint256(5), uint256(32))) : _read(1);
        steps[7] = steps[2];
        steps[8] = _binary(OP_SUB, _result(5), _result(0));
        steps[9] = _binary(OP_EQUAL, _result(8), _input(0));
        steps[10] = _binary(OP_SUB, _result(6), _result(1));
        steps[11] = _binary(OP_EQUAL, _result(10), _input(1));
        steps[12] = _binary(OP_SUB, _result(2), _result(7));
        steps[13] = _binary(OP_EQUAL, _result(12), _input(0));
        uint256[] memory inputs = new uint256[](4);
        inputs[0] = _ASSETS;
        inputs[1] = _YIELD;
        inputs[2] = _PRINCIPAL;
        inputs[3] = _MINT_YIELD;
        leaf.data = abi.encodeCall(IRecipeCapability.execute, (queries, steps, inputs));
        leaf.consumeAssets = _find(leaf.data, bytes32(_ASSETS));
        leaf.consumeYield = _find(leaf.data, bytes32(_YIELD));
        leaf.mintPrincipal = _find(leaf.data, bytes32(uint256(_PRINCIPAL)));
        leaf.mintYield = _find(leaf.data, bytes32(uint256(_MINT_YIELD)));
        leaf.dataMask = new bytes(leaf.data.length);
        _mask(leaf.dataMask, leaf.consumeAssets);
        _mask(leaf.dataMask, leaf.consumeYield);
        _mask(leaf.dataMask, leaf.mintPrincipal);
        _mask(leaf.dataMask, leaf.mintYield);
    }

    /// @notice Writes one complete word into an encoded payload, for callers submitting the action directly.
    function write(bytes memory data, uint256 offset, uint256 value) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), value)
        }
    }

    /* PRIVATE FUNCTIONS */

    function _query(address target, bytes memory data, uint256 offset) private pure returns (bytes memory) {
        return abi.encode(target, data, new uint256[](0), offset);
    }

    function _read(uint256 query) private pure returns (bytes memory) {
        return abi.encodePacked(OP_READ, abi.encode(query));
    }

    function _binary(uint8 operation, uint256 a, uint256 b) private pure returns (bytes memory) {
        return abi.encodePacked(operation, abi.encode(a, b));
    }

    function _result(uint216 index) private pure returns (uint256) {
        return uint256(SRC_RESULT) << 216 | index;
    }

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

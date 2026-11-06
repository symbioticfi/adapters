// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL, OP_EQUAL, OP_READ, OP_SUB, SRC_INPUT, SRC_RESULT} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFRequest} from "src/interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ThreeFGuardedMint
 * @notice Library building the guarded leaf that charges ThreeFPolicy in the same sequence as the mint.
 * @dev The mask and the recipe's binding offsets are both derived here so they cannot drift apart.
 * The leaf pins the policy, funding asset and every check. The committed executor binds every request target and
 * argument to the same source; the policy resolves and charges the request collateral budget dynamically.
 * Those words are bound to the observed principal, yield and cash movements, so an understated
 * charge reverts the whole sequence. Offsets are located by searching for sentinel values rather
 * than computed by hand, because they sit inside a nested ABI encoding. Grant the masked leaf role
 * only to the committed executor or a trusted curator: the executor enforces equality of request slots.
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
    uint128 private constant _PRINCIPAL = uint128(uint256(keccak256("ThreeFGuardedMint.principal")));
    uint128 private constant _MINT_YIELD = uint128(uint256(keccak256("ThreeFGuardedMint.mintYield")));

    /* STRUCTS */

    /**
     * @notice Fixed account, funding asset and policy, plus the default runtime request.
     * @param account Custody address holding the PT/YT and the funding cash.
     * @param asset Funding token whose cash debit is verified after minting.
     * @param policy ThreeFPolicy charged by the sequence; only the bound account can consume it.
     * @param request Native 3F request that is minted and queried for share balances.
     * @param resetApproval Whether the funding token needs a zero approval before a nonzero approval.
     */
    struct Config {
        address account;
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
        uint256 consumeAssets;
        uint256 consumeYield;
        uint256 mintPrincipal;
        uint256 mintYield;
        uint256[] requestOffsets;
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Builds the guarded `execute` payload, its mask and its variable-word offsets.
    function build(Config memory config) internal pure returns (Leaf memory leaf) {
        uint256 request = uint160(uint256(keccak256("ThreeFGuardedMint.request")));
        bytes[] memory queries = new bytes[](7);
        queries[0] = _query(request, abi.encodeCall(IThreeFVaultController.balancesOf, (config.account)), 0);
        queries[1] = _query(request, abi.encodeCall(IThreeFVaultController.balancesOf, (config.account)), 32);
        queries[2] = _query(uint160(config.asset), abi.encodeCall(IERC20.balanceOf, (config.account)), 0);
        queries[3] = _query(request, abi.encodeCall(IThreeFRequest.asset, ()), 0);
        uint256[] memory callBindings = new uint256[](1);
        callBindings[0] = ExecutingRecipe.binding(36, _input(4));
        queries[4] = abi.encode(
            config.asset, abi.encodeCall(IERC20.allowance, (config.account, address(0))), callBindings, uint256(0)
        );
        queries[5] = _query(request, abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.account)), 0);
        queries[6] = _query(request, abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.account)), 32);
        uint256 reset = config.resetApproval ? 1 : 0;
        bytes[] memory steps = new bytes[](26 + reset);
        steps[0] = _read(3);
        steps[1] = _binary(OP_EQUAL, _result(0), uint160(config.asset));
        steps[2] = _read(5);
        steps[3] = _binary(OP_EQUAL, _result(2), _input(0));
        steps[4] = _read(6);
        steps[5] = _binary(OP_EQUAL, _result(4), _input(1));
        steps[6] = _read(0);
        steps[7] = _read(1);
        steps[8] = _read(2);
        callBindings = new uint256[](3);
        callBindings[0] = ExecutingRecipe.binding(4, _input(4));
        callBindings[1] = ExecutingRecipe.binding(ASSETS_ARGUMENT, _input(0));
        callBindings[2] = ExecutingRecipe.binding(YIELD_ARGUMENT, _input(1));
        steps[9] = abi.encodePacked(
            OP_CALL,
            abi.encode(
                config.policy, abi.encodeCall(IThreeFPolicy.consume, (address(0), uint256(0), uint256(0))), callBindings
            )
        );
        callBindings = new uint256[](1);
        callBindings[0] = ExecutingRecipe.binding(4, _input(4));
        steps[14 + reset] = abi.encodePacked(
            OP_CALL, abi.encode(config.asset, abi.encodeCall(IERC20.approve, (address(0), uint256(0))), callBindings)
        );
        if (config.resetApproval) steps[10] = steps[14 + reset];
        callBindings = new uint256[](2);
        callBindings[0] = ExecutingRecipe.binding(4, _input(4));
        callBindings[1] = ExecutingRecipe.binding(36, _input(0));
        steps[10 + reset] = abi.encodePacked(
            OP_CALL, abi.encode(config.asset, abi.encodeCall(IERC20.approve, (address(0), uint256(0))), callBindings)
        );
        steps[11 + reset] = _read(4);
        steps[12 + reset] = _binary(OP_EQUAL, _result(uint216(11 + reset)), _input(0));
        callBindings[0] = ExecutingRecipe.binding(4, _input(2));
        callBindings[1] = ExecutingRecipe.binding(36, _input(3));
        steps[13 + reset] = abi.encodePacked(
            OP_CALL,
            abi.encode(
                address(uint160(request)),
                abi.encodeCall(IThreeFPushRequest.mint, (uint128(0), uint128(0))),
                callBindings
            )
        );
        steps[15 + reset] = _read(4);
        steps[16 + reset] = _binary(OP_EQUAL, _result(uint216(15 + reset)), 0);
        steps[17 + reset] = _read(0);
        steps[18 + reset] = _read(1);
        steps[19 + reset] = _read(2);
        steps[20 + reset] = _binary(OP_SUB, _result(uint216(17 + reset)), _result(6));
        steps[21 + reset] = _binary(OP_EQUAL, _result(uint216(20 + reset)), _input(0));
        steps[22 + reset] = _binary(OP_SUB, _result(uint216(18 + reset)), _result(7));
        steps[23 + reset] = _binary(OP_EQUAL, _result(uint216(22 + reset)), _input(1));
        steps[24 + reset] = _binary(OP_SUB, _result(8), _result(uint216(19 + reset)));
        steps[25 + reset] = _binary(OP_EQUAL, _result(uint216(24 + reset)), _input(0));
        uint256[] memory inputs = new uint256[](5);
        inputs[0] = _ASSETS;
        inputs[1] = _YIELD;
        inputs[2] = _PRINCIPAL;
        inputs[3] = _MINT_YIELD;
        inputs[4] = request;
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
        uint256 length = leaf.data.length;
        leaf.requestOffsets = new uint256[](7);
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
        values = new uint256[](length + 4);
        for (uint256 i; i < length; ++i) {
            values[i] = ExecutingRecipe.binding(leaf.requestOffsets[i], request);
        }
        values[length] = ExecutingRecipe.binding(leaf.consumeAssets, assets);
        values[length + 1] = ExecutingRecipe.binding(leaf.consumeYield, yieldAssets);
        values[length + 2] = ExecutingRecipe.binding(leaf.mintPrincipal, assets);
        values[length + 3] = ExecutingRecipe.binding(leaf.mintYield, yieldAssets);
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

    function _query(uint256 target, bytes memory data, uint256 offset) private pure returns (bytes memory) {
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

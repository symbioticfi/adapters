// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {
    OP_APPROVE,
    OP_CALL,
    OP_CALL_IF,
    OP_CLEAR_APPROVAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_MUL_DIV,
    OP_READ,
    OP_READ_CACHED,
    OP_READ_IF,
    OP_READ_WORD,
    SRC_INPUT,
    SRC_LITERAL,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";

import {Vm} from "forge-std/Vm.sol";

/**
 * @title RecipeManifest
 * @notice Library for rendering committed recipe bytes as a readable offchain JSON manifest.
 * @dev Operand values are decimal strings to retain precision in JSON consumers. Input and result values
 * describe references, not resolved execution amounts. Required opcodes describe the encoded recipe only;
 * this manifest does not verify deployed executor compatibility, permissions or external protocol behavior.
 */
library RecipeManifest {
    /* ERRORS */

    /**
     * @notice Raised when an instruction or operand source cannot be represented by the manifest schema.
     */
    error InvalidManifest();

    /* CONSTANTS */

    address private constant _VM = address(uint160(uint256(keccak256("hevm cheat code"))));

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Renders the recipe's queries, instructions, runtime slots and required opcodes.
     * @dev The snapshot records the build context. parentBlockHash identifies the preceding block because
     * the current block hash is unavailable during its execution. Nested capability recipes use this same API.
     */
    function render(ExecutingRecipe.Recipe memory recipe) internal view returns (string memory manifest) {
        string[17] memory names = [
            "Read",
            "Add",
            "Sub",
            "SaturatingSub",
            "Min",
            "Max",
            "MulDiv",
            "Equal",
            "LessOrEqual",
            "Manage",
            "Approve",
            "Call",
            "ReadIf",
            "ClearApproval",
            "ReadCached",
            "ReadWord",
            "CallIf"
        ];
        string memory queries = "[";
        uint256 queriesLength = recipe.queries.length;
        for (uint256 i; i < queriesLength; ++i) {
            (address target, bytes memory data, uint256[] memory bindings, uint256 offset) =
                abi.decode(recipe.queries[i], (address, bytes, uint256[], uint256));
            queries = string.concat(
                queries,
                i > 0 ? "," : "",
                '{"index":',
                _number(i),
                ',"target":"',
                Vm(_VM).toString(target),
                '","calldata":"',
                Vm(_VM).toString(data),
                '","returnOffset":',
                _number(offset),
                ',"bindings":',
                _bindings(bindings),
                "}"
            );
        }
        bool[17] memory used;
        uint256 runtimeSlot;
        string memory instructions = "[";
        uint256 stepsLength = recipe.steps.length;
        for (uint256 i; i < stepsLength; ++i) {
            if (recipe.steps[i].length == 0) revert InvalidManifest();
            uint8 operation = uint8(recipe.steps[i][0]);
            if (operation > OP_CALL_IF) revert InvalidManifest();
            used[operation] = true;
            instructions = string.concat(
                instructions,
                i > 0 ? "," : "",
                '{"index":',
                _number(i),
                ',"code":',
                _number(operation),
                ',"opcode":"',
                names[operation],
                '"',
                _payload(operation, Bytes.slice(recipe.steps[i], 1))
            );
            if (operation == OP_MANAGE || operation == OP_APPROVE || operation == OP_CLEAR_APPROVAL) {
                instructions = string.concat(instructions, ',"runtimeSlot":', _number(runtimeSlot++));
            }
            instructions = string.concat(instructions, "}");
        }
        string memory required = "[";
        bool comma;
        for (uint256 i; i < names.length; ++i) {
            if (!used[i]) continue;
            required = string.concat(required, comma ? "," : "", '{"code":', _number(i), ',"name":"', names[i], '"}');
            comma = true;
        }
        manifest = string.concat(
            '{"schemaVersion":1,"recipeHash":"',
            Vm(_VM).toString(keccak256(abi.encode(recipe.queries, recipe.steps))),
            '","snapshot":{"chainId":',
            _number(block.chainid),
            ',"blockNumber":',
            _number(block.number),
            ',"parentBlockHash":"',
            Vm(_VM).toString(block.number > 0 ? blockhash(block.number - 1) : bytes32(0)),
            '"},"requiredOpcodes":',
            required,
            '],"queries":',
            queries,
            '],"instructions":',
            instructions,
            "]}"
        );
    }

    /* PRIVATE FUNCTIONS */

    function _payload(uint8 operation, bytes memory data) private pure returns (string memory) {
        if (operation == OP_READ || operation == OP_READ_CACHED) {
            return string.concat(',"queryIndex":', _number(abi.decode(data, (uint256))));
        }
        if (operation == OP_READ_WORD) {
            (uint256 producer, uint256 offset) = abi.decode(data, (uint256, uint256));
            return string.concat(',"producerIndex":', _number(producer), ',"returnOffset":', _number(offset));
        }
        if (operation == OP_READ_IF) {
            (uint256 gate, uint256 queryIndex, uint256 fallbackValue) = abi.decode(data, (uint256, uint256, uint256));
            return string.concat(
                ',"gate":',
                _operand(gate),
                ',"queryIndex":',
                _number(queryIndex),
                ',"fallback":',
                _operand(fallbackValue)
            );
        }
        if (operation <= OP_LESS_OR_EQUAL) {
            if (operation == OP_MUL_DIV) {
                (uint256 a, uint256 b, uint256 denominator) = abi.decode(data, (uint256, uint256, uint256));
                return
                    string.concat(',"a":', _operand(a), ',"b":', _operand(b), ',"denominator":', _operand(denominator));
            }
            (uint256 a, uint256 b) = abi.decode(data, (uint256, uint256));
            return string.concat(',"a":', _operand(a), ',"b":', _operand(b));
        }
        if (operation == OP_CALL || operation == OP_CALL_IF) {
            uint256 gate;
            address target;
            bytes memory callData;
            uint256[] memory bindings;
            if (operation == OP_CALL_IF) {
                (gate, target, callData, bindings) = abi.decode(data, (uint256, address, bytes, uint256[]));
            } else {
                (target, callData, bindings) = abi.decode(data, (address, bytes, uint256[]));
            }
            return string.concat(
                operation == OP_CALL_IF ? string.concat(',"gate":', _operand(gate)) : "",
                ',"target":"',
                Vm(_VM).toString(target),
                '","calldata":"',
                Vm(_VM).toString(callData),
                '","bindings":',
                _bindings(bindings)
            );
        }
        if (operation == OP_MANAGE) {
            (uint256 gate, bytes32[] memory leaves, uint256[][] memory bindings) =
                abi.decode(data, (uint256, bytes32[], uint256[][]));
            if (leaves.length != bindings.length) revert InvalidManifest();
            string memory groups = "[";
            uint256 length = leaves.length;
            for (uint256 i; i < length; ++i) {
                groups = string.concat(
                    groups,
                    i > 0 ? "," : "",
                    '{"leaf":"',
                    Vm(_VM).toString(leaves[i]),
                    '","bindings":',
                    _bindings(bindings[i]),
                    "}"
                );
            }
            return string.concat(',"gate":', _operand(gate), ',"groups":', groups, "]");
        }
        address token;
        address spender;
        bytes32 leaf;
        string memory amount;
        if (operation == OP_APPROVE) {
            uint256 operand;
            (operand, token, spender, leaf) = abi.decode(data, (uint256, address, address, bytes32));
            amount = string.concat(',"amount":', _operand(operand));
        } else {
            (token, spender, leaf) = abi.decode(data, (address, address, bytes32));
        }
        return string.concat(
            amount,
            ',"token":"',
            Vm(_VM).toString(token),
            '","spender":"',
            Vm(_VM).toString(spender),
            '","leaf":"',
            Vm(_VM).toString(leaf),
            '"'
        );
    }

    function _bindings(uint256[] memory bindings) private pure returns (string memory rendered) {
        rendered = "[";
        uint256 length = bindings.length;
        for (uint256 i; i < length; ++i) {
            rendered = string.concat(
                rendered,
                i > 0 ? "," : "",
                '{"offset":',
                _number(bindings[i] >> 224),
                ',"operand":',
                _operand(bindings[i]),
                "}"
            );
        }
        return string.concat(rendered, "]");
    }

    function _operand(uint256 operand) private pure returns (string memory) {
        uint8 source = uint8(operand >> 216);
        if (source != SRC_LITERAL && source != SRC_INPUT && source != SRC_RESULT) revert InvalidManifest();
        return string.concat(
            '{"source":"',
            source == SRC_LITERAL ? "Literal" : source == SRC_INPUT ? "Input" : "Result",
            '","value":"',
            _number(uint216(operand)),
            '"}'
        );
    }

    function _number(uint256 value) private pure returns (string memory) {
        return Vm(_VM).toString(value);
    }
}

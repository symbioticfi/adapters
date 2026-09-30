// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {RecipeManifest} from "script/recipes/RecipeManifest.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_ADD, OP_MANAGE} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract RecipeInspectTest is Test {
    using stdJson for string;
    using ExecutingRecipe for ExecutingRecipe.Builder;

    address internal _builder;
    string internal _inputPath = "out/RecipeInspect.input.json";
    string internal _outputPath = "out/RecipeInspect.output.json";

    function setUp() public {
        _builder = deployCode("BuildRecipe.s.sol:BuildRecipe");
    }

    function test_ManifestCommitsToExactRecipeBytes() public view {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.instruction(OP_ADD, abi.encode(uint256(2), uint256(3)));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        string memory manifest = RecipeManifest.render(recipe);
        assertTrue(manifest.keyExists(".recipeHash"), "Manifest is not bound to its recipe");
        assertEq(manifest.readBytes32(".recipeHash"), keccak256(abi.encode(recipe.queries, recipe.steps)));
    }

    function test_InspectSavedArtifactPreservesBytesAndMetadata() public {
        _paths("SavedArtifactPreservesBytesAndMetadata");
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.instruction(OP_ADD, abi.encode(uint256(2), uint256(3)));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        bytes memory encoded = abi.encode(recipe.queries, recipe.steps);
        bytes memory setRecipe = abi.encodeCall(IRecipeExecutor.setRecipe, (recipe.queries, recipe.steps));
        vm.serializeJson(_inputPath, '{"operatorNote":"existing automation","manifest":{"schemaVersion":99}}');
        vm.serializeBytes(_inputPath, "recipe", encoded);
        vm.serializeBytes(_inputPath, "setRecipeCalldata", setRecipe);
        vm.writeJson(vm.serializeBytes32(_inputPath, "recipeHash", keccak256(encoded)), _inputPath);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        string memory output = vm.readFile(_outputPath);
        assertEq(output.readBytes(".recipe"), encoded);
        assertEq(output.readBytes(".setRecipeCalldata"), setRecipe);
        assertEq(output.readString(".operatorNote"), "existing automation");
        assertEq(output.readString(".manifestContext"), "inspection");
        assertEq(output.readUint(".manifest.schemaVersion"), 1);
        assertEq(output.readBytes32(".manifest.recipeHash"), keccak256(encoded));
        assertEq(output.readString(".manifest.instructions[0].opcode"), "Add");
        assertEq(output.readString(".manifest.instructions[0].a.value"), "2");
        assertEq(output.readString(".manifest.instructions[0].b.value"), "3");
        assertEq(output.readUint(".stepCount"), 1);
        assertFalse(output.keyExists(".runtimeSteps[0]"));
    }

    function test_InspectPackedArraysSupportsExistingEventExportsInPlace() public {
        _paths("PackedArraysSupportsExistingEventExportsInPlace");
        bytes[] memory queries = new bytes[](0);
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(7), uint256(8)));
        vm.serializeJson(_inputPath, "{}");
        vm.serializeBytes(_inputPath, "queries", queries);
        vm.writeJson(vm.serializeBytes(_inputPath, "steps", steps), _inputPath);
        BuildRecipe(_builder).inspect(_inputPath, _inputPath);
        string memory output = vm.readFile(_inputPath);
        assertEq(output.readBytes(".recipe"), abi.encode(queries, steps));
        assertEq(output.readBytes32(".recipeHash"), keccak256(abi.encode(queries, steps)));
        assertEq(output.readString(".manifest.instructions[0].a.value"), "7");
        assertEq(output.readString(".manifest.instructions[0].b.value"), "8");
    }

    function test_InspectRejectsMismatchedHashWithoutReplacingOutput() public {
        _paths("RejectsMismatchedHashWithoutReplacingOutput");
        _writeEmptyRecipe();
        vm.writeJson(string.concat('"', vm.toString(bytes32(uint256(1))), '"'), _inputPath, ".recipeHash");
        vm.writeFile(_outputPath, "unchanged");
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertEq(vm.readFile(_outputPath), "unchanged");
    }

    function test_InspectRejectsMismatchedConfigurationCalldata() public {
        _paths("RejectsMismatchedConfigurationCalldata");
        _writeEmptyRecipe();
        vm.writeJson('"0x12345678"', _inputPath, ".setRecipeCalldata");
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function test_InspectRejectsConflictingEncodedAndArrayRecipes() public {
        _paths("RejectsConflictingEncodedAndArrayRecipes");
        bytes[] memory empty = new bytes[](0);
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(1), uint256(2)));
        vm.writeFile(
            _inputPath,
            string.concat(
                '{"recipe":"',
                vm.toString(abi.encode(empty, empty)),
                '","queries":[],"steps":["',
                vm.toString(steps[0]),
                '"]}'
            )
        );
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function test_InspectRendersCommittedGuardedLeaf() public {
        _paths("RendersCommittedGuardedLeaf");
        _writeGuardedRecipe();
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        string memory output = vm.readFile(_outputPath);
        assertEq(output.readString(".guardedMintManifest.instructions[0].opcode"), "Add");
        assertEq(output.readString(".guardedMintManifest.instructions[0].a.value"), "4");
        assertEq(output.readUint(".guardedMintManifest.schemaVersion"), 1);
        assertEq(output.readString(".manifest.instructions[0].opcode"), "Manage");
    }

    function test_InspectRejectsGuardedLeafWithWrongSelector() public {
        _paths("RejectsGuardedLeafWithWrongSelector");
        _writeGuardedRecipe();
        vm.writeJson('"0x12345678"', _inputPath, ".mintLeafData");
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function test_InspectRejectsMismatchedGuardedLeafHash() public {
        _paths("RejectsMismatchedGuardedLeafHash");
        _writeGuardedRecipe();
        vm.writeJson(string.concat('"', vm.toString(bytes32(uint256(1))), '"'), _inputPath, ".mintLeafHash");
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function test_InspectRejectsUnknownInstructionBeforeWriting() public {
        _paths("RejectsUnknownInstructionBeforeWriting");
        bytes[] memory queries = new bytes[](0);
        bytes[] memory steps = new bytes[](1);
        steps[0] = hex"ff";
        vm.writeFile(_inputPath, string.concat('{"recipe":"', vm.toString(abi.encode(queries, steps)), '"}'));
        vm.expectRevert(RecipeManifest.InvalidManifest.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function test_InspectRejectsGuardedLeafAbsentFromOuterRecipe() public {
        _paths("RejectsGuardedLeafAbsentFromOuterRecipe");
        _writeGuardedRecipe();
        bytes[] memory empty = new bytes[](0);
        vm.writeJson(string.concat('"', vm.toString(abi.encode(empty, empty)), '"'), _inputPath, ".recipe");
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function test_InspectRejectsNonCanonicalEncodedBytes() public {
        _paths("RejectsNonCanonicalEncodedBytes");
        bytes[] memory empty = new bytes[](0);
        vm.writeFile(
            _inputPath, string.concat('{"recipe":"', vm.toString(bytes.concat(abi.encode(empty, empty), hex"ff")), '"}')
        );
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function test_InspectPreservesTrailingPayloadAndIgnoredOperandBits() public {
        _paths("PreservesTrailingPayloadAndIgnoredOperandBits");
        bytes[] memory queries = new bytes[](1);
        queries[0] = bytes.concat(abi.encode(address(1), hex"12345678", new uint256[](0), uint256(0)), hex"aa");
        bytes[] memory steps = new bytes[](1);
        steps[0] = bytes.concat(
            abi.encodePacked(OP_ADD, abi.encode((uint256(1) << 224) | 3, (uint256(1) << 248) | 4)), hex"bb"
        );
        bytes memory encoded = abi.encode(queries, steps);
        vm.writeFile(_inputPath, string.concat('{"recipe":"', vm.toString(encoded), '"}'));
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        string memory output = vm.readFile(_outputPath);
        assertEq(output.readBytes(".recipe"), encoded);
        assertEq(output.readBytes32(".manifest.recipeHash"), keccak256(encoded));
        assertEq(output.readString(".manifest.instructions[0].a.value"), "3");
        assertEq(output.readString(".manifest.instructions[0].b.value"), "4");
    }

    function test_InspectRejectsStaleNestedManifestWithoutGuardedMint() public {
        _paths("RejectsStaleNestedManifestWithoutGuardedMint");
        _writeEmptyRecipe();
        vm.writeJson("{}", _inputPath, ".guardedMintManifest");
        vm.expectRevert(BuildRecipe.InvalidRecipeArtifact.selector);
        BuildRecipe(_builder).inspect(_inputPath, _outputPath);
        assertFalse(vm.exists(_outputPath));
    }

    function _paths(string memory caseName) internal {
        _inputPath = string.concat("out/RecipeInspect.", caseName, ".input.json");
        _outputPath = string.concat("out/RecipeInspect.", caseName, ".output.json");
        if (vm.exists(_outputPath)) vm.removeFile(_outputPath);
    }

    function _writeEmptyRecipe() internal {
        bytes[] memory empty = new bytes[](0);
        vm.writeFile(_inputPath, string.concat('{"recipe":"', vm.toString(abi.encode(empty, empty)), '"}'));
    }

    function _writeGuardedRecipe() internal {
        bytes[] memory queries = new bytes[](0);
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(4), uint256(5)));
        bytes memory data = abi.encodeCall(IRecipeCapability.execute, (queries, steps, new uint256[](0)));
        bytes memory mask = new bytes(data.length);
        bytes32 leaf = MerkleAdapterVerifier.leaf(address(9), 0, data, mask);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](0);
        steps[0] = abi.encodePacked(OP_MANAGE, abi.encode(uint256(1), leaves, bindings));
        vm.serializeJson(_inputPath, '{"guardedMint":true}');
        vm.serializeBytes(_inputPath, "recipe", abi.encode(queries, steps));
        vm.serializeAddress(_inputPath, "mintLeafTarget", address(9));
        vm.serializeBytes(_inputPath, "mintLeafData", data);
        vm.serializeBytes(_inputPath, "mintLeafMask", mask);
        vm.writeJson(vm.serializeBytes32(_inputPath, "mintLeafHash", leaf), _inputPath);
    }
}

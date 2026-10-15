// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {RecipeManifest} from "script/recipes/RecipeManifest.sol";

import {
    OP_ADD,
    OP_APPROVE,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_SATURATING_SUB,
    OP_SUB
} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {
    ThreeFFacilityMock,
    ThreeFPositionManagerMock,
    ThreeFRequestFactoryMock,
    ThreeFRequestMock,
    ThreeFUnderlyingAssetMock
} from "test/mocks/ThreeFRequestMocks.sol";

contract RecipeManifestBuildTest is Test {
    using stdJson for string;

    address internal _builder;

    function setUp() public {
        _builder = deployCode("BuildRecipe.s.sol:BuildRecipe");
        vm.mockCall(address(0x103), abi.encodeCall(IMerkleAdapter.account, ()), abi.encode(address(0x104)));
        address requestsFactory = address(new ThreeFRequestFactoryMock());
        address facility = address(new ThreeFFacilityMock());
        address positionManager = address(
            new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(address(0x405))), address(0x400))
        );
        vm.etch(address(0x600), address(new ThreeFRequestMock(address(0x400), "request-1")).code);
        ThreeFRequestMock(address(0x600)).setName("request-1");
        ThreeFRequestFactoryMock(requestsFactory).set(address(0x600), true);
        ThreeFFacilityMock(facility).setIntent(1, address(0x600), positionManager, true);
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.REQUESTS_FACTORY, ()), abi.encode(requestsFactory));
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.FACILITY, ()), abi.encode(facility));
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.account, ()), abi.encode(address(0x104)));
    }

    function test_BuildRecipePublishesReadableManifest() public {
        string memory outputPath = "out/RecipeManifest.build.json";
        BuildRecipe(_builder).run("script/recipes/examples/lending.json", outputPath);
        string memory output = vm.readFile(outputPath);
        assertTrue(output.keyExists(".manifest"), "Readable recipe manifest is absent");
        assertEq(output.readUint(".manifest.schemaVersion"), 1);
        assertEq(output.readString(".manifest.instructions[0].opcode"), "Read");
        vm.removeFile(outputPath);
    }

    function test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots() public {
        vm.chainId(31_337);
        vm.roll(1);
        vm.setBlockhash(0, bytes32(0));
        bool updateSamples = vm.envOr("UPDATE_RECIPE_MANIFESTS", false);
        string memory samplesDirectory = "script/recipes/examples/manifests";
        if (updateSamples) vm.createDir(samplesDirectory, true);
        Vm.DirEntry[] memory entries = vm.readDir("script/recipes/examples", 1);
        uint256 examples;
        for (uint256 i; i < entries.length; ++i) {
            assertEq(entries[i].errorMessage, "", "Cannot discover recipe examples");
            if (entries[i].isDir) continue;
            string memory filename;
            {
                string[] memory path = vm.split(entries[i].path, "/");
                filename = path[path.length - 1];
                bytes memory name = bytes(filename);
                if (name.length < 5 || keccak256(Bytes.slice(name, name.length - 5)) != keccak256(".json")) continue;
            }
            ++examples;
            string memory outputPath = string.concat("out/RecipeManifest.catalogue.", filename);
            BuildRecipe(_builder).run(entries[i].path, outputPath);
            string memory output = vm.readFile(outputPath);
            vm.removeFile(outputPath);
            assertEq(output.readString(".manifestContext"), "build");
            ExecutingRecipe.Recipe memory recipe;
            (recipe.queries, recipe.steps) = abi.decode(output.readBytes(".recipe"), (bytes[], bytes[]));
            _assertManifestMatchesRecipe(output, ".manifest", recipe);
            string memory sample = string.concat(
                '{"_notice":"ILLUSTRATIVE ONLY. Built from dummy example addresses and leaves with mock protocol resolution. '
                'Fixed local chain 31337, block 1 and zero parent hash; not a deployment or live protocol snapshot.",'
                '"sourceConfig":"',
                filename,
                '","recipe":"',
                vm.toString(abi.encode(recipe.queries, recipe.steps)),
                '","manifest":',
                RecipeManifest.render(recipe)
            );
            bool guardedMint = output.keyExists(".guardedMint") && output.readBool(".guardedMint");
            assertEq(output.keyExists(".guardedMintManifest"), guardedMint);
            if (guardedMint) {
                {
                    string memory buildFixturePath = string.concat("script/recipes/examples/fixtures/", filename);
                    if (updateSamples) {
                        vm.createDir("script/recipes/examples/fixtures", true);
                        vm.writeJson(output, buildFixturePath);
                    }
                    assertTrue(vm.exists(buildFixturePath), "Missing guarded build fixture");
                    assertEq(
                        vm.parseJson(output),
                        vm.parseJson(vm.readFile(buildFixturePath)),
                        "Guarded build fixture is stale"
                    );
                }
                ExecutingRecipe.Recipe memory nested;
                (nested.queries, nested.steps,) =
                    abi.decode(Bytes.slice(output.readBytes(".mintLeafData"), 4), (bytes[], bytes[], uint256[]));
                _assertManifestMatchesRecipe(output, ".guardedMintManifest", nested);
                sample = string.concat(
                    sample,
                    ',"guardedRecipe":"',
                    vm.toString(abi.encode(nested.queries, nested.steps)),
                    '","guardedMintManifest":',
                    RecipeManifest.render(nested)
                );
            }
            sample = string.concat(sample, "}");
            string memory samplePath = string.concat(samplesDirectory, "/", filename);
            if (updateSamples) vm.writeJson(sample, samplePath);
            assertTrue(vm.exists(samplePath), string.concat("Missing readable manifest sample: ", filename));
            assertEq(
                vm.parseJson(sample),
                vm.parseJson(vm.readFile(samplePath)),
                string.concat("Readable manifest sample is stale: ", filename)
            );
        }
        assertGt(examples, 0, "No recipe examples discovered");
    }

    function test_GuardedManifestMatchesNestedRecipeWithAndWithoutTupleReads() public {
        string memory inputPath = "out/RecipeManifest.tuple-input.json";
        string memory outputPath = "out/RecipeManifest.tuple-output.json";
        vm.writeFile(inputPath, vm.readFile("script/recipes/examples/3f-executing.json"));
        for (uint256 i; i < 2; ++i) {
            vm.writeJson(i == 0 ? '{"reuseTupleReads":false}' : '{"reuseTupleReads":true}', inputPath, ".optimizations");
            BuildRecipe(_builder).run(inputPath, outputPath);
            string memory output = vm.readFile(outputPath);
            ExecutingRecipe.Recipe memory nested;
            (nested.queries, nested.steps,) =
                abi.decode(Bytes.slice(output.readBytes(".mintLeafData"), 4), (bytes[], bytes[], uint256[]));
            _assertManifestMatchesRecipe(output, ".guardedMintManifest", nested);
            assertEq(output.readUint(".guardedMintManifest.instructions[2].code"), OP_READ);
            assertEq(output.readUint(".guardedMintManifest.instructions[4].code"), OP_READ);
            assertEq(output.readUint(".guardedMintManifest.instructions[10].code"), OP_CALL);
            assertFalse(output.keyExists(".guardedMintManifest.instructions[6].runtimeSlot"));
            assertFalse(output.keyExists(".guardedMintManifest.instructions[11].runtimeSlot"));
        }
        vm.removeFile(inputPath);
        vm.removeFile(outputPath);
    }

    function test_NonThreeFOverwriteRemovesGuardedManifest() public {
        string memory outputPath = "out/RecipeManifest.overwrite.json";
        BuildRecipe(_builder).run("script/recipes/examples/3f-executing.json", outputPath);
        assertTrue(vm.readFile(outputPath).keyExists(".guardedMintManifest"));
        BuildRecipe(_builder).run("script/recipes/examples/lending.json", outputPath);
        string memory output = vm.readFile(outputPath);
        assertFalse(output.keyExists(".guardedMintManifest"));
        assertFalse(output.keyExists(".consumeStep"));
        vm.removeFile(outputPath);
    }

    function _assertManifestMatchesRecipe(
        string memory output,
        string memory base,
        ExecutingRecipe.Recipe memory recipe
    ) internal view {
        assertEq(output.readUint(string.concat(base, ".schemaVersion")), 1);
        assertEq(
            output.readBytes32(string.concat(base, ".recipeHash")), keccak256(abi.encode(recipe.queries, recipe.steps))
        );
        bool[17] memory used;
        uint256 runtimeSlot;
        uint256 stepsLength = recipe.steps.length;
        for (uint256 i; i < stepsLength; ++i) {
            uint8 operation = uint8(recipe.steps[i][0]);
            used[operation] = true;
            string memory path = string.concat(base, ".instructions[", vm.toString(i), "]");
            assertEq(output.readUint(string.concat(path, ".index")), i);
            assertEq(output.readUint(string.concat(path, ".code")), operation);
            if (operation == OP_MANAGE || operation == OP_APPROVE) {
                assertEq(output.readUint(string.concat(path, ".runtimeSlot")), runtimeSlot++);
            } else {
                assertFalse(output.keyExists(string.concat(path, ".runtimeSlot")));
            }
        }
        assertFalse(output.keyExists(string.concat(base, ".instructions[", vm.toString(stepsLength), "]")));
        uint256 required;
        for (uint256 i; i < used.length; ++i) {
            if (used[i]) {
                assertEq(
                    output.readUint(string.concat(base, ".requiredOpcodes[", vm.toString(required++), "].code")), i
                );
            }
        }
        assertFalse(output.keyExists(string.concat(base, ".requiredOpcodes[", vm.toString(required), "]")));
        uint256 queriesLength = recipe.queries.length;
        for (uint256 i; i < queriesLength; ++i) {
            (uint256 target, bytes memory data,, uint256 offset) =
                abi.decode(recipe.queries[i], (uint256, bytes, uint256[], uint256));
            string memory path = string.concat(base, ".queries[", vm.toString(i), "]");
            assertEq(output.readUint(string.concat(path, ".index")), i);
            if (target <= type(uint160).max) {
                assertEq(output.readAddress(string.concat(path, ".target")), address(uint160(target)));
            } else {
                assertEq(output.readString(string.concat(path, ".target.source")), "Input");
                assertEq(output.readString(string.concat(path, ".target.value")), vm.toString(uint216(target)));
            }
            assertEq(output.readBytes(string.concat(path, ".calldata")), data);
            assertEq(output.readUint(string.concat(path, ".returnOffset")), offset);
        }
        assertFalse(output.keyExists(string.concat(base, ".queries[", vm.toString(queriesLength), "]")));
    }
}

contract RecipeManifestTest is Test {
    using stdJson for string;
    using ExecutingRecipe for ExecutingRecipe.Builder;

    function test_RendersEveryOpcodeAndBindingWithoutResolvingAmounts() public {
        vm.chainId(31_337);
        vm.roll(1);
        vm.setBlockhash(0, bytes32(0));
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(16);
        uint256 literal = builder.literal(type(uint216).max);
        uint256 input = builder.input(7);
        uint256 result = ExecutingRecipe.result(0);
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = ExecutingRecipe.binding(4, literal);
        bindings[1] = ExecutingRecipe.binding(36, input);
        builder.readQuery(
            ExecutingRecipe.Query({target: address(1), data: hex"aabbccdd", bindings: bindings, offset: 32})
        );
        uint8[8] memory numerical =
            [OP_ADD, OP_SUB, OP_SATURATING_SUB, OP_MIN, OP_MAX, OP_MUL_DIV, OP_EQUAL, OP_LESS_OR_EQUAL];
        for (uint256 i; i < numerical.length; ++i) {
            builder.instruction(
                numerical[i],
                numerical[i] == OP_MUL_DIV ? abi.encode(literal, input, result) : abi.encode(literal, input)
            );
        }
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = bytes32(uint256(9));
        leaves[1] = bytes32(uint256(10));
        uint256[][] memory grouped = new uint256[][](2);
        grouped[0] = bindings;
        grouped[1] = new uint256[](1);
        grouped[1][0] = ExecutingRecipe.binding(68, result);
        builder.manage(leaves, input, grouped);
        builder.approve(address(11), address(12), leaves[0], result);
        builder.call(address(13), hex"11223344", bindings);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        string memory manifest = RecipeManifest.render(recipe);

        assertEq(manifest.readUint(".schemaVersion"), 1);
        assertEq(manifest.readUint(".snapshot.chainId"), block.chainid);
        assertEq(manifest.readUint(".snapshot.blockNumber"), block.number);
        assertEq(
            manifest.readBytes32(".snapshot.parentBlockHash"),
            block.number > 0 ? blockhash(block.number - 1) : bytes32(0)
        );
        string[12] memory names = [
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
            "Call"
        ];
        for (uint256 i; i < names.length; ++i) {
            string memory path = string.concat(".instructions[", vm.toString(i), "]");
            assertEq(manifest.readUint(string.concat(path, ".index")), i);
            assertEq(manifest.readUint(string.concat(path, ".code")), i);
            assertEq(manifest.readString(string.concat(path, ".opcode")), names[i]);
            path = string.concat(".requiredOpcodes[", vm.toString(i), "]");
            assertEq(manifest.readUint(string.concat(path, ".code")), i);
            assertEq(manifest.readString(string.concat(path, ".name")), names[i]);
        }
        assertEq(manifest.readAddress(".queries[0].target"), address(1));
        assertEq(manifest.readBytes(".queries[0].calldata"), hex"aabbccdd");
        assertEq(manifest.readUint(".queries[0].returnOffset"), 32);
        assertEq(manifest.readUint(".queries[0].bindings[0].offset"), 4);
        assertEq(manifest.readString(".queries[0].bindings[0].operand.source"), "Literal");
        assertEq(manifest.readString(".queries[0].bindings[0].operand.value"), vm.toString(type(uint216).max));
        assertEq(manifest.readString(".queries[0].bindings[1].operand.source"), "Input");
        assertEq(manifest.readString(".queries[0].bindings[1].operand.value"), "7");
        assertEq(manifest.readUint(".instructions[0].queryIndex"), 0);
        for (uint256 i = 1; i <= 8; ++i) {
            string memory path = string.concat(".instructions[", vm.toString(i), "]");
            assertEq(manifest.readString(string.concat(path, ".a.source")), "Literal");
            assertEq(manifest.readString(string.concat(path, ".a.value")), vm.toString(type(uint216).max));
            assertEq(manifest.readString(string.concat(path, ".b.source")), "Input");
            assertEq(manifest.readString(string.concat(path, ".b.value")), "7");
        }
        assertEq(manifest.readString(".instructions[6].denominator.source"), "Result");
        assertEq(manifest.readString(".instructions[6].denominator.value"), "0");
        assertEq(manifest.readString(".instructions[9].gate.source"), "Input");
        assertEq(manifest.readBytes32(".instructions[9].groups[0].leaf"), leaves[0]);
        assertEq(manifest.readUint(".instructions[9].groups[0].bindings[1].offset"), 36);
        assertEq(manifest.readBytes32(".instructions[9].groups[1].leaf"), leaves[1]);
        assertEq(manifest.readString(".instructions[9].groups[1].bindings[0].operand.source"), "Result");
        assertEq(manifest.readUint(".instructions[9].runtimeSlot"), 0);
        assertEq(manifest.readAddress(".instructions[10].token"), address(11));
        assertEq(manifest.readAddress(".instructions[10].spender"), address(12));
        assertEq(manifest.readBytes32(".instructions[10].leaf"), leaves[0]);
        assertEq(manifest.readString(".instructions[10].amount.source"), "Result");
        assertEq(manifest.readUint(".instructions[10].runtimeSlot"), 1);
        assertEq(manifest.readAddress(".instructions[11].target"), address(13));
        assertEq(manifest.readBytes(".instructions[11].calldata"), hex"11223344");
        assertEq(manifest.readUint(".instructions[11].bindings[1].offset"), 36);
        assertFalse(manifest.keyExists(".instructions[11].runtimeSlot"));
        assertFalse(manifest.keyExists(".requiredOpcodes[12]"));
        {
            string memory fixture = string.concat(
                '{"_notice":"Decoder fixture only; dummy calls, symbolic inputs and leaves are not an executable strategy.",',
                '"recipe":"',
                vm.toString(abi.encode(recipe.queries, recipe.steps)),
                '","manifest":',
                manifest,
                "}"
            );
            string memory fixturePath = "script/recipes/examples/fixtures/all-opcodes.json";
            if (vm.envOr("UPDATE_RECIPE_MANIFESTS", false)) {
                vm.createDir("script/recipes/examples/fixtures", true);
                vm.writeJson(fixture, fixturePath);
            }
            assertTrue(vm.exists(fixturePath), "Missing cross-language opcode fixture");
            assertEq(vm.parseJson(fixture), vm.parseJson(vm.readFile(fixturePath)), "Opcode fixture is stale");
        }
    }

    function test_RequiredOpcodesComeFromEncodedInstructionsOnly() public view {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.instruction(OP_ADD, abi.encode(uint256(2), uint256(3)));
        builder.instruction(OP_ADD, abi.encode(uint256(5), uint256(6)));
        string memory manifest = RecipeManifest.render(builder.finish());
        assertEq(manifest.readUint(".requiredOpcodes[0].code"), OP_ADD);
        assertEq(manifest.readString(".requiredOpcodes[0].name"), "Add");
        assertFalse(manifest.keyExists(".requiredOpcodes[1]"));
    }

    function test_LargeInputAndResultIndicesStayReferences() public view {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.instruction(
            OP_ADD, abi.encode(builder.input(type(uint216).max), ExecutingRecipe.result(type(uint216).max))
        );
        string memory manifest = RecipeManifest.render(builder.finish());
        assertEq(manifest.readString(".instructions[0].a.source"), "Input");
        assertEq(manifest.readString(".instructions[0].a.value"), vm.toString(type(uint216).max));
        assertEq(manifest.readString(".instructions[0].b.source"), "Result");
        assertEq(manifest.readString(".instructions[0].b.value"), vm.toString(type(uint216).max));
    }

    function test_EmptyRecipeProducesEmptyListsAtGenesis() public {
        vm.roll(0);
        string memory manifest = RecipeManifest.render(ExecutingRecipe.start(0).finish());
        assertEq(manifest.readBytes32(".snapshot.parentBlockHash"), bytes32(0));
        assertFalse(manifest.keyExists(".queries[0]"));
        assertFalse(manifest.keyExists(".instructions[0]"));
        assertFalse(manifest.keyExists(".requiredOpcodes[0]"));
    }

    function testFuzz_RejectsUnsupportedOpcode(uint8 operation) public {
        operation = uint8(bound(operation, OP_CALL + 1, type(uint8).max));
        ExecutingRecipe.Recipe memory recipe;
        recipe.queries = new bytes[](0);
        recipe.steps = new bytes[](1);
        recipe.steps[0] = abi.encodePacked(operation, abi.encode(uint256(0)));
        vm.expectRevert(RecipeManifest.InvalidManifest.selector);
        this.render(recipe);
    }

    function test_RejectsUnknownOpcodeAndEmptyStep() public {
        ExecutingRecipe.Recipe memory recipe;
        recipe.queries = new bytes[](0);
        recipe.steps = new bytes[](1);
        recipe.steps[0] = hex"ff";
        vm.expectRevert(RecipeManifest.InvalidManifest.selector);
        this.render(recipe);
        recipe.steps[0] = "";
        vm.expectRevert(RecipeManifest.InvalidManifest.selector);
        this.render(recipe);
    }

    function test_RejectsUnknownOperandSourceAndMismatchedGroups() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.instruction(OP_ADD, abi.encode(uint256(3) << 216, uint256(0)));
        vm.expectRevert(RecipeManifest.InvalidManifest.selector);
        this.render(builder.finish());
        builder = ExecutingRecipe.start(1);
        builder.instruction(OP_MANAGE, abi.encode(uint256(1), new bytes32[](1), new uint256[][](0)));
        vm.expectRevert(RecipeManifest.InvalidManifest.selector);
        this.render(builder.finish());
    }

    function test_MalformedPayloadCannotProduceManifest() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.instruction(OP_READ, hex"01");
        vm.expectRevert();
        this.render(builder.finish());
    }

    function render(ExecutingRecipe.Recipe memory recipe) public view returns (string memory) {
        return RecipeManifest.render(recipe);
    }
}

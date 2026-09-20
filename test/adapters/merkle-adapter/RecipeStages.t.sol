// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract RecipeStagesTest is Test {
    using stdJson for string;

    function test_AllTemplatesHaveContiguousNamedStages() public {
        string[5] memory templates = ["lending", "health-recovery", "health-claim", "ll-executing", "3f-executing"];
        BuildRecipe builder = new BuildRecipe();
        for (uint256 i; i < templates.length; ++i) {
            string memory path = string.concat("out/RecipeStages.", templates[i], ".json");
            builder.run(string.concat("script/recipes/examples/", templates[i], ".json"), path);
            string memory output = vm.readFile(path);
            uint256 actionCount = output.readUint(".stepCount");
            uint256 end;
            for (uint256 j; output.keyExists(string.concat(".stages[", vm.toString(j), "]")); ++j) {
                string memory stage = string.concat(".stages[", vm.toString(j), "]");
                assertGt(bytes(output.readString(string.concat(stage, ".name"))).length, 0);
                assertEq(output.readUint(string.concat(stage, ".startStep")), end);
                uint256 next = output.readUint(string.concat(stage, ".endStep"));
                assertGt(next, end);
                end = next;
            }
            assertEq(end, actionCount);
            vm.removeFile(path);
        }
    }

    function test_SourceNamesAreEscapedAndRedemptionIsVisible() public {
        string memory inputPath = "out/RecipeStages.input.json";
        string memory outputPath = "out/RecipeStages.output.json";
        vm.writeFile(
            inputPath,
            vm.replace(
                vm.readFile("script/recipes/examples/ll-executing.json"), "Aave USDC withdrawal", 'Aave \\"Core\\"'
            )
        );
        new BuildRecipe().run(inputPath, outputPath);
        string memory output = vm.readFile(outputPath);
        assertEq(output.readString(".stages[1].name"), 'Aave "Core"');
        uint256 redeem = output.readUintArray(".runtimeSteps")[output.readUint(".redeemStep")];
        bool found;
        for (uint256 i; output.keyExists(string.concat(".stages[", vm.toString(i), "]")); ++i) {
            string memory stage = string.concat(".stages[", vm.toString(i), "]");
            if (keccak256(bytes(output.readString(string.concat(stage, ".name")))) == keccak256("Redeem RWA")) {
                assertLe(output.readUint(string.concat(stage, ".startStep")), redeem);
                assertGt(output.readUint(string.concat(stage, ".endStep")), redeem);
                found = true;
            }
        }
        assertTrue(found);
        vm.removeFile(inputPath);
        vm.removeFile(outputPath);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {
    ThreeFFacilityMock,
    ThreeFPositionManagerMock,
    ThreeFRequestFactoryMock,
    ThreeFRequestMock,
    ThreeFUnderlyingAssetMock
} from "test/mocks/ThreeFRequestMocks.sol";

contract RecipeStagesTest is Test {
    using stdJson for string;

    function setUp() public {
        vm.mockCall(address(0x103), abi.encodeCall(IMerkleAdapter.account, ()), abi.encode(address(0x104)));
        address requestsFactory = address(new ThreeFRequestFactoryMock());
        address facility = address(new ThreeFFacilityMock());
        vm.etch(address(0x600), address(new ThreeFRequestMock(address(0x400), "request-1")).code);
        ThreeFRequestMock(address(0x600)).setName("request-1");
        ThreeFRequestFactoryMock(requestsFactory).set(address(0x600), true);
        ThreeFFacilityMock(facility)
            .setIntent(
                1,
                address(0x600),
                address(
                    new ThreeFPositionManagerMock(
                        address(new ThreeFUnderlyingAssetMock(address(0x405))), address(0x400)
                    )
                ),
                true
            );
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.REQUESTS_FACTORY, ()), abi.encode(requestsFactory));
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.FACILITY, ()), abi.encode(facility));
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.account, ()), abi.encode(address(0x104)));
    }

    function test_AllTemplatesHaveContiguousNamedStages() public {
        string[7] memory templates =
            ["lending", "health-recovery", "health-claim", "health-repay", "claim", "ll-executing", "3f-executing"];
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

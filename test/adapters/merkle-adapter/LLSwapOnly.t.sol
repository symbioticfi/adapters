// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LLSwapOnly} from "script/recipes/LLSwapOnly.sol";

import {Test} from "forge-std/Test.sol";

contract LLSwapOnlyTest is Test {
    function test_AllAdmittedAssetsShareOneCommittedProgram() public pure {
        LLSwapOnly.Config memory config = _config(13);
        (ExecutingRecipe.Recipe memory recipe, LLSwapOnly.Layout memory layout) = LLSwapOnly.build(config);
        assertEq(layout.operations.length, 13);
        assertGt(recipe.queries.length, 13);
        uint256[] memory runtime = ExecutingRecipe.runtimeSteps(recipe);
        assertEq(runtime.length, 15);
    }

    function test_EmptyAndDuplicateAssetSetsRevert() public {
        LLSwapOnly.Config memory config = _config(0);
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.build(config);
        config = _config(2);
        config.routes[1].rwa = config.routes[0].rwa;
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.build(config);
        config = _config(65);
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.build(config);
    }

    function build(LLSwapOnly.Config memory config) external pure {
        LLSwapOnly.build(config);
    }

    function _config(uint256 count) internal pure returns (LLSwapOnly.Config memory config) {
        config.funding.account = address(100);
        config.funding.asset = address(101);
        config.connector = address(102);
        config.recipient = address(103);
        config.approvalLeaf = bytes32(uint256(104));
        config.routes = new LLSwapOnly.Route[](count);
        for (uint256 i; i < count; ++i) {
            config.routes[i] = LLSwapOnly.Route({rwa: address(uint160(i + 200)), swapLeaf: bytes32(i + 300)});
        }
    }
}

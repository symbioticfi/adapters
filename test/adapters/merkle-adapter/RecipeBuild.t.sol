// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {LendingRecipe} from "script/recipes/LendingRecipe.sol";
import {LiquidityRecipe} from "script/recipes/LiquidityRecipe.sol";

import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract RecipeBuildTest is Test {
    using stdJson for string;

    address internal builder;

    function setUp() public {
        builder = address(new BuildRecipe());
    }

    function test_LendingExampleRoundTrips() public {
        string memory outputPath = "out/RecipeBuild.lending.json";
        BuildRecipe(builder).run("script/recipes/examples/lending.json", outputPath);
        LendingRecipe.Config memory config;
        config.adapter = address(0x0103);
        config.lbtc = address(0x0201);
        config.usdc = address(0x0202);
        config.rwa = address(0x0203);
        config.collateralReceipt = address(0x0204);
        config.variableDebt = address(0x0205);
        config.pool = address(0x0206);
        config.issuer = address(0x0207);
        config.collateralApprovalLeaf = bytes32(uint256(type(uint256).max / 15));
        config.supplyLeaf = bytes32(uint256(type(uint256).max / 15 * 2));
        config.borrowLeaf = bytes32(uint256(type(uint256).max / 15 * 3));
        config.purchaseApprovalLeaf = bytes32(uint256(type(uint256).max / 15 * 4));
        config.purchaseLeaf = bytes32(uint256(type(uint256).max / 15 * 5));
        IRecipeExecutor.Step[] memory expected =
            LendingRecipe.build(config, LendingRecipe.Limits(1e8, 50_000e6, 0.99e18));

        _assertOutput(outputPath, expected, true);
        vm.removeFile(outputPath);
    }

    function test_LiquidLaneExampleRoundTripsWithoutFactory() public {
        string memory outputPath = "out/RecipeBuild.liquid-lane.json";
        BuildRecipe(builder).run("script/recipes/examples/liquid-lane.json", outputPath);
        LiquidityRecipe.Configuration memory config = LiquidityRecipe.Configuration({
            executor: address(0x0301),
            adapter: address(0x0103),
            connector: address(0x0302),
            rwa: address(0x0303),
            receiptToken: address(0x0304),
            maxAmountIn: 100e18,
            maxFundingAmount: 100e6,
            minReceiptNumerator: 1,
            receiptDenominator: 1,
            maxReceiptBalance: 1000e18
        });
        IRecipeExecutor.Step[] memory expected = LiquidityRecipe.liquidLane(config);

        _assertOutput(outputPath, expected, false);
        vm.removeFile(outputPath);
    }

    function test_OverwritingOutputDoesNotRetainOptionalFactory() public {
        string memory outputPath = "out/RecipeBuild.overwrite.json";
        BuildRecipe(builder).run("script/recipes/examples/lending.json", outputPath);
        assertTrue(vm.readFile(outputPath).keyExists(".factoryCreateCalldata"));
        BuildRecipe(builder).run("script/recipes/examples/liquid-lane.json", outputPath);
        string memory output = vm.readFile(outputPath);
        assertFalse(output.keyExists(".factory"));
        assertFalse(output.keyExists(".factoryCreateCalldata"));
        assertEq(output.readString(".template"), "liquid-lane");
        vm.removeFile(outputPath);
    }

    function test_UnknownTemplateRevertsBeforeWritingOutput() public {
        string memory inputPath = "out/RecipeBuild.unknown-input.json";
        string memory outputPath = "out/RecipeBuild.unknown-output.json";
        vm.writeFile(inputPath, vm.readFile("script/recipes/examples/lending.json"));
        vm.writeJson('"unsupported"', inputPath, ".template");

        vm.expectRevert(BuildRecipe.UnknownTemplate.selector);
        BuildRecipe(builder).run(inputPath, outputPath);
        assertFalse(vm.exists(outputPath));
        vm.removeFile(inputPath);
    }

    function test_HealthRecoveryExampleDefinesOrderedSourcesAndRequests() public {
        string memory outputPath = "out/RecipeBuild.health-recovery.json";
        BuildRecipe(builder).run("script/recipes/examples/health-recovery.json", outputPath);
        string memory output = vm.readFile(outputPath);
        IRecipeExecutor.Step[] memory recipe = abi.decode(output.readBytes(".recipe"), (IRecipeExecutor.Step[]));
        _assertOutput(outputPath, recipe, true);
        uint256[] memory sources = output.readUintArray(".sourceCalls");
        uint256[] memory requests = output.readUintArray(".requestCalls");
        assertEq(sources.length, 2);
        assertEq(requests.length, 2);
        assertEq(output.readUintArray(".claimCalls").length, 0);
        assertLt(sources[0], sources[1]);
        assertLt(sources[1], output.readUint(".repayStep"));
        assertLt(output.readUint(".repayStep"), requests[0]);
        assertLt(requests[0], requests[1]);
        _assertGroup(recipe[sources[0]], 3, 1);
        _assertGroup(recipe[sources[1]], 4, 1);
        _assertGroup(recipe[requests[0]], 5, 3);
        _assertGroup(recipe[requests[1]], 8, 3);
        _assertRecoveryLayout(output, recipe);
        bool trigger;
        bool target;
        bool cap;
        bool rate;
        for (uint256 i; i < recipe.length; ++i) {
            if (recipe[i].operation != IRecipeExecutor.Operation.Constant) continue;
            if (recipe[i].a == 1.25e18) trigger = true;
            if (recipe[i].a == 1.5e18) target = true;
            if (recipe[i].a == 100e6) cap = true;
            if (recipe[i].a == 1e30) rate = true;
        }
        assertTrue(trigger && target && cap && rate);
        vm.removeFile(outputPath);
    }

    function test_HealthClaimExampleHasSeparateClaimAndRepayLayout() public {
        string memory outputPath = "out/RecipeBuild.health-claim.json";
        BuildRecipe(builder).run("script/recipes/examples/health-claim.json", outputPath);
        string memory output = vm.readFile(outputPath);
        IRecipeExecutor.Step[] memory recipe = abi.decode(output.readBytes(".recipe"), (IRecipeExecutor.Step[]));
        _assertOutput(outputPath, recipe, true);
        uint256[] memory claims = output.readUintArray(".claimCalls");
        assertEq(claims.length, 2);
        assertEq(output.readUintArray(".sourceCalls").length, 0);
        assertEq(output.readUintArray(".requestCalls").length, 0);
        assertLt(claims[0], claims[1]);
        assertLt(claims[1], output.readUint(".repayStep"));
        _assertGroup(recipe[claims[0]], 7, 1);
        _assertGroup(recipe[claims[1]], 10, 1);
        _assertRecoveryLayout(output, recipe);
        vm.removeFile(outputPath);
    }

    function test_OverwritingHealthOutputDoesNotRetainLayout() public {
        string memory outputPath = "out/RecipeBuild.health-overwrite.json";
        BuildRecipe(builder).run("script/recipes/examples/health-recovery.json", outputPath);
        assertTrue(vm.readFile(outputPath).keyExists(".sourceCalls"));
        BuildRecipe(builder).run("script/recipes/examples/lending.json", outputPath);
        assertFalse(vm.readFile(outputPath).keyExists(".sourceCalls"));
        assertFalse(vm.readFile(outputPath).keyExists(".repayStep"));
        vm.removeFile(outputPath);
    }

    function test_ThreeFExecutingExampleUsesLiveAuthorizationAndDirectLeaves() public {
        string memory outputPath = "out/RecipeBuild.3f-executing.json";
        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        string memory output = vm.readFile(outputPath);
        IRecipeExecutor.Step[] memory recipe = abi.decode(output.readBytes(".recipe"), (IRecipeExecutor.Step[]));
        _assertOutput(outputPath, recipe, true);
        _assertExecutingLayout(output, recipe, 0);
        uint256 principal = output.readUint(".principalStep");
        _assertRead(
            recipe[principal], address(0x600), abi.encodeCall(IThreeFPushRequest.mintAuthorization, (address(0x103))), 0
        );
        assertEq(recipe[output.readUint(".approveStep")].a, principal);
        assertEq(recipe[output.readUint(".operationStep")].a, principal);
        _assertApproval(recipe[output.readUint(".approveStep")], address(0x400), address(0x600), 1);
        _assertApproval(recipe[output.readUint(".clearApprovalStep")], address(0x400), address(0x600), 1);
        _assertConstant(recipe, 100e6);
        _assertConstant(recipe, 1e6);
        _assertConstant(recipe, 1000e6);
        assertFalse(output.keyExists(".amountInStep"));
        assertFalse(output.keyExists(".redeemStep"));
        vm.removeFile(outputPath);
    }

    function test_LLExecutingExampleMapsInputsSwapAndRedemption() public {
        string memory outputPath = "out/RecipeBuild.ll-executing.json";
        BuildRecipe(builder).run("script/recipes/examples/ll-executing.json", outputPath);
        string memory output = vm.readFile(outputPath);
        IRecipeExecutor.Step[] memory recipe = abi.decode(output.readBytes(".recipe"), (IRecipeExecutor.Step[]));
        _assertOutput(outputPath, recipe, true);
        _assertExecutingLayout(output, recipe, 2);
        uint256 amountIn = output.readUint(".amountInStep");
        uint256 amountOut = output.readUint(".amountOutStep");
        assertEq(uint256(recipe[amountIn].operation), uint256(IRecipeExecutor.Operation.Input));
        assertEq(uint256(recipe[amountOut].operation), uint256(IRecipeExecutor.Operation.Input));
        assertEq(recipe[amountIn].a, 0);
        assertEq(recipe[amountOut].a, 1);
        assertEq(recipe[output.readUint(".approveStep")].a, amountOut);
        assertEq(recipe[output.readUint(".operationStep")].a, amountIn);
        _assertApproval(recipe[output.readUint(".approveStep")], address(0x400), address(0x302), 1);
        _assertApproval(recipe[output.readUint(".clearApprovalStep")], address(0x400), address(0x302), 1);
        uint256 redeem = output.readUint(".redeemStep");
        _assertGroup(recipe[redeem], 6, 1);
        assertEq(recipe[redeem].a, amountIn);
        assertLt(output.readUint(".clearApprovalStep"), output.readUint(".redeemApproveStep"));
        assertLt(output.readUint(".redeemApproveStep"), redeem);
        assertLt(redeem, output.readUint(".redeemClearApprovalStep"));
        _assertApproval(recipe[output.readUint(".redeemApproveStep")], address(0x303), address(0x305), 5);
        _assertApproval(recipe[output.readUint(".redeemClearApprovalStep")], address(0x303), address(0x305), 5);
        assertEq(recipe[output.readUint(".redeemApproveStep")].a, amountIn);
        _assertZeroReference(recipe, recipe[output.readUint(".redeemClearApprovalStep")].a);
        uint256 receiptReads;
        for (uint256 i; i < recipe.length; ++i) {
            if (recipe[i].operation != IRecipeExecutor.Operation.Read) continue;
            (address target,) = abi.decode(recipe[i].data, (address, bytes));
            if (target != address(0x304)) continue;
            _assertRead(recipe[i], address(0x304), abi.encodeCall(IERC20.balanceOf, (address(0x103))), 0);
            ++receiptReads;
        }
        assertEq(receiptReads, 2);
        _assertConstant(recipe, 100e18);
        _assertConstant(recipe, 100e6);
        _assertConstant(recipe, 1000e18);
        vm.removeFile(outputPath);
    }

    function test_LLExecutingOptionalRedemptionAndOverwriteClearLayout() public {
        string memory inputPath = "out/RecipeBuild.ll-optional-input.json";
        string memory outputPath = "out/RecipeBuild.ll-optional-output.json";
        string memory source = vm.readFile("script/recipes/examples/ll-executing.json");
        BuildRecipe(builder).run("script/recipes/examples/ll-executing.json", outputPath);
        assertTrue(vm.readFile(outputPath).keyExists(".redeemStep"));

        vm.writeFile(inputPath, source);
        vm.writeJson('{"leaves":[]}', inputPath, ".redemption");
        BuildRecipe(builder).run(inputPath, outputPath);
        string memory output = vm.readFile(outputPath);
        IRecipeExecutor.Step[] memory emptyLeaves = abi.decode(output.readBytes(".recipe"), (IRecipeExecutor.Step[]));
        _assertOutput(outputPath, emptyLeaves, true);
        _assertExecutingLayout(output, emptyLeaves, 2);
        _assertNoRedemption(output, emptyLeaves);

        vm.writeFile(inputPath, vm.replace(source, '"redemption": {', '"_disabledRedemption": {'));
        assertFalse(vm.readFile(inputPath).keyExists(".redemption"));
        BuildRecipe(builder).run(inputPath, outputPath);
        output = vm.readFile(outputPath);
        IRecipeExecutor.Step[] memory absent = abi.decode(output.readBytes(".recipe"), (IRecipeExecutor.Step[]));
        assertEq(abi.encode(absent), abi.encode(emptyLeaves));
        _assertOutput(outputPath, absent, true);
        _assertNoRedemption(output, absent);

        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        output = vm.readFile(outputPath);
        assertTrue(output.keyExists(".principalStep"));
        assertFalse(output.keyExists(".amountInStep"));
        assertFalse(output.keyExists(".amountOutStep"));
        assertFalse(output.keyExists(".redeemStep"));
        vm.removeFile(inputPath);
        vm.removeFile(outputPath);
    }

    function _assertGroup(IRecipeExecutor.Step memory step, uint256 firstLeaf, uint256 count) internal pure {
        assertEq(uint256(step.operation), uint256(IRecipeExecutor.Operation.Manage));
        bytes32[] memory leaves = abi.decode(step.data, (bytes32[]));
        assertEq(leaves.length, count);
        assertEq(leaves[0], bytes32(firstLeaf));
    }

    function _assertExecutingLayout(string memory output, IRecipeExecutor.Step[] memory recipe, uint256 expectedInputs)
        internal
        pure
    {
        uint256[] memory calls = output.readUintArray(".sourceCalls");
        uint256[] memory amounts = output.readUintArray(".sourceAmounts");
        assertEq(calls.length, 2);
        assertEq(amounts.length, 2);
        assertLt(calls[0], calls[1]);
        assertLt(calls[1], output.readUint(".approveStep"));
        assertLt(output.readUint(".approveStep"), output.readUint(".operationStep"));
        assertLt(output.readUint(".operationStep"), output.readUint(".clearApprovalStep"));
        for (uint256 i; i < calls.length; ++i) {
            _assertGroup(recipe[calls[i]], 3 + i, 1);
            assertEq(recipe[calls[i]].a, amounts[i]);
            assertLt(amounts[i], calls[i]);
            assertEq(uint256(recipe[amounts[i]].operation), uint256(IRecipeExecutor.Operation.Minimum));
        }
        _assertRead(
            recipe[recipe[amounts[0]].b],
            address(0x420),
            abi.encodeWithSignature("morphoVaultWithdraw(address,address)", address(0x421), address(0x103)),
            0
        );
        _assertRead(
            recipe[recipe[amounts[1]].b],
            address(0x420),
            abi.encodeWithSignature(
                "aaveWithdraw(address,address,address)", address(0x422), address(0x400), address(0x103)
            ),
            0
        );
        _assertGroup(recipe[output.readUint(".operationStep")], 2, 1);
        _assertZeroReference(recipe, recipe[output.readUint(".clearApprovalStep")].a);
        uint256 inputs;
        for (uint256 i; i < recipe.length; ++i) {
            assertTrue(recipe[i].operation != IRecipeExecutor.Operation.Invoke);
            assertTrue(recipe[i].operation != IRecipeExecutor.Operation.Calldata);
            if (recipe[i].operation == IRecipeExecutor.Operation.Input) ++inputs;
        }
        assertEq(inputs, expectedInputs);
    }

    function _assertApproval(IRecipeExecutor.Step memory step, address token, address spender, uint256 leaf)
        internal
        pure
    {
        assertEq(uint256(step.operation), uint256(IRecipeExecutor.Operation.Approve));
        (address actualToken, address actualSpender, bytes32 actualLeaf) =
            abi.decode(step.data, (address, address, bytes32));
        assertEq(actualToken, token);
        assertEq(actualSpender, spender);
        assertEq(actualLeaf, bytes32(leaf));
    }

    function _assertRead(IRecipeExecutor.Step memory step, address target, bytes memory data, uint256 offset)
        internal
        pure
    {
        assertEq(uint256(step.operation), uint256(IRecipeExecutor.Operation.Read));
        (address actualTarget, bytes memory actualData) = abi.decode(step.data, (address, bytes));
        assertEq(actualTarget, target);
        assertEq(actualData, data);
        assertEq(step.a, offset);
    }

    function _assertZeroReference(IRecipeExecutor.Step[] memory recipe, uint256 index) internal pure {
        assertEq(uint256(recipe[index].operation), uint256(IRecipeExecutor.Operation.Constant));
        assertEq(recipe[index].a, 0);
    }

    function _assertConstant(IRecipeExecutor.Step[] memory recipe, uint256 value) internal pure {
        for (uint256 i; i < recipe.length; ++i) {
            if (recipe[i].operation == IRecipeExecutor.Operation.Constant && recipe[i].a == value) return;
        }
        revert("Missing configured limit");
    }

    function _assertNoRedemption(string memory output, IRecipeExecutor.Step[] memory recipe) internal view {
        assertFalse(output.keyExists(".redeemStep"));
        assertFalse(output.keyExists(".redeemApproveStep"));
        assertFalse(output.keyExists(".redeemClearApprovalStep"));
        uint256 managed;
        uint256 approvals;
        for (uint256 i; i < recipe.length; ++i) {
            if (recipe[i].operation == IRecipeExecutor.Operation.Manage) ++managed;
            if (recipe[i].operation == IRecipeExecutor.Operation.Approve) ++approvals;
        }
        assertEq(managed, 3);
        assertEq(approvals, 2);
    }

    function _assertRecoveryLayout(string memory output, IRecipeExecutor.Step[] memory recipe) internal pure {
        assertEq(uint256(recipe[output.readUint(".approveStep")].operation), uint256(IRecipeExecutor.Operation.Approve));
        assertEq(
            uint256(recipe[output.readUint(".clearApprovalStep")].operation), uint256(IRecipeExecutor.Operation.Approve)
        );
        _assertGroup(recipe[output.readUint(".repayStep")], 2, 1);
        for (uint256 i; i < recipe.length; ++i) {
            assertTrue(recipe[i].operation != IRecipeExecutor.Operation.Input);
            assertTrue(recipe[i].operation != IRecipeExecutor.Operation.Calldata);
        }
    }

    function _assertOutput(string memory path, IRecipeExecutor.Step[] memory expected, bool hasFactory) internal view {
        string memory output = vm.readFile(path);
        assertEq(output.readAddress(".curator"), address(0x0101));
        assertEq(output.readAddress(".provider"), address(0x0102));
        assertEq(output.readAddress(".adapter"), address(0x0103));
        assertFalse(output.keyExists(".recipeHash"));
        IRecipeExecutor.Step[] memory recipe = abi.decode(output.readBytes(".recipe"), (IRecipeExecutor.Step[]));
        assertEq(abi.encode(recipe), abi.encode(expected));

        bytes memory data = output.readBytes(".setRecipeCalldata");
        assertEq(bytes4(data), IRecipeExecutor.setRecipe.selector);
        recipe = abi.decode(_arguments(data), (IRecipeExecutor.Step[]));
        assertEq(abi.encode(recipe), abi.encode(expected));
        data = output.readBytes(".setCallerCalldata");
        assertEq(bytes4(data), IRecipeExecutor.setCaller.selector);
        assertEq(abi.decode(_arguments(data), (address)), address(0x0102));

        bytes memory constructorArgs = output.readBytes(".constructorArgs");
        (address curator, address adapter) = abi.decode(constructorArgs, (address, address));
        assertEq(curator, address(0x0101));
        assertEq(adapter, address(0x0103));
        assertEq(output.keyExists(".factory"), hasFactory);
        assertEq(output.keyExists(".factoryCreateCalldata"), hasFactory);
        if (hasFactory) {
            assertEq(output.readAddress(".factory"), address(0x0104));
            data = output.readBytes(".factoryCreateCalldata");
            assertEq(bytes4(data), IImmutableFactory.create.selector);
            assertEq(abi.decode(_arguments(data), (bytes)), constructorArgs);
        }
    }

    function _arguments(bytes memory data) internal pure returns (bytes memory arguments) {
        arguments = new bytes(data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = data[i + 4];
        }
    }
}

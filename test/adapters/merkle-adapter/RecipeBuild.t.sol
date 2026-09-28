// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    OP_ADD,
    OP_APPROVE,
    OP_CALL,
    OP_MANAGE,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_SATURATING_SUB,
    SRC_INPUT,
    SRC_LITERAL,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LendingRecipe} from "script/recipes/LendingRecipe.sol";
import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";
import {
    ThreeFFacilityMock,
    ThreeFPositionManagerMock,
    ThreeFRequestFactoryMock,
    ThreeFRequestMock,
    ThreeFUnderlyingAssetMock
} from "test/mocks/ThreeFRequestMocks.sol";

contract RecipeBuildTest is Test {
    using stdJson for string;

    address internal builder;
    address internal _requestsFactory;
    address internal _facility;
    address internal _positionManager;

    function setUp() public {
        builder = address(new BuildRecipe());
        vm.mockCall(address(0x103), abi.encodeCall(IMerkleAdapter.account, ()), abi.encode(address(0x104)));
        _requestsFactory = address(new ThreeFRequestFactoryMock());
        _facility = address(new ThreeFFacilityMock());
        _positionManager = address(
            new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(address(0x405))), address(0x400))
        );
        vm.etch(address(0x600), address(new ThreeFRequestMock(address(0x400), "request-1")).code);
        ThreeFRequestMock(address(0x600)).setName("request-1");
        ThreeFRequestFactoryMock(_requestsFactory).set(address(0x600), true);
        ThreeFFacilityMock(_facility).setIntent(1, address(0x600), _positionManager, true);
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.REQUESTS_FACTORY, ()), abi.encode(_requestsFactory));
        vm.mockCall(address(0x602), abi.encodeCall(IThreeFPolicy.FACILITY, ()), abi.encode(_facility));
    }

    function test_LendingExampleRoundTrips() public {
        string memory outputPath = "out/RecipeBuild.lending.json";
        BuildRecipe(builder).run("script/recipes/examples/lending.json", outputPath);
        LendingRecipe.Config memory config;
        config.account = address(0x0104);
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
        config.supplyAmountOffsets = new uint256[](1);
        config.supplyAmountOffsets[0] = 36;
        config.borrowAmountOffsets = new uint256[](1);
        config.borrowAmountOffsets[0] = 872;
        config.purchaseAmountOffsets = new uint256[](1);
        config.purchaseAmountOffsets[0] = 4;
        (ExecutingRecipe.Recipe memory expected,) = LendingRecipe.build(
            config, LendingRecipe.Limits({maxSupplyLbtc: 1e8, maxTotalDebtUsdc: 50_000e6, minRwaPerUsdcWad: 0.99e18})
        );

        _assertOutput(outputPath, expected, true);
        vm.removeFile(outputPath);
    }

    function test_OverwritingOutputDoesNotRetainOptionalFactory() public {
        string memory outputPath = "out/RecipeBuild.overwrite.json";
        BuildRecipe(builder).run("script/recipes/examples/lending.json", outputPath);
        assertTrue(vm.readFile(outputPath).keyExists(".factoryCreateCalldata"));
        BuildRecipe(builder).run("script/recipes/examples/ll-executing.json", outputPath);
        string memory output = vm.readFile(outputPath);
        assertFalse(output.keyExists(".factory"));
        assertFalse(output.keyExists(".factoryCreateCalldata"));
        assertEq(output.readString(".template"), "ll-executing");
        vm.removeFile(outputPath);
    }

    function test_SourceBindingListsMustAlignWithLeavesBeforeWritingConfiguration() public {
        string memory inputPath = "out/RecipeBuild.bindings-input.json";
        string memory outputPath = "out/RecipeBuild.bindings-output.json";
        string[2] memory templates = [string("ll-executing"), "health-recovery"];
        for (uint256 i; i < templates.length; ++i) {
            vm.writeFile(inputPath, vm.readFile(string.concat("script/recipes/examples/", templates[i], ".json")));
            string memory malformed =
                '[{"name":"Source","capacity":{"target":"0x0000000000000000000000000000000000000420","data":"0x12345678","offset":0},"leaves":["0x0000000000000000000000000000000000000000000000000000000000000003"],"amountOffsets":[]}]';
            vm.writeJson(malformed, inputPath, ".sources");
            vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
            BuildRecipe(builder).run(inputPath, outputPath);
            assertFalse(vm.exists(outputPath));

            // One empty list is an explicit choice to use no substitutions for this leaf.
            vm.writeJson(vm.replace(malformed, '"amountOffsets":[]', '"amountOffsets":[[]]'), inputPath, ".sources");
            BuildRecipe(builder).run(inputPath, outputPath);
            assertTrue(vm.readFile(outputPath).keyExists(".setRecipeCalldata"));
            vm.removeFile(outputPath);
        }
        vm.removeFile(inputPath);
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
        ExecutingRecipe.Recipe memory recipe = _decodeRecipe(output.readBytes(".recipe"));
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
        _assertGroup(_action(recipe, sources[0]), 3, 1);
        _assertGroup(_action(recipe, sources[1]), 4, 1);
        _assertGroup(_action(recipe, requests[0]), 5, 3);
        _assertGroup(_action(recipe, requests[1]), 8, 3);
        _assertRecoveryLayout(output, recipe);
        _assertConstant(recipe, 1.25e18);
        _assertConstant(recipe, 1.5e18);
        _assertConstant(recipe, 100e6);
        _assertConstant(recipe, 1e30);
        vm.removeFile(outputPath);
    }

    function test_HealthClaimExampleHasSeparateClaimAndRepayLayout() public {
        string memory outputPath = "out/RecipeBuild.health-claim.json";
        BuildRecipe(builder).run("script/recipes/examples/health-claim.json", outputPath);
        string memory output = vm.readFile(outputPath);
        ExecutingRecipe.Recipe memory recipe = _decodeRecipe(output.readBytes(".recipe"));
        _assertOutput(outputPath, recipe, true);
        uint256[] memory claims = output.readUintArray(".claimCalls");
        assertEq(claims.length, 2);
        assertEq(output.readUintArray(".sourceCalls").length, 0);
        assertEq(output.readUintArray(".requestCalls").length, 0);
        assertLt(claims[0], claims[1]);
        assertLt(claims[1], output.readUint(".repayStep"));
        _assertGroup(_action(recipe, claims[0]), 7, 1);
        _assertGroup(_action(recipe, claims[1]), 10, 1);
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

    function test_ThreeFExecutingExampleUsesLiveAuthorizationAndGuardedLeaf() public {
        string memory outputPath = "out/RecipeBuild.3f-executing.json";
        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        string memory output = vm.readFile(outputPath);
        ExecutingRecipe.Recipe memory recipe = _decodeRecipe(output.readBytes(".recipe"));
        _assertOutput(outputPath, recipe, true);
        _assertExecutingLayout(output, recipe, 0);
        uint256 principal = output.readUint(".principalResult");
        _assertRead(
            recipe, principal, address(0x600), abi.encodeCall(IThreeFPushRequest.mintAuthorization, (address(0x104))), 0
        );
        assertEq(uint216(_amount(_action(recipe, output.readUint(".approveStep")))), principal);
        assertEq(uint216(_amount(_action(recipe, output.readUint(".operationStep")))), principal);
        _assertApproval(_action(recipe, output.readUint(".approveStep")), address(0x400), address(0x600), 1);
        _assertApproval(_action(recipe, output.readUint(".clearApprovalStep")), address(0x400), address(0x600), 1);
        _assertConstant(recipe, 100e6);
        assertEq(output.readAddress(".policy"), address(0x602));
        assertEq(output.readAddress(".underlyingAsset"), address(0x405));
        assertEq(output.readBytes(".setConsumerCalldata"), abi.encodeCall(IThreeFPolicy.setConsumer, (address(0x104))));
        assertEq(
            output.readBytes(".setMaxAssetsPerDurationCalldata"),
            abi.encodeCall(IThreeFPolicy.setMaxAssetsPerDuration, (address(0x405), 1000e6, 1 days))
        );
        assertEq(
            output.readBytes(".setMinYieldPerRequestCalldata"),
            abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (address(0x405), 1_000_000))
        );
        assertFalse(output.keyExists(".consumeStep"));
        _assertGuardedMint(output, recipe, principal);
        assertFalse(output.keyExists(".amountIn"));
        assertFalse(output.keyExists(".redeemStep"));
        vm.removeFile(outputPath);
    }

    function test_ThreeFDirectPolicyBuildsNativeMintAndExecutorConsumption() public {
        string memory inputPath = "out/RecipeBuild.3f-direct-input.json";
        string memory outputPath = "out/RecipeBuild.3f-direct-output.json";
        vm.writeFile(inputPath, vm.readFile("script/recipes/examples/3f-executing.json"));
        vm.writeJson("false", inputPath, ".policy.guardedMint");
        vm.writeJson('"0x0000000000000000000000000000000000000603"', inputPath, ".executor");
        BuildRecipe(builder).run(inputPath, outputPath);
        string memory output = vm.readFile(outputPath);
        ExecutingRecipe.Recipe memory recipe = _decodeRecipe(output.readBytes(".recipe"));
        _assertOutput(outputPath, recipe, true);
        _assertExecutingLayout(output, recipe, 0);
        assertFalse(output.readBool(".guardedMint"));
        assertEq(uint256(uint8(recipe.steps[output.readUint(".consumeStep")][0])), uint256(OP_CALL));
        assertEq(output.readAddress(".mintLeafTarget"), address(0x600));
        assertEq(output.readBytes(".mintLeafData"), abi.encodeCall(IThreeFPushRequest.mint, (0, 0)));
        bytes memory mask = new bytes(68);
        for (uint256 i = 4; i < mask.length; ++i) {
            mask[i] = 0xff;
        }
        assertEq(output.readBytes(".mintLeafMask"), mask);
        assertEq(
            output.readBytes32(".mintLeafHash"),
            MerkleAdapterVerifier.leaf(address(0x600), 0, output.readBytes(".mintLeafData"), mask)
        );
        assertEq(output.readBytes(".setConsumerCalldata"), abi.encodeCall(IThreeFPolicy.setConsumer, (address(0x603))));
        assertEq(output.readAddress(".underlyingAsset"), address(0x405));
        assertEq(
            output.readBytes(".setMaxAssetsPerDurationCalldata"),
            abi.encodeCall(IThreeFPolicy.setMaxAssetsPerDuration, (address(0x405), 1000e6, 1 days))
        );
        assertEq(
            output.readBytes(".setMinYieldPerRequestCalldata"),
            abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (address(0x405), 1_000_000))
        );
        uint256 calls;
        for (uint256 i; i < recipe.steps.length; ++i) {
            if (uint8(recipe.steps[i][0]) != OP_CALL) continue;
            ++calls;
            (address target, bytes memory data, uint256[] memory bindings) =
                abi.decode(Bytes.slice(recipe.steps[i], 1), (address, bytes, uint256[]));
            assertEq(target, address(0x602));
            assertEq(data, abi.encodeCall(IThreeFPolicy.consume, (address(0x600), 0, 0)));
            assertEq(bindings.length, 2);
            assertEq(bindings[0] >> 224, 36);
            assertEq(uint216(bindings[0]), output.readUint(".principalResult"));
            assertEq(bindings[1] >> 224, 68);
        }
        assertEq(calls, 1);
        vm.writeJson('"0x0000000000000000000000000000000000000000"', inputPath, ".executor");
        vm.expectRevert(BuildRecipe.InvalidPolicyConsumer.selector);
        BuildRecipe(builder).run(inputPath, outputPath);
        vm.removeFile(inputPath);
        vm.removeFile(outputPath);
    }

    function test_ThreeFPolicyResolutionRejectsBeforeWritingOutput() public {
        string memory outputPath = "out/RecipeBuild.3f-invalid-request.json";
        ThreeFRequestFactoryMock(_requestsFactory).set(address(0x600), false);

        vm.expectRevert(IThreeFPolicy.InvalidRequest.selector);
        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        assertFalse(vm.exists(outputPath));
    }

    function test_ThreeFInvalidRequestNameRejectsBeforeWritingOutput() public {
        string memory outputPath = "out/RecipeBuild.3f-invalid-name.json";
        string[3] memory names = [string("request"), "request-", "requests-1"];
        for (uint256 i; i < names.length; ++i) {
            ThreeFRequestMock(address(0x600)).setName(names[i]);
            vm.expectRevert(IThreeFPolicy.InvalidRequestName.selector);
            BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
            assertFalse(vm.exists(outputPath));
        }
        ThreeFRequestMock(address(0x600)).setName("request-1a");
        vm.expectRevert(Strings.StringsInvalidChar.selector);
        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        assertFalse(vm.exists(outputPath));
    }

    function test_ThreeFRequestMismatchRejectsBeforeWritingOutput() public {
        string memory outputPath = "out/RecipeBuild.3f-request-mismatch.json";
        ThreeFFacilityMock(_facility).setIntent(1, address(0x601), _positionManager, true);
        vm.expectRevert(IThreeFPolicy.RequestMismatch.selector);
        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        assertFalse(vm.exists(outputPath));
    }

    function test_ThreeFUnsupportedTargetRejectsBeforeWritingOutput() public {
        string memory outputPath = "out/RecipeBuild.3f-unsupported-target.json";
        ThreeFFacilityMock(_facility).setIntent(1, address(0x600), _positionManager, false);
        vm.expectRevert(IThreeFPolicy.UnsupportedTarget.selector);
        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        assertFalse(vm.exists(outputPath));
    }

    function test_ThreeFZeroCollateralUnderlyingRejectsBeforeWritingOutput() public {
        string memory outputPath = "out/RecipeBuild.3f-zero-underlying.json";
        ThreeFFacilityMock(_facility)
            .setIntent(
                1,
                address(0x600),
                address(
                    new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(address(0))), address(0x400))
                ),
                true
            );
        vm.expectRevert(IThreeFPolicy.InvalidAsset.selector);
        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        assertFalse(vm.exists(outputPath));
    }

    function test_ExecutingAddsApprovedPushBeforeVenueSources() public {
        string memory inputPath = "out/RecipeBuild.push-input.json";
        string memory outputPath = "out/RecipeBuild.push-output.json";
        vm.writeFile(inputPath, vm.readFile("script/recipes/examples/3f-executing.json"));
        vm.writeJson(string.concat('"', vm.toString(bytes32(uint256(99))), '"'), inputPath, ".leaves.push");
        BuildRecipe(builder).run(inputPath, outputPath);
        string memory output = vm.readFile(outputPath);
        ExecutingRecipe.Recipe memory recipe = _decodeRecipe(output.readBytes(".recipe"));
        _assertOutput(outputPath, recipe, true);
        uint256[] memory calls = output.readUintArray(".sourceCalls");
        assertEq(calls.length, 3);
        _assertGroup(_action(recipe, calls[0]), 99, 1);
        _assertGroup(_action(recipe, calls[1]), 3, 1);
        _assertGroup(_action(recipe, calls[2]), 4, 1);
        uint256[] memory amounts = output.readUintArray(".sourceAmountResults");
        (, uint256 capacity) = abi.decode(Bytes.slice(recipe.steps[amounts[0]], 1), (uint256, uint256));
        assertEq(uint256(uint8(recipe.steps[uint216(capacity)][0])), uint256(OP_SATURATING_SUB));
        (uint256 balance, uint256 reserved) =
            abi.decode(Bytes.slice(recipe.steps[uint216(capacity)], 1), (uint256, uint256));
        _assertRead(recipe, uint216(balance), address(0x400), abi.encodeCall(IERC20.balanceOf, (address(0x103))), 0);
        assertEq(uint256(uint8(recipe.steps[uint216(reserved)][0])), uint256(OP_MAX));
        (uint256 locked, uint256 pending) =
            abi.decode(Bytes.slice(recipe.steps[uint216(reserved)], 1), (uint256, uint256));
        _assertRead(recipe, uint216(pending), address(0x103), abi.encodeCall(IMerkleAdapter.pendingDeallocation, ()), 0);
        assertEq(uint256(uint8(recipe.steps[uint216(locked)][0])), uint256(OP_ADD));
        (uint256 released, uint256 staged) =
            abi.decode(Bytes.slice(recipe.steps[uint216(locked)], 1), (uint256, uint256));
        _assertRead(recipe, uint216(released), address(0x103), abi.encodeCall(IMerkleAdapter.releasedLiquidity, ()), 0);
        _assertRead(recipe, uint216(staged), address(0x103), abi.encodeCall(IMerkleAdapter.stagedLiquidity, ()), 0);
        assertEq(output.readString(".stages[0].name"), "Fund strategy");
        vm.removeFile(inputPath);
        vm.removeFile(outputPath);
    }

    function test_LLExecutingExampleMapsInputsSwapAndRedemption() public {
        string memory outputPath = "out/RecipeBuild.ll-executing.json";
        BuildRecipe(builder).run("script/recipes/examples/ll-executing.json", outputPath);
        string memory output = vm.readFile(outputPath);
        ExecutingRecipe.Recipe memory recipe = _decodeRecipe(output.readBytes(".recipe"));
        _assertOutput(outputPath, recipe, false);
        _assertExecutingLayout(output, recipe, 2);
        uint256 amountIn = abi.decode(output.readBytes(".amountIn"), (uint256));
        uint256 amountOut = abi.decode(output.readBytes(".amountOut"), (uint256));
        assertEq(uint256(uint8(amountIn >> 216)), uint256(SRC_INPUT));
        assertEq(uint256(uint8(amountOut >> 216)), uint256(SRC_INPUT));
        assertEq(uint216(amountIn), 0);
        assertEq(uint216(amountOut), 1);
        assertEq(abi.encode(_amount(_action(recipe, output.readUint(".approveStep")))), abi.encode(amountOut));
        assertEq(abi.encode(_amount(_action(recipe, output.readUint(".operationStep")))), abi.encode(amountIn));
        _assertApproval(_action(recipe, output.readUint(".approveStep")), address(0x400), address(0x302), 1);
        _assertApproval(_action(recipe, output.readUint(".clearApprovalStep")), address(0x400), address(0x302), 1);
        uint256 redeem = output.readUint(".redeemStep");
        _assertGroup(_action(recipe, redeem), 6, 1);
        assertEq(abi.encode(_amount(_action(recipe, redeem))), abi.encode(amountIn));
        assertLt(output.readUint(".clearApprovalStep"), output.readUint(".redeemApproveStep"));
        assertLt(output.readUint(".redeemApproveStep"), redeem);
        assertLt(redeem, output.readUint(".redeemClearApprovalStep"));
        _assertApproval(_action(recipe, output.readUint(".redeemApproveStep")), address(0x303), address(0x305), 5);
        _assertApproval(_action(recipe, output.readUint(".redeemClearApprovalStep")), address(0x303), address(0x305), 5);
        assertEq(abi.encode(_amount(_action(recipe, output.readUint(".redeemApproveStep")))), abi.encode(amountIn));
        _assertZeroReference(recipe, _amount(_action(recipe, output.readUint(".redeemClearApprovalStep"))));
        uint256 receiptQueries;
        for (uint256 i; i < recipe.queries.length; ++i) {
            (address queryTarget, bytes memory queryData,,) =
                abi.decode(recipe.queries[i], (address, bytes, uint256[], uint256));
            if (queryTarget != address(0x304)) continue;
            assertEq(queryData, abi.encodeCall(IERC20.balanceOf, (address(0x104))));
            ++receiptQueries;
        }
        assertEq(receiptQueries, 1);
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
        ExecutingRecipe.Recipe memory emptyLeaves = _decodeRecipe(output.readBytes(".recipe"));
        _assertOutput(outputPath, emptyLeaves, false);
        _assertExecutingLayout(output, emptyLeaves, 2);
        _assertNoRedemption(output, emptyLeaves);

        vm.writeFile(inputPath, vm.replace(source, '"redemption": {', '"_disabledRedemption": {'));
        assertFalse(vm.readFile(inputPath).keyExists(".redemption"));
        BuildRecipe(builder).run(inputPath, outputPath);
        output = vm.readFile(outputPath);
        ExecutingRecipe.Recipe memory absent = _decodeRecipe(output.readBytes(".recipe"));
        assertEq(abi.encode(absent), abi.encode(emptyLeaves));
        _assertOutput(outputPath, absent, false);
        _assertNoRedemption(output, absent);

        BuildRecipe(builder).run("script/recipes/examples/3f-executing.json", outputPath);
        output = vm.readFile(outputPath);
        assertTrue(output.keyExists(".principalResult"));
        assertFalse(output.keyExists(".amountIn"));
        assertFalse(output.keyExists(".amountOut"));
        assertFalse(output.keyExists(".redeemStep"));
        vm.removeFile(inputPath);
        vm.removeFile(outputPath);
    }

    function _action(ExecutingRecipe.Recipe memory recipe, uint256 runtimeIndex) internal pure returns (bytes memory) {
        return recipe.steps[ExecutingRecipe.runtimeSteps(recipe)[runtimeIndex]];
    }

    function _amount(bytes memory step) internal pure returns (uint256) {
        return abi.decode(Bytes.slice(step, 1), (uint256));
    }

    function _assertGroup(bytes memory step, uint256 firstLeaf, uint256 count) internal pure {
        assertEq(uint256(uint8(step[0])), uint256(OP_MANAGE));
        (, bytes32[] memory leaves,) = abi.decode(Bytes.slice(step, 1), (uint256, bytes32[], uint256[][]));
        assertEq(leaves.length, count);
        assertEq(leaves[0], bytes32(firstLeaf));
    }

    function _assertExecutingLayout(string memory output, ExecutingRecipe.Recipe memory recipe, uint256 expectedInputs)
        internal
        view
    {
        uint256[] memory calls = output.readUintArray(".sourceCalls");
        uint256[] memory amounts = output.readUintArray(".sourceAmountResults");
        assertEq(calls.length, 2);
        assertEq(amounts.length, 2);
        assertLt(calls[0], calls[1]);
        assertLt(calls[1], output.readUint(".approveStep"));
        assertLt(output.readUint(".approveStep"), output.readUint(".operationStep"));
        assertLt(output.readUint(".operationStep"), output.readUint(".clearApprovalStep"));
        for (uint256 i; i < calls.length; ++i) {
            _assertGroup(_action(recipe, calls[i]), 3 + i, 1);
            assertEq(uint216(_amount(_action(recipe, calls[i]))), amounts[i]);
            assertEq(uint256(uint8(recipe.steps[amounts[i]][0])), uint256(OP_MIN));
        }
        (, uint256 capacity) = abi.decode(Bytes.slice(recipe.steps[amounts[0]], 1), (uint256, uint256));
        _assertRead(
            recipe,
            uint216(capacity),
            address(0x420),
            abi.encodeWithSignature("liquidity(address,address)", address(0x421), address(0x104)),
            0
        );
        (, capacity) = abi.decode(Bytes.slice(recipe.steps[amounts[1]], 1), (uint256, uint256));
        _assertRead(
            recipe,
            uint216(capacity),
            address(0x423),
            abi.encodeWithSignature(
                "liquidityWithBorrow(address,address,address)", address(0x422), address(0x400), address(0x104)
            ),
            0
        );
        _assertGroup(_action(recipe, output.readUint(".operationStep")), 2, 1);
        _assertZeroReference(recipe, _amount(_action(recipe, output.readUint(".clearApprovalStep"))));
        uint256 inputs;
        for (uint256 i; i < calls.length + 3; ++i) {
            uint256 amount = _amount(_action(recipe, i));
            if (uint8(amount >> 216) == SRC_INPUT && uint216(amount) + 1 > inputs) {
                inputs = uint216(amount) + 1;
            }
        }
        assertEq(inputs, expectedInputs);
    }

    function _assertApproval(bytes memory step, address token, address spender, uint256 leaf) internal pure {
        assertEq(uint256(uint8(step[0])), uint256(OP_APPROVE));
        (, address actualToken, address actualSpender, bytes32 actualLeaf) =
            abi.decode(Bytes.slice(step, 1), (uint256, address, address, bytes32));
        assertEq(actualToken, token);
        assertEq(actualSpender, spender);
        assertEq(actualLeaf, bytes32(leaf));
    }

    function _assertRead(
        ExecutingRecipe.Recipe memory recipe,
        uint256 index,
        address target,
        bytes memory data,
        uint256 offset
    ) internal pure {
        assertEq(uint256(uint8(recipe.steps[index][0])), uint256(OP_READ));
        (address queryTarget, bytes memory queryData,, uint256 queryOffset) = abi.decode(
            recipe.queries[abi.decode(Bytes.slice(recipe.steps[index], 1), (uint256))],
            (address, bytes, uint256[], uint256)
        );
        assertEq(queryTarget, target);
        assertEq(queryData, data);
        assertEq(queryOffset, offset);
    }

    function _assertZeroReference(ExecutingRecipe.Recipe memory, uint256 value) internal pure {
        assertEq(uint256(uint8(value >> 216)), uint256(SRC_LITERAL));
        assertEq(uint216(value), 0);
    }

    function _assertConstant(ExecutingRecipe.Recipe memory recipe, uint256 value) internal pure {
        for (uint256 i; i < recipe.steps.length; ++i) {
            bytes memory step = recipe.steps[i];
            if (uint8(step[0]) == OP_READ || uint8(step[0]) == OP_CALL) {
                continue;
            }
            if (uint8(step[0]) == OP_MANAGE || uint8(step[0]) == OP_APPROVE) {
                if (_literalMatches(_amount(step), value)) return;
            } else if (uint8(step[0]) == OP_MUL_DIV) {
                (uint256 a, uint256 b, uint256 c) = abi.decode(Bytes.slice(step, 1), (uint256, uint256, uint256));
                if (_literalMatches(a, value) || _literalMatches(b, value) || _literalMatches(c, value)) return;
            } else {
                (uint256 a, uint256 b) = abi.decode(Bytes.slice(step, 1), (uint256, uint256));
                if (_literalMatches(a, value) || _literalMatches(b, value)) return;
            }
        }
        revert("Missing configured limit");
    }

    function _literalMatches(uint256 operand, uint256 value) internal pure returns (bool) {
        return uint8(operand >> 216) == SRC_LITERAL && uint216(operand) == value;
    }

    function _assertNoRedemption(string memory output, ExecutingRecipe.Recipe memory recipe) internal view {
        assertFalse(output.keyExists(".redeemStep"));
        assertFalse(output.keyExists(".redeemApproveStep"));
        assertFalse(output.keyExists(".redeemClearApprovalStep"));
        uint256 managed;
        uint256 approvals;
        for (uint256 i; i < recipe.steps.length; ++i) {
            if (uint8(recipe.steps[i][0]) == OP_MANAGE) ++managed;
            if (uint8(recipe.steps[i][0]) == OP_APPROVE) ++approvals;
        }
        assertEq(managed, 3);
        assertEq(approvals, 2);
    }

    function _assertRecoveryLayout(string memory output, ExecutingRecipe.Recipe memory recipe) internal pure {
        assertEq(uint256(uint8(_action(recipe, output.readUint(".approveStep"))[0])), uint256(OP_APPROVE));
        assertEq(uint256(uint8(_action(recipe, output.readUint(".clearApprovalStep"))[0])), uint256(OP_APPROVE));
        _assertGroup(_action(recipe, output.readUint(".repayStep")), 2, 1);
        uint256[] memory runtimeSteps = ExecutingRecipe.runtimeSteps(recipe);
        for (uint256 i; i < runtimeSteps.length; ++i) {
            assertTrue(uint8(_amount(recipe.steps[runtimeSteps[i]]) >> 216) != SRC_INPUT);
        }
    }

    function _assertOutput(string memory path, ExecutingRecipe.Recipe memory expected, bool hasFactory) internal {
        string memory output = vm.readFile(path);
        assertEq(output.readAddress(".curator"), address(0x0101));
        assertEq(output.readAddress(".provider"), address(0x0102));
        assertEq(output.readAddress(".adapter"), address(0x0103));
        assertEq(output.readAddress(".account"), address(0x0104));
        assertEq(output.readBytes32(".recipeHash"), keccak256(abi.encode(expected.queries, expected.steps)));
        assertEq(output.readUintArray(".runtimeSteps"), ExecutingRecipe.runtimeSteps(expected));
        assertEq(output.readUint(".stepCount"), expected.steps.length);
        ExecutingRecipe.Recipe memory recipe = _decodeRecipe(output.readBytes(".recipe"));
        assertEq(abi.encode(recipe.queries, recipe.steps), abi.encode(expected.queries, expected.steps));

        bytes memory data = output.readBytes(".setRecipeCalldata");
        assertEq(bytes4(data), IRecipeExecutor.setRecipe.selector);
        recipe = _decodeRecipe(_arguments(data));
        assertEq(abi.encode(recipe.queries, recipe.steps), abi.encode(expected.queries, expected.steps));
        data = output.readBytes(".setCallerCalldata");
        assertEq(bytes4(data), IRecipeExecutor.setCaller.selector);
        assertEq(abi.decode(_arguments(data), (address)), address(0x0102));

        bytes memory constructorArgs = output.readBytes(".constructorArgs");
        (address curator, address account) = abi.decode(constructorArgs, (address, address));
        assertEq(curator, address(0x0101));
        assertEq(account, address(0x0104));
        assertEq(output.keyExists(".factory"), hasFactory);
        assertEq(output.keyExists(".factoryCreateCalldata"), hasFactory);
        if (hasFactory) {
            assertEq(output.readAddress(".factory"), address(0x0104));
            data = output.readBytes(".factoryCreateCalldata");
            assertEq(bytes4(data), IImmutableFactory.create.selector);
            assertEq(abi.decode(_arguments(data), (bytes)), constructorArgs);
        }
    }

    function _decodeRecipe(bytes memory encoded) internal pure returns (ExecutingRecipe.Recipe memory recipe) {
        (recipe.queries, recipe.steps) = abi.decode(encoded, (bytes[], bytes[]));
    }

    function _arguments(bytes memory data) internal pure returns (bytes memory arguments) {
        arguments = new bytes(data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = data[i + 4];
        }
    }

    /// @dev The published leaf must come from ThreeFGuardedMint, and the Manage bindings must match its offsets.
    function _assertGuardedMint(string memory output, ExecutingRecipe.Recipe memory recipe, uint256 principal)
        internal
        view
    {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: address(0x104), asset: address(0x400), policy: address(0x602), request: address(0x600)
            })
        );
        assertEq(output.readBytes(".mintLeafData"), leaf.data);
        assertEq(output.readBytes(".mintLeafMask"), leaf.dataMask);
        assertEq(
            output.readBytes32(".mintLeafHash"), MerkleAdapterVerifier.leaf(address(0x104), 0, leaf.data, leaf.dataMask)
        );
        bytes memory step = _action(recipe, output.readUint(".operationStep"));
        (, bytes32[] memory leaves, uint256[][] memory bindings) =
            abi.decode(Bytes.slice(step, 1), (uint256, bytes32[], uint256[][]));
        assertEq(leaves.length, 1);
        assertEq(bindings[0].length, 4);
        assertEq(bindings[0][0] >> 224, leaf.consumeAssets);
        assertEq(uint216(bindings[0][0]), principal);
        assertEq(bindings[0][1] >> 224, leaf.consumeYield);
        assertEq(bindings[0][2] >> 224, leaf.mintPrincipal);
        assertEq(uint216(bindings[0][2]), principal);
        assertEq(bindings[0][3] >> 224, leaf.mintYield);
        assertEq(uint256(uint8(bindings[0][1] >> 216)), uint256(SRC_RESULT));
        assertEq(uint256(uint8(bindings[0][3] >> 216)), uint256(SRC_RESULT));
    }
}

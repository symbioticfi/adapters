// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {AsyncClaimTokenMock} from "./RecipeClaims.t.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ClaimRecipe} from "script/recipes/ClaimRecipe.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";

/// @dev Real executor and account routing against local settlement fixtures; no live issuer evidence.
contract RecipeConditionalClaimsTest is CapabilityTestBase {
    address internal _asset;
    address internal _source;
    address internal _executor;
    IMerkleAccount.Action[] internal _actions;
    ExecutingRecipe.Recipe internal _recipe;

    function setUp() public {
        _asset = address(new AsyncClaimTokenMock(6));
        _source = address(new ConditionalClaimSource(_asset));
        _deployAdapter(_asset);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        AsyncClaimTokenMock(_asset).mint(_source, 100);
        AsyncClaimTokenMock(_asset).mint(account, 13);
        bytes32[2] memory leaves;
        for (uint256 i; i < 2; ++i) {
            bytes memory data = abi.encodeCall(ConditionalClaimSource.claim, (i, uint256(999), account));
            bytes memory mask = new bytes(data.length);
            for (uint256 j = 36; j < 68; ++j) {
                mask[j] = 0xff;
            }
            _actions.push(
                IMerkleAccount.Action({target: _source, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)})
            );
            leaves[i] = ActionMasker.mask(_source, 0, data, mask);
            MerkleAccount(payable(account)).grantRole(leaves[i], _executor);
        }
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        _actions[0].proof.push(leaves[1]);
        _actions[1].proof.push(leaves[0]);
    }

    function test_ConditionalJSONEmptyProgramSucceedsWithZeroGatedMalformedRuntime() public {
        _recipe = _buildJSON(",\"idleWhenEmpty\":true");
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = hex"deadbeef";
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 13);
        assertEq(ConditionalClaimSource(_source).calls(), 0);
    }

    function test_ConditionalJSONPreservesDefaultQueriesAndAllGroupChecks() public {
        ExecutingRecipe.Recipe memory legacy = _buildJSON("");
        ExecutingRecipe.Recipe memory explicitDefault = _buildJSON(",\"idleWhenEmpty\":false");
        assertEq(abi.encode(legacy.queries, legacy.steps), abi.encode(explicitDefault.queries, explicitDefault.steps));
        ExecutingRecipe.Recipe memory conditional = _buildJSON(",\"idleWhenEmpty\":true");
        assertEq(abi.encode(conditional.queries), abi.encode(legacy.queries));
        assertEq(conditional.steps.length + 1, legacy.steps.length);
        for (uint256 i; i < conditional.steps.length; ++i) {
            assertEq(conditional.steps[i], legacy.steps[i]);
        }
    }

    function test_ConditionalLibraryPreservesEveryLegacyInstructionExceptProgressFooter() public view {
        ClaimRecipe.Claim[] memory claims = _claims();
        (ExecutingRecipe.Recipe memory legacy, uint256[] memory legacyCalls) = ClaimRecipe.build(account, claims);
        (ExecutingRecipe.Recipe memory conditional, uint256[] memory conditionalCalls) =
            ClaimRecipe.buildConditional(account, claims);
        assertEq(abi.encode(conditional.queries), abi.encode(legacy.queries));
        assertEq(abi.encode(conditionalCalls), abi.encode(legacyCalls));
        assertEq(conditional.steps.length + 1, legacy.steps.length);
        for (uint256 i; i < conditional.steps.length; ++i) {
            assertEq(conditional.steps[i], legacy.steps[i]);
        }
    }

    function test_ConditionalEmptyLibraryProgramCanRunRepeatedlyWhileLegacyStillReverts() public {
        ClaimRecipe.Claim[] memory claims = _claims();
        (_recipe,) = ClaimRecipe.build(account, claims);
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
        bytes[] memory runtime = new bytes[](2);
        runtime[0] = hex"deadbeef";
        runtime[1] = hex"deadbeef";
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _installConditional(claims);
        assertEq(_execute(runtime).length, _recipe.steps.length);
        assertEq(_execute(runtime).length, _recipe.steps.length);
        assertEq(IERC20(_asset).balanceOf(account), 13);
        assertEq(ConditionalClaimSource(_source).calls(), 0);
    }

    function testFuzz_ConditionalMixedGroupsPreserveRuntimeAlignmentAndCaps(uint64 ready, bool firstReady) public {
        ready = uint64(bound(ready, 1, 100));
        uint256 active = firstReady ? 0 : 1;
        ConditionalClaimSource(_source).configure(active, ready, 0, 0);
        _installConditional(_claims());
        bytes[] memory runtime = _runtime();
        runtime[1 - active] = hex"deadbeef";
        _execute(runtime);
        uint256 selected = ready < 5 ? ready : 5;
        assertEq(IERC20(_asset).balanceOf(account), 13 + selected);
        assertEq(ConditionalClaimSource(_source).ready(active), ready - selected);
        assertEq(ConditionalClaimSource(_source).calls(), 1);
        assertEq(ConditionalClaimSource(_source).lastId(), active);
    }

    function test_ConditionalZeroRequestIdUsesIndependentPositiveReadiness() public {
        ConditionalClaimSource(_source).configure(0, 7, 0, 0);
        _installConditional(_claims());
        bytes[] memory runtime = _runtime();
        runtime[1] = hex"deadbeef";
        _execute(runtime);
        assertEq(ConditionalClaimSource(_source).lastId(), 0);
        assertEq(ConditionalClaimSource(_source).calls(), 1);
        assertEq(ConditionalClaimSource(_source).ready(0), 2);
        assertEq(IERC20(_asset).balanceOf(account), 18);
    }

    function test_ConditionalEmptyProgramStillRequiresReadinessQueries() public {
        _installConditional(_claims());
        ConditionalClaimSource(_source).setUnavailable(true);
        bytes[] memory runtime = new bytes[](2);
        vm.expectRevert(ConditionalClaimSource.ReadUnavailable.selector);
        _execute(runtime);
        assertEq(ConditionalClaimSource(_source).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 13);
    }

    function test_ConditionalZeroGateStillRequiresOutputReads() public {
        _installConditional(_claims());
        vm.mockCallRevert(
            _asset,
            abi.encodeCall(IERC20.balanceOf, (account)),
            abi.encodeWithSelector(ConditionalClaimSource.ReadUnavailable.selector)
        );
        bytes[] memory runtime = new bytes[](2);
        vm.expectRevert(ConditionalClaimSource.ReadUnavailable.selector);
        _execute(runtime);
        assertEq(ConditionalClaimSource(_source).calls(), 0);
    }

    function testFuzz_ConditionalActiveFailuresRollBackEarlierGroup(uint8 fault) public {
        fault = uint8(bound(fault, 0, 3));
        ClaimRecipe.Claim[] memory claims = _claims();
        ConditionalClaimSource(_source).configure(0, 4, 0, 0);
        ConditionalClaimSource(_source).configure(1, 10, fault == 0 ? 1 : 0, fault == 1 ? 1 : fault == 2 ? 5 : 0);
        if (fault == 2) claims[1].outputs[0].denominator = 100;
        _installConditional(claims);
        bytes[] memory runtime = _runtime();
        if (fault == 3) runtime[1] = hex"deadbeef";
        if (fault < 3) vm.expectRevert(IRecipes.CheckFailed.selector);
        else vm.expectRevert();
        _execute(runtime);
        assertEq(ConditionalClaimSource(_source).ready(0), 4);
        assertEq(ConditionalClaimSource(_source).ready(1), 10);
        assertEq(ConditionalClaimSource(_source).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 13);
        assertEq(IERC20(_asset).balanceOf(_source), 100);
    }

    function _claims() internal view returns (ClaimRecipe.Claim[] memory claims) {
        claims = new ClaimRecipe.Claim[](2);
        for (uint256 i; i < claims.length; ++i) {
            claims[i].claimable = ExecutingRecipe.query(
                ExecutingRecipe.Read({
                    target: _source, data: abi.encodeCall(ConditionalClaimSource.ready, (i)), offset: 0
                })
            );
            claims[i].maxAmount = 5;
            claims[i].leaves = new bytes32[](1);
            claims[i].leaves[0] = _leaf(i);
            claims[i].amountOffsets = new uint256[][](1);
            claims[i].amountOffsets[0] = new uint256[](1);
            claims[i].amountOffsets[0][0] = 36;
            claims[i].outputs = new ClaimRecipe.Output[](1);
            claims[i].outputs[0] = ClaimRecipe.Output({
                token: _asset,
                balance: ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
                minNumerator: 1,
                denominator: 1
            });
        }
    }

    function _installConditional(ClaimRecipe.Claim[] memory claims) internal {
        (_recipe,) = ClaimRecipe.buildConditional(account, claims);
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
    }

    function _runtime() internal view returns (bytes[] memory runtime) {
        runtime = new bytes[](2);
        for (uint256 i; i < runtime.length; ++i) {
            IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
            actions[0] = _actions[i];
            runtime[i] = abi.encode(actions);
        }
    }

    function _buildJSON(string memory idleSetting) internal returns (ExecutingRecipe.Recipe memory recipe) {
        string memory inputPath = string.concat("out/RecipeConditionalClaims.", vm.toString(msg.sig), ".input.json");
        string memory outputPath = string.concat("out/RecipeConditionalClaims.", vm.toString(msg.sig), ".output.json");
        vm.writeFile(
            inputPath,
            string.concat(
                '{"curator":"',
                vm.toString(address(this)),
                '","provider":"',
                vm.toString(address(this)),
                '","adapter":"',
                vm.toString(address(adapter)),
                '","template":"claim"',
                idleSetting,
                ",",
                '"claims":[{"claimable":{"target":"',
                vm.toString(_source),
                '","data":"',
                vm.toString(abi.encodeCall(ConditionalClaimSource.ready, (uint256(0)))),
                '","offset":0},"maxAmount":5,"leaves":["',
                vm.toString(_leaf(0)),
                '"],"amountOffsets":[[36]],"outputs":[{"token":"',
                vm.toString(_asset),
                '","minNumerator":1,"denominator":1}]}]}'
            )
        );
        BuildRecipe(deployCode("BuildRecipe.s.sol:BuildRecipe")).run(inputPath, outputPath);
        (recipe.queries, recipe.steps) =
            abi.decode(vm.parseJsonBytes(vm.readFile(outputPath), ".recipe"), (bytes[], bytes[]));
        vm.removeFile(inputPath);
        vm.removeFile(outputPath);
    }

    function _leaf(uint256 index) internal view returns (bytes32) {
        return ActionMasker.mask(_actions[index].target, 0, _actions[index].data, _actions[index].dataMask);
    }

    function _execute(bytes[] memory runtime) internal returns (uint256[] memory) {
        return RecipeExecutor(_executor).execute(_recipe.queries, _recipe.steps, new uint256[](0), runtime);
    }
}

contract ConditionalClaimSource {
    error ReadUnavailable();

    address public immutable asset;
    mapping(uint256 => uint256) internal _ready;
    uint256 public calls;
    uint256 public lastId;
    mapping(uint256 => uint256) public extraDebit;
    mapping(uint256 => uint256) public shortfall;
    bool public unavailable;

    constructor(address newAsset) {
        asset = newAsset;
    }

    function configure(uint256 id, uint256 amount, uint256 newExtraDebit, uint256 newShortfall) public {
        _ready[id] = amount;
        extraDebit[id] = newExtraDebit;
        shortfall[id] = newShortfall;
    }

    function setUnavailable(bool newUnavailable) public {
        unavailable = newUnavailable;
    }

    function ready(uint256 id) public view returns (uint256) {
        if (unavailable) revert ReadUnavailable();
        return _ready[id];
    }

    function claim(uint256 id, uint256 amount, address recipient) public {
        _ready[id] -= amount + extraDebit[id];
        ++calls;
        lastId = id;
        IERC20(asset).transfer(recipient, amount - shortfall[id]);
    }
}

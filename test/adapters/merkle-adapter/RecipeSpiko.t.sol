// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {SpikoRedemption} from "script/recipes/SpikoRedemption.sol";

/// @dev Local issuer fixture checks request-ID uniqueness through the production account and executor.
contract RecipeSpikoTest is CapabilityTestBase {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    address internal _token;
    address internal _redemption;
    address internal _outputAsset;
    address internal _executor;
    bytes internal _recipe;
    uint256 internal _requestCall;

    function setUp() public {
        _token = address(new SpikoRecipeToken());
        _outputAsset = makeAddr("outputAsset");
        _redemption = address(new SpikoRecipeIssuer(_outputAsset));
        _deployAdapter(_token);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        SpikoRecipeToken(_token).mint(account, 300);
        IMerkleAccount.Action memory request = SpikoRedemption.action(_token, _redemption, _outputAsset, 100, 0);
        bytes32 leaf = ActionMasker.mask(request.target, request.value, request.data, request.dataMask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, _executor);
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(4);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        _requestCall = builder.manage(leaves, builder.literal(1));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
    }

    function testFuzz_EqualAmountRequestsReuseLeafWithFreshSalts(bytes32 first, bytes32 second) public {
        vm.assume(first != second);
        _execute(SpikoRedemption.action(_token, _redemption, _outputAsset, 100, first));
        _execute(SpikoRedemption.action(_token, _redemption, _outputAsset, 100, second));
        assertEq(SpikoRecipeToken(_token).balanceOf(account), 100);
        assertEq(SpikoRecipeToken(_token).balanceOf(_redemption), 200);
        assertEq(SpikoRecipeIssuer(_redemption).requests(), 2);
    }

    function test_ReusedAmountAndSaltRevertsWithoutLosingTokens() public {
        IMerkleAccount.Action memory request = SpikoRedemption.action(_token, _redemption, _outputAsset, 100, 0);
        _execute(request);
        vm.expectRevert(SpikoRecipeIssuer.DuplicateRequest.selector);
        _execute(request);
        assertEq(SpikoRecipeToken(_token).balanceOf(account), 200);
        assertEq(SpikoRecipeIssuer(_redemption).requests(), 1);
    }

    function testFuzz_RouteAndAmountRemainPinned(uint8 word) public {
        word = uint8(bound(word, 0, 4));
        IMerkleAccount.Action memory request = SpikoRedemption.action(_token, _redemption, _outputAsset, 100, 0);
        // Redemption, amount, dynamic offset, bytes length and output asset must all stay pinned.
        request.data[4 + 32 * word + 31] ^= bytes1(uint8(1));
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(request);
        assertEq(SpikoRecipeToken(_token).balanceOf(account), 300);
        assertEq(SpikoRecipeIssuer(_redemption).requests(), 0);
    }

    function _execute(IMerkleAccount.Action memory request) internal {
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        bytes[] memory runtime =
            new bytes[](ExecutingRecipe.runtimeSteps(ExecutingRecipe.Recipe({queries: queries, steps: steps})).length);
        IMerkleAccount.Action[] memory requests = new IMerkleAccount.Action[](1);
        requests[0] = request;
        runtime[_requestCall] = abi.encode(requests);
        RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), runtime);
    }
}

contract SpikoRecipeToken is ERC20 {
    constructor() ERC20("Spiko recipe fixture", "SPK") {}

    function mint(address recipient, uint256 amount) public {
        _mint(recipient, amount);
    }

    function transferAndCall(address recipient, uint256 amount, bytes calldata data) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        SpikoRecipeIssuer(recipient).onTransferReceived(msg.sender, amount, data);
        return true;
    }
}

contract SpikoRecipeIssuer {
    error DuplicateRequest();
    error InvalidOutputAsset();

    address public immutable outputAsset;
    uint256 public requests;
    mapping(bytes32 id => bool requested) public requested;

    constructor(address newOutputAsset) {
        outputAsset = newOutputAsset;
    }

    function onTransferReceived(address sender, uint256 amount, bytes calldata data) public {
        (address output, bytes32 salt) = abi.decode(data, (address, bytes32));
        if (output != outputAsset) revert InvalidOutputAsset();
        bytes32 id = keccak256(abi.encodePacked(sender, msg.sender, output, amount, salt));
        if (requested[id]) revert DuplicateRequest();
        requested[id] = true;
        ++requests;
    }
}

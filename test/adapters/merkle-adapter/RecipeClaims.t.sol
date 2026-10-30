// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {ClaimRecipe} from "script/recipes/ClaimRecipe.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Real executor/account routing; issuer settlement is a local fixture.
contract RecipeClaimsTest is CapabilityTestBase {
    ClaimToken internal token;
    ClaimIssuer internal issuer;
    RecipeExecutor internal executor;
    IMerkleAccount.Action internal action;
    ExecutingRecipe.Recipe internal recipe;
    bytes32 internal leaf;

    function setUp() public {
        token = new ClaimToken();
        issuer = new ClaimIssuer(token);
        _deployAdapter(address(token));
        executor = new RecipeExecutor(address(this), account);
        executor.setCaller(address(this));
        bytes memory data = abi.encodeCall(ClaimIssuer.claim, (0, account));
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 4; i < 36; ++i) {
            mask[i] = 0xff;
        }
        action = IMerkleAccount.Action(address(issuer), 0, data, mask, new bytes32[](0));
        leaf = ActionMasker.mask(action.target, 0, data, mask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(executor));
        ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](1);
        claims[0].leaves = new bytes32[](1);
        claims[0].leaves[0] = leaf;
        (recipe,) = ClaimRecipe.build(account, claims);
        executor.setRecipe(recipe.queries, recipe.steps);
        issuer.settle(account, 0, 7);
        issuer.settle(account, 9, 11);
    }

    function test_ClaimHasNoDiscoveryReadsOrNumericalInputs() public {
        assertEq(recipe.queries.length, 0);
        assertEq(recipe.steps.length, 1);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(9, account));
        assertEq(token.balanceOf(account), 11);
        assertEq(issuer.ready(account, 0), 7);
    }

    function test_MulticallRepeatsSameRecipeForDifferentReadyRequests() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = _executeCall(0);
        calls[1] = _executeCall(9);
        executor.multicall(calls);
        assertEq(token.balanceOf(account), 18);
        assertEq(issuer.ready(account, 0), 0);
        assertEq(issuer.ready(account, 9), 0);
    }

    function test_MulticallRollsBackEarlierClaimWhenAnotherRequestIsUnready() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = _executeCall(0);
        calls[1] = _executeCall(1);
        vm.expectRevert(ClaimIssuer.NotReady.selector);
        executor.multicall(calls);
        assertEq(token.balanceOf(account), 0);
        assertEq(issuer.ready(account, 0), 7);
    }

    function test_MulticallCannotBypassCaller() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = _executeCall(0);
        vm.prank(address(0xBAD));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.multicall(calls);
    }

    function test_RecipientStillPinnedByPermission() public {
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(0, address(0xBAD)));
        assertEq(issuer.ready(account, 0), 7);
    }

    function test_RevokedPermissionPreventsClaim() public {
        MerkleAccount(payable(account)).revokeRole(leaf, address(executor));
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(0, account));
        assertEq(token.balanceOf(account), 0);
    }

    function test_InvalidConfiguration() public {
        ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](0);
        vm.expectRevert(ClaimRecipe.InvalidConfiguration.selector);
        this.build(account, claims);
        claims = new ClaimRecipe.Claim[](2);
        vm.expectRevert(ClaimRecipe.InvalidConfiguration.selector);
        this.build(account, claims);
        claims = new ClaimRecipe.Claim[](1);
        vm.expectRevert(ClaimRecipe.InvalidConfiguration.selector);
        this.build(account, claims);
        claims[0].leaves = new bytes32[](1);
        claims[0].leaves[0] = leaf;
        vm.expectRevert(ClaimRecipe.InvalidConfiguration.selector);
        this.build(address(0), claims);
    }

    function build(address owner, ClaimRecipe.Claim[] memory claims) public pure {
        ClaimRecipe.build(owner, claims);
    }

    function _runtime(uint256 id, address receiver) internal view returns (bytes[] memory runtime) {
        IMerkleAccount.Action[] memory calls = new IMerkleAccount.Action[](1);
        calls[0] = action;
        calls[0].data = abi.encodeCall(ClaimIssuer.claim, (id, receiver));
        runtime = new bytes[](1);
        runtime[0] = abi.encode(calls);
    }

    function _executeCall(uint256 id) internal view returns (bytes memory) {
        return abi.encodeCall(
            IRecipeExecutor.execute, (recipe.queries, recipe.steps, new uint256[](0), _runtime(id, account))
        );
    }
}

contract ClaimToken is ERC20 {
    constructor() ERC20("Claim asset", "CLAIM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ClaimIssuer {
    error NotReady();
    ClaimToken internal immutable token;
    mapping(address => mapping(uint256 => uint256)) public ready;

    constructor(ClaimToken asset) {
        token = asset;
    }

    function settle(address owner, uint256 id, uint256 amount) external {
        ready[owner][id] = amount;
    }

    function claim(uint256 id, address receiver) external {
        uint256 amount = ready[msg.sender][id];
        if (amount == 0) revert NotReady();
        delete ready[msg.sender][id];
        token.mint(receiver, amount);
    }
}

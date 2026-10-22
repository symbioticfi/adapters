// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {SynchronousVaultRecipe} from "script/recipes/SynchronousVaultRecipe.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev Exercises actual MerkleAccount authorization and interpreter execution against local venue effects.
contract SynchronousVaultRecipeTest is CapabilityTestBase {
    SynchronousVaultAssetMock internal _asset;
    SynchronousVaultMock internal _vault;
    RecipeExecutor internal _executor;
    SynchronousVaultRecipe.Config internal _config;
    IMerkleAccount.Action[] internal _actions;
    uint256 public demand = 200;

    function setUp() public {
        _asset = new SynchronousVaultAssetMock();
        _vault = new SynchronousVaultMock(address(_asset));
        _deployAdapter(address(_asset));
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        _executor = RecipeExecutor(
            new ImmutableFactory(type(RecipeExecutor).creationCode).create(abi.encode(address(this), account))
        );
        _executor.setCaller(address(this));
        _permissions();
        _asset.mint(account, 100);
        _asset.mint(address(_vault), 2000);
        _vault.seed(account, 1000);
    }

    function test_DepositSizesFromLiveBalancePolicyAndVenueLimit() public {
        _execute(SynchronousVaultRecipe.deposit(_config, 80, 0), _depositRuntime());
        assertEq(_asset.balanceOf(account), 40);
        assertEq(_vault.balanceOf(account), 1120);
        assertEq(_asset.allowance(account, address(_vault)), 0);
    }

    function testFuzz_DepositRemainsLiveAfterRecipeConstruction(uint96 policy, uint96 balance, uint96 capacity) public {
        ExecutingRecipe.Recipe memory recipe = SynchronousVaultRecipe.deposit(_config, policy, 0);
        _asset.burn(account, 100);
        _asset.mint(account, balance);
        _vault.setCapacity(capacity, 50);
        uint256 expected = _min(_min(policy, balance), capacity);
        _execute(recipe, _depositRuntime());
        assertEq(_asset.balanceOf(account), uint256(balance) - expected);
        assertEq(_vault.balanceOf(account), 1000 + expected * 2);
        assertEq(_asset.allowance(account, address(_vault)), 0);
    }

    function test_WithdrawUsesOnlyShortfallAndAvailableLiquidity() public {
        _execute(_withdraw(), _withdrawRuntime());
        assertEq(_asset.balanceOf(account), 150);
        assertEq(_vault.balanceOf(account), 900);
    }

    function test_WithdrawReadsNewDemandAfterRecipeConstruction() public {
        ExecutingRecipe.Recipe memory recipe = _withdraw();
        demand = 130;
        _execute(recipe, _withdrawRuntime());
        assertEq(_asset.balanceOf(account), 130);
        assertEq(_vault.balanceOf(account), 940);
    }

    function test_WithdrawDoesNothingWhenFreeFundsCoverDemand() public {
        demand = 90;
        _execute(_withdraw(), _withdrawRuntime());
        _pristine();
    }

    function test_DepositRejectsBadPreviewOutputAndRollsBackApproval() public {
        _vault.setLosses(1, 0, 0);
        ExecutingRecipe.Recipe memory recipe = SynchronousVaultRecipe.deposit(_config, 80, 0);
        bytes[] memory runtime = _depositRuntime();
        _expectFailure(recipe, runtime, IRecipes.CheckFailed.selector);
        _pristine();
    }

    function test_DepositAcceptsOutputWithinConfiguredSlippage() public {
        _vault.setLosses(1, 0, 0);
        _execute(SynchronousVaultRecipe.deposit(_config, 80, 100), _depositRuntime());
        assertEq(_asset.balanceOf(account), 40);
        assertEq(_vault.balanceOf(account), 1119);
        assertEq(_asset.allowance(account, address(_vault)), 0);
    }

    function test_DepositRejectsZeroOutputEvenWithFullSlippage() public {
        _vault.setLosses(120, 0, 0);
        ExecutingRecipe.Recipe memory recipe = SynchronousVaultRecipe.deposit(_config, 80, 10_000);
        bytes[] memory runtime = _depositRuntime();
        _expectFailure(recipe, runtime, IRecipes.CheckFailed.selector);
        _pristine();
    }

    function test_WithdrawRejectsExcessShareBurn() public {
        _vault.setLosses(0, 1, 0);
        ExecutingRecipe.Recipe memory recipe = _withdraw();
        bytes[] memory runtime = _withdrawRuntime();
        _expectFailure(recipe, runtime, IRecipes.CheckFailed.selector);
        _pristine();
    }

    function test_WithdrawRejectsShortPayment() public {
        _vault.setLosses(0, 0, 1);
        ExecutingRecipe.Recipe memory recipe = _withdraw();
        bytes[] memory runtime = _withdrawRuntime();
        _expectFailure(recipe, runtime, IRecipes.CheckFailed.selector);
        _pristine();
    }

    function test_RejectsChangedVaultAsset() public {
        _vault.setAsset(address(0xbad));
        ExecutingRecipe.Recipe memory recipe = _withdraw();
        bytes[] memory runtime = _withdrawRuntime();
        _expectFailure(recipe, runtime, IRecipes.CheckFailed.selector);
        _pristine();
    }

    function test_RejectsRuntimeRecipientChange() public {
        ExecutingRecipe.Recipe memory recipe = SynchronousVaultRecipe.deposit(_config, 80, 0);
        bytes[] memory runtime = _depositRuntime();
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[1], (IMerkleAccount.Action[]));
        actions[0].data = abi.encodeCall(IERC4626.deposit, (0, address(0xbad)));
        runtime[1] = abi.encode(actions);
        _expectFailure(recipe, runtime, bytes4(0));
        _pristine();
    }

    function _withdraw() internal view returns (ExecutingRecipe.Recipe memory) {
        return SynchronousVaultRecipe.withdraw(
            _config,
            ExecutingRecipe.Read({target: address(this), data: abi.encodeWithSignature("demand()"), offset: 0}),
            0
        );
    }

    function _execute(ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) internal {
        _executor.setRecipe(recipe.queries, recipe.steps);
        _executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
    }

    function _expectFailure(ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime, bytes4 selector) internal {
        _executor.setRecipe(recipe.queries, recipe.steps);
        if (selector == bytes4(0)) vm.expectRevert();
        else vm.expectRevert(selector);
        _executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
    }

    function _pristine() internal view {
        assertEq(_asset.balanceOf(account), 100);
        assertEq(_vault.balanceOf(account), 1000);
        assertEq(_asset.allowance(account, address(_vault)), 0);
    }

    function _permissions() internal {
        _actions.push(_action(address(_asset), abi.encodeCall(IERC20.approve, (address(_vault), 0)), 36));
        _actions.push(_action(address(_vault), abi.encodeCall(IERC4626.deposit, (0, account)), 4));
        _actions.push(_action(address(_vault), abi.encodeCall(IERC4626.withdraw, (0, account, account)), 4));
        bytes32[] memory nodes = new bytes32[](7);
        for (uint256 i; i < 3; ++i) {
            nodes[3 + i] = ActionMasker.mask(_actions[i].target, 0, _actions[i].data, _actions[i].dataMask);
            MerkleAccount(payable(account)).grantRole(nodes[3 + i], address(_executor));
        }
        for (uint256 i = 3; i > 0;) {
            --i;
            bytes32 left = nodes[i * 2 + 1];
            bytes32 right = nodes[i * 2 + 2];
            nodes[i] =
                left < right ? keccak256(abi.encodePacked(left, right)) : keccak256(abi.encodePacked(right, left));
        }
        for (uint256 i; i < 3; ++i) {
            uint256 cursor = 3 + i;
            while (cursor > 0) {
                _actions[i].proof.push(nodes[cursor % 2 == 1 ? cursor + 1 : cursor - 1]);
                cursor = (cursor - 1) / 2;
            }
        }
        roots.setRoot(account, nodes[0]);
        MerkleAccount(payable(account)).acceptRoot(nodes[0]);
        _config = SynchronousVaultRecipe.Config({
            account: account,
            asset: address(_asset),
            vault: address(_vault),
            approvalLeaf: nodes[3],
            depositLeaf: nodes[4],
            withdrawLeaf: nodes[5]
        });
    }

    function _action(address target, bytes memory data, uint256 amountOffset)
        internal
        pure
        returns (IMerkleAccount.Action memory)
    {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < 32; ++i) {
            mask[amountOffset + i] = 0xff;
        }
        return IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _depositRuntime() internal view returns (bytes[] memory runtime) {
        runtime = new bytes[](3);
        runtime[0] = abi.encode(_actions[0].dataMask, _actions[0].proof);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _actions[1];
        runtime[1] = abi.encode(actions);
        runtime[2] = runtime[0];
    }

    function _withdrawRuntime() internal view returns (bytes[] memory runtime) {
        runtime = new bytes[](1);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _actions[2];
        runtime[0] = abi.encode(actions);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract SynchronousVaultAssetMock is ERC20 {
    constructor() ERC20("Asset", "ASSET") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function burn(address owner, uint256 amount) external {
        _burn(owner, amount);
    }
}

contract SynchronousVaultMock is ERC20 {
    address public asset;
    uint256 public depositCapacity = 60;
    uint256 public withdrawCapacity = 50;
    uint256 public outputLoss;
    uint256 public excessBurn;
    uint256 public paymentLoss;

    constructor(address asset_) ERC20("Vault", "VAULT") {
        asset = asset_;
    }

    function setAsset(address value) external {
        asset = value;
    }

    function seed(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setCapacity(uint256 deposits, uint256 withdrawals) external {
        depositCapacity = deposits;
        withdrawCapacity = withdrawals;
    }

    function setLosses(uint256 output, uint256 burn, uint256 payment) external {
        outputLoss = output;
        excessBurn = burn;
        paymentLoss = payment;
    }

    function maxDeposit(address) external view returns (uint256) {
        return depositCapacity;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return _min(_min(balanceOf(owner) / 2, IERC20(asset).balanceOf(address(this))), withdrawCapacity);
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets * 2;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets * 2;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets <= depositCapacity);
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        shares = assets * 2 - outputLoss;
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(msg.sender == owner && assets <= withdrawCapacity);
        shares = assets * 2 + excessBurn;
        _burn(owner, shares);
        IERC20(asset).transfer(receiver, assets - paymentLoss);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

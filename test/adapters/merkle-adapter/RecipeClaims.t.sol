// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {OP_READ, OP_MANAGE} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClaimRecipe} from "script/recipes/ClaimRecipe.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";

contract RecipeClaimsTest is CapabilityTestBase {
    AsyncClaimTokenMock private token;
    AsyncClaimVaultMock private vault;
    RecipeExecutor private executor;

    function setUp() public {
        token = new AsyncClaimTokenMock(6);
        vault = new AsyncClaimVaultMock(address(token));
        _deployAdapter(address(token));
        executor = new RecipeExecutor(address(this), account);
        executor.setCaller(address(this));
        token.mint(address(vault), 100e6);
        vault.seedShares(account, 100e18);
        vm.prank(account);
        vault.requestRedeem(100e18, account, account);
    }

    function test_OnlyArgumentReadAndNativeClaim() public {
        vault.settleRedeem(account, 40e18);
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _install(true);
        assertEq(recipe.queries.length, 1);
        assertEq(recipe.steps.length, 2);
        assertEq(uint8(recipe.steps[0][0]), OP_READ);
        assertEq(uint8(recipe.steps[1][0]), OP_MANAGE);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(token.balanceOf(account), 40e6);
        assertEq(vault.pendingRedeem(account), 60e18);
        assertEq(vault.maxWithdraw(account), 0);
    }

    function test_NativeClaimReceivesFreshAmountOnEveryRun() public {
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _install(true);
        vault.settleRedeem(account, 40e18);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        vault.settleRedeem(account, 60e18);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(token.balanceOf(account), 100e6);
    }

    function test_RuntimeAmountNeedsNoRead() public {
        vault.settleRedeem(account, 40e18);
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _install(false);
        assertEq(recipe.queries.length, 0);
        assertEq(recipe.steps.length, 1);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[0], (IMerkleAccount.Action[]));
        actions[0].data = abi.encodeCall(vault.withdraw, (25e6, account, account));
        runtime[0] = abi.encode(actions);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(token.balanceOf(account), 25e6);
        assertEq(vault.maxWithdraw(account), 15e6);
    }

    function test_NativeContractRejectsUnavailableClaimAndRollsBack() public {
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _install(false);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[0], (IMerkleAccount.Action[]));
        actions[0].data = abi.encodeCall(vault.withdraw, (1, account, account));
        runtime[0] = abi.encode(actions);
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(token.balanceOf(account), 0);
        assertEq(vault.pendingRedeem(account), 100e18);
    }

    function test_CannotChangePinnedRecipient() public {
        vault.settleRedeem(account, 40e18);
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _install(true);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[0], (IMerkleAccount.Action[]));
        actions[0].data = abi.encodeCall(vault.withdraw, (0, address(0xbad), account));
        runtime[0] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(token.balanceOf(account), 0);
    }

    function _install(bool readAmount) private returns (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) {
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(vault), abi.encodeCall(vault.withdraw, (0, account, account)));
        for (uint256 i = 4; i < 36; ++i) {
            actions[0].dataMask[i] = 0xff;
        }
        bytes32 leaf = ActionMasker.mask(address(vault), 0, actions[0].data, actions[0].dataMask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(executor));
        ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](1);
        claims[0].leaves = new bytes32[](1);
        claims[0].leaves[0] = leaf;
        claims[0].arguments = new ClaimRecipe.Argument[](readAmount ? 1 : 0);
        if (readAmount) {
            claims[0].arguments[0].query = ExecutingRecipe.query(
                ExecutingRecipe.Read({
                    target: address(vault), data: abi.encodeCall(vault.maxWithdraw, (account)), offset: 0
                })
            );
            claims[0].arguments[0].offsets = new uint256[][](1);
            claims[0].arguments[0].offsets[0] = new uint256[](1);
            claims[0].arguments[0].offsets[0][0] = 4;
        }
        (recipe,) = ClaimRecipe.build(claims);
        executor.setRecipe(recipe.queries, recipe.steps);
        runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
    }
}

contract AsyncClaimTokenMock is ERC20 {
    uint8 internal immutable _decimals;

    constructor(uint8 newDecimals) ERC20("Fixture asset", "ASSET") {
        _decimals = newDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address receiver, uint256 amount) public {
        _mint(receiver, amount);
    }
}

contract AsyncClaimBalanceLensMock {
    error OutputUnavailable();

    function getBalance(address) public pure returns (uint256) {
        revert OutputUnavailable();
    }
}

/// @dev ERC-7540-style local fixture: pending excludes claimable, and claims never transfer inputs twice.
contract AsyncClaimVaultMock is ERC20 {
    error AsyncPreview();
    address public immutable asset;
    mapping(address => uint256) public pendingDeposit;
    mapping(address => uint256) public pendingRedeem;
    mapping(address => uint256) internal _claimableMint;
    mapping(address => uint256) internal _claimableRedeem;

    constructor(address newAsset) ERC20("Fixture shares", "SHARE") {
        asset = newAsset;
    }

    function seedShares(address receiver, uint256 shares) public {
        _mint(receiver, shares);
    }

    function requestDeposit(uint256 assets, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender);
        IERC20(asset).transferFrom(owner, address(this), assets);
        pendingDeposit[controller] += assets;
        return 0;
    }

    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender);
        _burn(owner, shares);
        pendingRedeem[controller] += shares;
        return 0;
    }

    function settleDeposit(address controller, uint256 assets) public {
        pendingDeposit[controller] -= assets;
        _claimableMint[controller] += assets * 1e12;
    }

    function settleRedeem(address controller, uint256 shares) public {
        pendingRedeem[controller] -= shares;
        _claimableRedeem[controller] += shares;
    }

    function maxMint(address controller) public view returns (uint256) {
        return _claimableMint[controller];
    }

    function maxDeposit(address controller) public view returns (uint256) {
        return _claimableMint[controller] / 1e12;
    }

    function maxRedeem(address controller) public view returns (uint256) {
        return _claimableRedeem[controller];
    }

    function maxWithdraw(address controller) public view virtual returns (uint256) {
        return _claimableRedeem[controller] / 1e12;
    }

    function previewMint(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function previewWithdraw(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function previewRedeem(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        _claimableMint[msg.sender] -= shares;
        _mint(receiver, shares);
        return shares / 1e12;
    }

    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = assets * 1e12;
        _claimableMint[msg.sender] -= shares;
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        require(controller == msg.sender);
        _claimableRedeem[controller] -= shares;
        assets = shares / 1e12;
        IERC20(asset).transfer(receiver, assets);
    }

    function withdraw(uint256 assets, address receiver, address controller) public virtual returns (uint256 shares) {
        require(controller == msg.sender);
        shares = assets * 1e12;
        _claimableRedeem[controller] -= shares;
        IERC20(asset).transfer(receiver, assets);
    }
}

contract AsyncRewardsMock {
    address public immutable rewardA;
    address public immutable rewardB;
    mapping(address => uint256) public earned;
    bool internal _secondReward = true;
    bool internal _noPayout;

    constructor(address newRewardA, address newRewardB) {
        rewardA = newRewardA;
        rewardB = newRewardB;
    }

    function accrue(address controller, uint256 amount) public {
        earned[controller] += amount;
    }

    function setSecondReward(bool enabled) public {
        _secondReward = enabled;
    }

    function setNoPayout(bool enabled) public {
        _noPayout = enabled;
    }

    function getReward(address receiver) public {
        claim(earned[msg.sender], receiver);
    }

    function claim(uint256 amount, address receiver) public {
        earned[msg.sender] -= amount;
        if (_noPayout) return;
        AsyncClaimTokenMock(rewardA).mint(receiver, amount);
        if (_secondReward) AsyncClaimTokenMock(rewardB).mint(receiver, 2 * amount);
    }
}

/// @dev Local ETH settlement fixture and balance lens; no live issuer behavior is claimed.
contract AsyncNativeClaimMock {
    mapping(address => uint256) public pending;
    mapping(address => uint256) public claimable;
    bool internal _noPayout;

    function seedPending(address controller, uint256 amount) public {
        pending[controller] += amount;
    }

    function settle(address controller, uint256 amount) public {
        pending[controller] -= amount;
        claimable[controller] += amount;
    }

    function getEthBalance(address controller) public view returns (uint256) {
        return controller.balance;
    }

    function setNoPayout(bool enabled) public {
        _noPayout = enabled;
    }

    function claim(uint256 amount, address receiver) public {
        claimable[msg.sender] -= amount;
        if (_noPayout) return;
        (bool success,) = receiver.call{value: amount}("");
        require(success);
    }
}

/// @dev Raw readiness/output units avoid unrelated token supply or decimal conversion arithmetic.
contract ClaimO09Lens {
    error QueryFailed();
    uint256 public ready;
    uint256 public cash;
    uint256 internal _effects;
    bool internal _queryFailure;

    constructor(uint256 newReady) {
        ready = newReady;
    }

    function setEffects(uint256 mode) public {
        _effects = mode + 1;
    }

    function setQueryFailure(bool value) public {
        _queryFailure = value;
    }

    function readiness(address) public view returns (uint256) {
        if (_queryFailure) revert QueryFailed();
        return ready;
    }

    function balance(address) public view returns (uint256) {
        return cash;
    }

    function claim(uint256 amount, address recipient) public {
        require(recipient == msg.sender);
        ready -= _effects == 1 ? amount - 1 : _effects == 2 ? amount + 1 : amount;
        cash += _effects == 3 ? amount - 1 : _effects == 4 ? 0 : amount;
    }
}

/// @dev Local owner-ledger fixture; next is independent of whether the selected identifier is zero.
contract SelectedClaimMock {
    address public immutable asset;
    uint256[] internal _ids;
    mapping(uint256 => uint256) internal _ready;

    constructor(address asset_) {
        asset = asset_;
    }

    function seed(uint256 id, uint256 amount) external {
        _ids.push(id);
        _ready[id] = amount;
    }

    function next(address) public view returns (uint256) {
        for (uint256 i; i < _ids.length; ++i) {
            if (_ready[_ids[i]] != 0) return _ids[i];
        }
        return 0;
    }

    function ready(address, uint256 id) external view returns (uint256) {
        return _ready[id];
    }

    function minimum(address account) external view returns (uint256) {
        return _ready[next(account)] * 2;
    }

    function claim(uint256 id, uint256 amount, address recipient) external {
        require(_ready[id] == amount && amount != 0);
        _ready[id] = 0;
        AsyncClaimTokenMock(asset).mint(recipient, amount * 2);
    }
}

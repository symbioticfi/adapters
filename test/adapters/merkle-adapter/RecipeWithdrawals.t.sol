// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {RecoveryTokenMock, RecoveryTraceMock, RecoveryMorphoVaultMock, RecoveryAaveMock} from "./RecipeRecovery.t.sol";
import {MerkleAdapterOracleMock} from "test/adapters/MerkleAdapter.t.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {WithdrawalsRecipe} from "script/recipes/WithdrawalsRecipe.sol";

/// @dev Real executor, account permissions and adapter accounting; local liquidity sources and queue reads.
contract RecipeWithdrawalsTest is CapabilityTestBase {
    address internal _asset;
    address internal _morpho;
    address internal _aave;
    address internal _trace;
    RecipeExecutor internal _executor;
    WithdrawalsRecipe.Config internal _config;
    IMerkleAccount.Action[] internal _actions;

    function setUp() public {
        _asset = address(new RecoveryTokenMock("USDC", 6));
        _trace = address(new RecoveryTraceMock());
        _morpho = address(new RecoveryMorphoVaultMock(_asset, _trace));
        _aave = address(new RecoveryAaveMock(_asset, _trace));
        _deployAdapter(_asset);
        vm.roll(10);
        MerkleAdapterOracleMock(adapter.oracle()).setTotalAssets(100e6);
        RecoveryTokenMock(_asset).mint(account, 17e6);
        RecoveryTokenMock(_asset).mint(_morpho, 100e6);
        RecoveryTokenMock(_asset).mint(_aave, 100e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(30e6);
        RecoveryAaveMock(_aave).setCapacity(20e6);
        _manage(_asset, abi.encodeCall(IERC20.approve, (address(adapter), type(uint256).max)));
        _executor = RecipeExecutor(
            new ImmutableFactory(type(RecipeExecutor).creationCode).create(abi.encode(address(this), account))
        );
        _executor.setCaller(address(this));
        _permissions();
        _config.adapter = address(adapter);
        _config.account = account;
        _config.asset = _asset;
        _config.vault = adapter.vault();
        _config.delegator = makeAddr("delegator");
        _config.queue = makeAddr("queue");
        _config.returnLeaf = _leaf(2);
        _config.returnAmountOffsets.push(4);
        for (uint256 i; i < 2; ++i) {
            _config.sources.push();
            _config.sources[i].capacity = ExecutingRecipe.Read({
                target: i == 0 ? _morpho : _aave,
                data: i == 0
                    ? abi.encodeCall(RecoveryMorphoVaultMock.maxWithdraw, (account))
                    : abi.encodeCall(RecoveryAaveMock.capacity, (account)),
                offset: 0
            });
            _config.sources[i].leaves.push(_leaf(i));
            _config.sources[i].amountOffsets.push();
            _config.sources[i].amountOffsets[0].push(i == 0 ? 4 : 36);
        }
        _config.sources[1].debt =
            ExecutingRecipe.Read({target: _aave, data: abi.encodeCall(RecoveryAaveMock.debt, (account)), offset: 0});
        _mock(_config.delegator, abi.encodeWithSignature("getAdaptersLength()"), 1);
        _mock(_config.delegator, abi.encodeWithSignature("adapters(uint256)", 0), uint160(address(adapter)));
        _mock(_config.vault, abi.encodeWithSignature("freeAssets()"), 0);
        _mock(_config.queue, abi.encodeWithSignature("pendingAssets()"), 50e6);
    }

    function test_CashThenOrderedSourcesReturnExactDemand() public {
        _execute();
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50e6);
        assertEq(adapter.lockedLiquidity(), 50e6);
        assertEq(RecoveryMorphoVaultMock(_morpho).maxWithdraw(account), 0);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 17e6);
        assertEq(RecoveryTraceMock(_trace).calls(0), 1);
        assertEq(RecoveryTraceMock(_trace).calls(1), 2);
    }

    function test_RepeatedRunDoesNotReturnAlreadyLockedFunds() public {
        _execute();
        _execute();
        assertEq(adapter.lockedLiquidity(), 50e6);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 17e6);
    }

    function test_PositiveDebtSkipsSourceAndMakesPartialProgress() public {
        RecoveryAaveMock(_aave).setPosition(1, 300e6);
        _execute();
        assertEq(adapter.lockedLiquidity(), 47e6);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 1);
        assertEq(RecoveryTraceMock(_trace).count(), 1);
    }

    function test_QueueSubtractsVaultCashAndOtherAdapters() public {
        address preceding = makeAddr("preceding adapter");
        address following = makeAddr("following adapter");
        _config.precedingAdapters.push(preceding);
        _config.followingAdapters.push(following);
        _mock(_config.delegator, abi.encodeWithSignature("getAdaptersLength()"), 3);
        _mock(_config.delegator, abi.encodeWithSignature("adapters(uint256)", 0), uint160(preceding));
        _mock(_config.delegator, abi.encodeWithSignature("adapters(uint256)", 1), uint160(address(adapter)));
        _mock(_config.delegator, abi.encodeWithSignature("adapters(uint256)", 2), uint160(following));
        _mock(_config.queue, abi.encodeWithSignature("pendingAssets()"), 80e6);
        _mock(_config.vault, abi.encodeWithSignature("freeAssets()"), 20e6);
        _mock(preceding, abi.encodeWithSignature("totalAssets()"), 10e6);
        _mock(following, abi.encodeWithSignature("freeAssets()"), 15e6);
        _execute();
        assertEq(adapter.lockedLiquidity(), 35e6);
        assertEq(RecoveryMorphoVaultMock(_morpho).maxWithdraw(account), 12e6);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 20e6);
    }

    function test_ChangedRouteRevertsBeforeWithdrawing() public {
        _mock(_config.delegator, abi.encodeWithSignature("getAdaptersLength()"), 2);
        _assertRevert();
    }

    function test_InexactSourceReceiptRollsBack() public {
        RecoveryMorphoVaultMock(_morpho).setShortfall(1);
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _prepare();
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", account, 50e6 - 1, 50e6)
        );
        _executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(adapter.lockedLiquidity(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function testFuzz_DemandIsCappedAndLockedCashIsNeverReturnedTwice(
        uint256 pending,
        uint256 cash,
        uint256 locked,
        bool debt
    ) public {
        pending = bound(pending, 0, 200e6);
        cash = bound(cash, 0, 120e6);
        locked = bound(locked, 0, 100e6);
        RecoveryTokenMock(_asset).burn(account, 17e6);
        RecoveryTokenMock(_asset).mint(account, cash + locked);
        vm.prank(account);
        adapter.pull(locked);
        RecoveryAaveMock(_aave).setPosition(debt ? 1 : 0, 300e6);
        _mock(_config.queue, abi.encodeWithSignature("pendingAssets()"), pending);

        uint256 target = pending < 100e6 ? pending : 100e6;
        uint256 need = target > locked ? target - locked : 0;
        uint256 available = cash + 30e6 + (debt ? 0 : 20e6);
        uint256 returned = need < available ? need : available;
        _execute();
        assertEq(adapter.lockedLiquidity(), locked + returned);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), locked + returned);
        assertEq(IERC20(_asset).balanceOf(account), cash > need ? cash - need : 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), debt ? 1 : 0);
    }

    function _assertRevert() internal {
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _prepare();
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(adapter.lockedLiquidity(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryMorphoVaultMock(_morpho).maxWithdraw(account), 30e6);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
    }

    function _execute() internal {
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _prepare();
        _executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
    }

    function _prepare() internal returns (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) {
        WithdrawalsRecipe.Layout memory layout;
        (recipe, layout) = WithdrawalsRecipe.build(_config);
        _executor.setRecipe(recipe.queries, recipe.steps);
        runtime = new bytes[](ExecutingRecipe.runtimeSteps(recipe).length);
        for (uint256 i; i < 3; ++i) {
            IMerkleAccount.Action[] memory calls = new IMerkleAccount.Action[](1);
            calls[0] = _actions[i];
            // Supplied amounts are deliberately wrong: committed bindings must replace them.
            calls[0].data = i == 0
                ? abi.encodeCall(RecoveryMorphoVaultMock.withdraw, (999e6, account, account))
                : i == 1
                    ? abi.encodeCall(RecoveryAaveMock.withdraw, (_asset, 999e6, account))
                    : abi.encodeCall(IMerkleAdapter.pull, (999e6));
            runtime[i < 2 ? layout.sourceCalls[i] : layout.returnStep] = abi.encode(calls);
        }
    }

    function _permissions() internal {
        _actions.push(_action(_morpho, abi.encodeCall(RecoveryMorphoVaultMock.withdraw, (0, account, account)), 4));
        _actions.push(_action(_aave, abi.encodeCall(RecoveryAaveMock.withdraw, (_asset, 0, account)), 36));
        _actions.push(_action(address(adapter), abi.encodeCall(IMerkleAdapter.pull, (0)), 4));
        bytes32[] memory nodes = new bytes32[](7);
        for (uint256 i; i < 3; ++i) {
            nodes[3 + i] = _leaf(i);
            MerkleAccount(payable(account)).grantRole(nodes[3 + i], address(_executor));
        }
        for (uint256 i = 3; i > 0;) {
            --i;
            bytes32 left = nodes[2 * i + 1];
            bytes32 right = nodes[2 * i + 2];
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

    function _leaf(uint256 index) internal view returns (bytes32) {
        return ActionMasker.mask(_actions[index].target, 0, _actions[index].data, _actions[index].dataMask);
    }

    function _mock(address target, bytes memory data, uint256 value) internal {
        vm.mockCall(target, data, abi.encode(value));
    }
}

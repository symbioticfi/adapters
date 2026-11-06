// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LLExecutingTest} from "test/adapters/merkle-adapter/LLExecuting.t.sol";
import {ThreeFExecutingTest} from "test/adapters/merkle-adapter/ThreeFExecuting.t.sol";
import {RecipeLendingTest} from "test/adapters/merkle-adapter/RecipeLending.t.sol";
import {RecipeRecoveryTest} from "test/adapters/merkle-adapter/RecipeRecovery.t.sol";
import {RecipeClaimsTest} from "test/adapters/merkle-adapter/RecipeClaims.t.sol";
import {RecipeExecutorTest} from "test/adapters/merkle-adapter/RecipeExecutor.t.sol";
import {RecipeCapabilityTest} from "test/adapters/merkle-adapter/RecipeCapability.t.sol";
import {RecipeFundingTest, ConditionalFundingSourceMock} from "test/adapters/merkle-adapter/RecipeFunding.t.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

/// @dev Stable fixture identifiers compare the previous runtime with the audited rollback.
contract CallIfGasLLTest is LLExecutingTest {
    /// forge-config: default.isolate = true
    function test_CallIfGasLLNoPrepare() public {
        test_GasO03LLPositiveMinimum();
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasLLNoPrepareOptimized() public {
        test_GasTwoActiveSources();
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasLLPrepareNeeded() public {
        _bench(false, false);
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasLLPrepareSkipped() public {
        _bench(true, false);
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasLLPrepareNeededOptimized() public {
        _bench(false, true);
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasLLPrepareSkippedOptimized() public {
        _bench(true, true);
    }

    function _bench(bool funded, bool optimized) internal {
        _skipZeroApprovals = optimized;
        Plan memory plan = _plan();
        plan.preparedFirstLiquidity = 30;
        if (funded) {
            IERC20(_asset).transfer(account, 90);
            plan.firstAmount = 0;
            plan.secondAmount = 0;
        }
        bytes[] memory runtime = _prepare(plan, _swapData(10_000_000, type(uint48).max, type(uint48).max, false));
        _execute(plan, runtime);
        vm.snapshotGasLastCall(
            "CallIfGasLL", string.concat(funded ? "skipped" : "needed", optimized ? "Optimized" : "Standard")
        );
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
        assertEq(IERC20(_issuer).balanceOf(account), 100);
    }
}

contract CallIfGasThreeFTest is ThreeFExecutingTest {
    /// forge-config: default.isolate = true
    function test_CallIfGasThreeF() public {
        IERC20(_asset).transfer(account, 20);
        _execute(_prepare(30, 50, 100, 10, 1000));
        vm.snapshotGasLastCall("CallIfGasThreeF", _reuseTupleReads ? "twoSourcesCached" : "twoSources");
        assertEq(IERC20(_asset).balanceOf(_request), 100);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }
}

contract CallIfGasThreeFCachedTest is CallIfGasThreeFTest {
    function setUp() public override {
        super.setUp();
        _reuseTupleReads = true;
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasThreeFCached() public {
        IERC20(_asset).transfer(account, 20);
        _execute(_prepare(30, 50, 100, 10, 1000));
        vm.snapshotGasLastCall("CallIfGasThreeF", "twoSourcesCached");
        assertEq(IERC20(_asset).balanceOf(_request), 100);
    }
}

contract CallIfGasLendingTest is RecipeLendingTest {
    /// forge-config: default.isolate = true
    function test_CallIfGasLendingSync() public {
        test_GasO04Sync();
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasLendingAsync() public {
        test_GasO04Async();
    }
}

contract CallIfGasRecoveryTest is RecipeRecoveryTest {
    /// forge-config: default.isolate = true
    function test_CallIfGasRecovery() public {
        test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder();
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasRepay() public {
        test_RepayUsesPreviouslySettledCashAndPreservesReserve();
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasRecoveryTwoSources() public {
        test_GasO01TwoActiveSources();
    }
}

contract CallIfGasClaimsTest is RecipeClaimsTest {
    /// forge-config: default.isolate = true
    function test_CallIfGasClaims() public {
        test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens();
    }
}

contract CallIfGasExecutorTest is RecipeExecutorTest {
    /// forge-config: default.isolate = true
    function test_CallIfGasOrdinaryCall() public {
        test_CallUsesCommittedTemplateAndProducesNoUsableResult();
    }
}

contract CallIfGasCapabilityTest is RecipeCapabilityTest {
    /// forge-config: default.isolate = true
    function test_CallIfGasAccountRecipe() public {
        test_RecipeBindsComputedAmountAndChecksAccountState();
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasReadOnly() public {
        test_EmptyAndReadOnlyRecipes();
    }
}

contract CallIfGasFundingTest is RecipeFundingTest {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    /// forge-config: default.isolate = true
    function test_CallIfGasFundingNeeded() public {
        _benchFunding(false);
    }

    /// forge-config: default.isolate = true
    function test_CallIfGasFundingSkipped() public {
        _benchFunding(true);
    }

    /// forge-config: default.isolate = true
    function _benchFunding(bool funded) internal {
        if (funded) IERC20(_asset).transfer(account, 10);
        ExecutingRecipe.Funding memory funding = _funding(1);
        funding.sources[0].prepare =
            ExecutingRecipe.Call({target: _source, data: abi.encodeCall(ConditionalFundingSourceMock.prepare, (10))});
        IMerkleAccount.Action memory action = _fundingAction();
        funding.sources[0].leaves = new bytes32[](1);
        funding.sources[0].leaves[0] = _authorize(action);
        funding.sources[0].amountOffsets = new uint256[][](1);
        funding.sources[0].amountOffsets[0] = new uint256[](1);
        funding.sources[0].amountOffsets[0][0] = 4;
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = action;
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.fund(funding, 10);
        _executeFunding(builder.finish(), runtime);
        vm.snapshotGasLastCall("CallIfGasFunding", funded ? "skipped" : "needed");
        assertEq(IERC20(_asset).balanceOf(account), 10);
    }
}

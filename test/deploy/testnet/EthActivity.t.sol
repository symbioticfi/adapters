// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {NativeRedemptionVault} from "./EthRedemptions.t.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {ILidoWithdrawalQueue} from "src/interfaces/ll-adapter/lido/ILidoWithdrawalQueue.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {ActivityContext} from "script/deploy/testnet/activity/ActivityContext.sol";
import {EthActivityScript} from "script/deploy/testnet/activity/EthActivity.s.sol";
import {TestnetCowSettlement} from "script/deploy/testnet/protocols/TestnetServices.sol";
import {
    TestnetEthDeploymentScript,
    TestnetEtherFiPool,
    TestnetLidoQueue,
    TestnetNativeStake,
    TestnetWETH,
    TestnetWrappedStake
} from "script/deploy/testnet/protocols/TestnetEthRedemptions.sol";

contract EthActivityBrokenGetter {
    error GetterFailed();

    function requestIds(uint256) public pure returns (uint64) {
        revert GetterFailed();
    }
}

/// @title EthActivityTest
/// @notice Verifies native backing, bounded rotating settlement and inventory replenishment through production accounts.
contract EthActivityTest is Test {
    address internal _weth;
    address internal _activity;
    ActivityContext internal _lido;
    ActivityContext internal _etherfi;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 100 ether);
        _weth = address(new TestnetWETH());
        _activity = address(new EthActivityScript());
        address factory = address(new MigratablesFactory(address(this)));
        address cow = address(new TestnetCowSettlement());
        address deployer = address(new TestnetEthDeploymentScript(address(this), false));
        address vault = address(new NativeRedemptionVault(_weth));
        for (uint256 i; i < 2; ++i) {
            (address token, address oracle, address endpoint, address implementation) =
                TestnetEthDeploymentScript(deployer).deploy(factory, cow, _weth, i == 1);
            MigratablesFactory(factory).whitelist(implementation);
            address account = MigratablesFactory(factory)
                .create(uint64(i + 1), address(this), abi.encode(vault, makeAddr("adapter")));
            ActivityContext memory context = ActivityContext({
                owner: address(this),
                asset: _weth,
                token: token,
                endpoint: endpoint,
                feed: address(0),
                oracle: oracle,
                account: account,
                profile: i == 0 ? 48 : 47,
                kind: 6,
                variant: uint8(i),
                assets: 1 ether,
                seed: 123,
                cursor: 0
            });
            if (i == 0) _lido = context;
            else _etherfi = context;
        }
    }

    function test_ReplenishmentDepositsRealETHAndStopsAtInventoryTarget() public {
        uint256 before = address(this).balance;
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 0);
        assertEq(before - address(this).balance, 1 ether);
        assertEq(IERC20(_lido.token).balanceOf(address(this)), 1 ether);
        assertEq(IERC20(TestnetWrappedStake(_lido.token).underlying()).allowance(address(this), _lido.token), 0);
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 0);
        assertEq(before - address(this).balance, 1 ether);
        _assertBacking(_lido);
    }

    function test_InventoryTargetUsesTheFundedWrappedRate() public {
        EthActivityScript(_activity).runBase(_lido, false);
        address stake = TestnetWrappedStake(_lido.token).underlying();
        TestnetNativeStake(stake).deposit{value: 0.1 ether}(_lido.token);
        _lido.assets = 2 ether;
        uint256 before = address(this).balance;
        EthActivityScript(_activity).runBase(_lido, false);
        assertEq(before - address(this).balance, 0.9 ether);
        assertApproxEqAbs(
            TestnetWrappedStake(_lido.token).getStETHByWstETH(IERC20(_lido.token).balanceOf(address(this))), 2 ether, 1
        );
        _assertBacking(_lido);
    }

    function test_LidoRequiresRealReadinessThenSyncCollectsAndRemovesTheClaim() public {
        _queue(_lido, 1 ether);
        _lido.assets = 0;
        uint256 timestamp = block.timestamp;
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 0);
        assertEq(block.timestamp, timestamp);
        assertEq(EthActivityScript(_activity).pendingRequests(_lido.account, _lido.endpoint), 1);
        vm.warp(timestamp + 1 days);
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 1);
        assertEq(IERC20(_weth).balanceOf(_lido.account), 1 ether);
        assertEq(EthActivityScript(_activity).pendingRequests(_lido.account, _lido.endpoint), 0);
        assertEq(EthActivityScript(_activity).nextCursor(), 0);
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 0);
        _assertBacking(_lido);
    }

    function test_PreviouslyFinalizedRequestsAreCollectedAndCounted() public {
        _queue(_lido, 1 ether);
        vm.warp(block.timestamp + 1 days);
        TestnetLidoQueue(payable(_lido.endpoint)).finalize(1, 1 ether);
        _lido.assets = 0;
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 1);
        assertEq(IERC20(_weth).balanceOf(_lido.account), 1 ether);
        _assertBacking(_lido);
    }

    function test_EtherFiSettlesItsNativeNFTAndPreservesWithdrawalFees() public {
        TestnetEtherFiPool(payable(_etherfi.endpoint)).setWithdrawalFee(125);
        _queue(_etherfi, 2 ether);
        vm.warp(block.timestamp + 1 days);
        _etherfi.assets = 0;
        assertEq(EthActivityScript(_activity).runBase(_etherfi, false), 1);
        assertEq(IERC20(_weth).balanceOf(_etherfi.account), 2 ether - 125 gwei);
        assertEq(_etherfi.endpoint.balance, 125 gwei);
        assertEq(EthActivityScript(_activity).pendingRequests(_etherfi.account, _etherfi.endpoint), 0);
        _assertBacking(_etherfi);
    }

    function test_LiquidityReturnsShareOneBudgetAndCannotCreateUnbackedInventory() public {
        _queue(_lido, 3 ether);
        address stake = TestnetWrappedStake(_lido.token).underlying();
        TestnetNativeStake(stake).deployLiquidity(address(this), 2 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 before = address(this).balance;
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 0);
        assertEq(before - address(this).balance, 1 ether);
        assertEq(TestnetNativeStake(stake).deployedAssets(), 1 ether);
        assertEq(IERC20(_lido.token).balanceOf(address(this)), 0);
        assertEq(EthActivityScript(_activity).pendingRequests(_lido.account, _lido.endpoint), 1);
        _assertBacking(_lido);
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 1);
        assertEq(before - address(this).balance, 2 ether);
        assertEq(TestnetNativeStake(stake).deployedAssets(), 0);
        assertEq(IERC20(_weth).balanceOf(_lido.account), 3 ether);
        assertEq(IERC20(_lido.token).balanceOf(address(this)), 0);
        _assertBacking(_lido);
    }

    function test_FinalizationBatchRotatesAndEventuallyClearsEveryRequest() public {
        for (uint256 i; i < 10; ++i) {
            _queue(_lido, 1 ether);
        }
        assertEq(EthActivityScript(_activity).pendingRequests(_lido.account, _lido.endpoint), 10);
        _lido.cursor = 8;
        _lido.assets = 0;
        vm.warp(block.timestamp + 1 days);
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 8);
        assertEq(IERC20(_weth).balanceOf(_lido.account), 8 ether);
        assertEq(EthActivityScript(_activity).pendingRequests(_lido.account, _lido.endpoint), 2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 8;
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            ILidoWithdrawalQueue(_lido.endpoint).getWithdrawalStatus(ids);
        assertFalse(statuses[0].isFinalized);
        assertFalse(statuses[1].isFinalized);
        _lido.cursor = EthActivityScript(_activity).nextCursor();
        assertEq(EthActivityScript(_activity).runBase(_lido, false), 2);
        assertEq(EthActivityScript(_activity).pendingRequests(_lido.account, _lido.endpoint), 0);
        assertEq(IERC20(_weth).balanceOf(_lido.account), 10 ether);
        _assertBacking(_lido);
    }

    function test_ImmatureBatchAdvancesCursorWithoutChangingClock() public {
        for (uint256 i; i < 10; ++i) {
            _queue(_etherfi, 1 ether);
        }
        _etherfi.assets = 0;
        _etherfi.cursor = 3;
        uint256 timestamp = block.timestamp;
        assertEq(EthActivityScript(_activity).runBase(_etherfi, false), 0);
        assertEq(EthActivityScript(_activity).nextCursor(), 1);
        assertEq(block.timestamp, timestamp);
        assertEq(EthActivityScript(_activity).pendingRequests(_etherfi.account, _etherfi.endpoint), 10);
        _assertBacking(_etherfi);
    }

    function test_InsufficientBroadcasterETHDefersWithoutMinting() public {
        _queue(_etherfi, 3 ether);
        address stake = TestnetWrappedStake(_etherfi.token).underlying();
        TestnetNativeStake(stake).deployLiquidity(address(this), 2 ether);
        vm.warp(block.timestamp + 1 days);
        vm.deal(address(this), 0);
        assertEq(EthActivityScript(_activity).runBase(_etherfi, false), 0);
        assertEq(TestnetNativeStake(stake).deployedAssets(), 2 ether);
        assertEq(IERC20(_etherfi.token).balanceOf(address(this)), 0);
        assertEq(IERC20(_weth).balanceOf(_etherfi.account), 0);
        _assertBacking(_etherfi);
    }

    function test_RejectsWrongOwnerOrForeignTokenAndBubblesUnexpectedGetterFailures() public {
        ActivityContext memory context = _lido;
        context.owner = makeAddr("unrelated owner");
        vm.expectRevert(EthActivityScript.InvalidFixture.selector);
        EthActivityScript(_activity).runBase(context, false);
        context = _lido;
        context.token = _weth;
        vm.expectRevert(EthActivityScript.InvalidFixture.selector);
        EthActivityScript(_activity).runBase(context, false);
        _queue(_lido, 1 ether);
        address broken = address(new EthActivityBrokenGetter());
        vm.expectRevert(EthActivityBrokenGetter.GetterFailed.selector);
        EthActivityScript(_activity).pendingRequests(broken, _lido.endpoint);
    }

    function test_OwnedFixturesHaveTheSameMaintenanceSemanticsOnSepolia() public {
        vm.chainId(11_155_111);
        _queue(_etherfi, 1 ether);
        vm.warp(block.timestamp + 1 days);
        _etherfi.assets = 0;
        assertEq(EthActivityScript(_activity).runBase(_etherfi, false), 1);
        assertEq(IERC20(_weth).balanceOf(_etherfi.account), 1 ether);
        _assertBacking(_etherfi);
    }

    function _queue(ActivityContext memory context, uint256 amount) internal {
        address stake = TestnetWrappedStake(context.token).underlying();
        TestnetNativeStake(stake).deposit{value: amount}(address(this));
        IERC20(stake).approve(context.token, amount);
        uint256 shares = TestnetWrappedStake(context.token).wrap(amount);
        IERC20(context.token).transfer(context.account, shares);
        IAccount(context.account).sync();
    }

    function _assertBacking(ActivityContext memory context) internal view {
        address stake = TestnetWrappedStake(context.token).underlying();
        assertEq(stake.balance + TestnetNativeStake(stake).deployedAssets(), IERC20(stake).totalSupply());
        assertEq(_weth.balance, IERC20(_weth).totalSupply());
    }

    receive() external payable {}
}

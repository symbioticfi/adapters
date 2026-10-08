// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {EtherFiAccount} from "src/contracts/ll-adapter/EtherFiAccount.sol";
import {LidoAccount} from "src/contracts/ll-adapter/LidoAccount.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IEtherFiWithdrawRequestNFT} from "src/interfaces/ll-adapter/etherfi/IEtherFiWithdrawRequestNFT.sol";
import {ILidoWithdrawalQueue} from "src/interfaces/ll-adapter/lido/ILidoWithdrawalQueue.sol";
import {IOracle} from "src/interfaces/ll-adapter/IOracle.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {TestnetCowSettlement} from "script/deploy/testnet/protocols/TestnetServices.sol";
import {
    TestnetEthDeploymentScript,
    TestnetEtherFiPool,
    TestnetEtherFiRedemptionManager,
    TestnetLidoQueue,
    TestnetNativeStake,
    TestnetWETH,
    TestnetWrappedStake
} from "script/deploy/testnet/protocols/TestnetEthRedemptions.sol";

/// @title NativeRedemptionVault
/// @notice Vault asset boundary for production account initialization in native redemption tests.
contract NativeRedemptionVault is ERC4626 {
    constructor(address newAsset) ERC20("Native test vault", "ntvWETH") ERC4626(IERC20(newAsset)) {}
}

/// @title EthRedemptionsTest
/// @notice Exercises real deposit funding, production account requests, delayed settlement and native wrapping.
contract EthRedemptionsTest is Test {
    address internal _weth;
    address internal _lido;
    address internal _etherfi;
    address internal _lidoAccount;
    address internal _etherfiAccount;
    address internal _attacker;
    address internal _adapter;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 10_000 ether);
        _attacker = makeAddr("attacker");
        _adapter = makeAddr("adapter");
        _weth = address(new TestnetWETH());
        address factory = address(new MigratablesFactory(address(this)));
        address cow = address(new TestnetCowSettlement());
        address deployer = address(new TestnetEthDeploymentScript(address(this), false));
        address vault = address(new NativeRedemptionVault(_weth));
        (,,, address lidoImplementation) = TestnetEthDeploymentScript(deployer).deploy(factory, cow, _weth, false);
        MigratablesFactory(factory).whitelist(lidoImplementation);
        _lidoAccount = MigratablesFactory(factory).create(1, address(this), abi.encode(vault, _adapter));
        _lido = LidoAccount(payable(_lidoAccount)).WITHDRAWAL_QUEUE();
        (,,, address etherfiImplementation) = TestnetEthDeploymentScript(deployer).deploy(factory, cow, _weth, true);
        MigratablesFactory(factory).whitelist(etherfiImplementation);
        _etherfiAccount = MigratablesFactory(factory).create(2, address(this), abi.encode(vault, _adapter));
        _etherfi = EtherFiAccount(payable(_etherfiAccount)).LIQUIDITY_POOL();
    }

    function test_LidoUsesFundedNativeRateAndSettlesProductionAccount() public {
        _fundWrapped(_lidoAccount, 10 ether);
        TestnetNativeStake(TestnetLidoQueue(payable(_lido)).stETH()).deposit{value: 1 ether}(
            IAccount(_lidoAccount).TOKEN_TO_REDEEM()
        );
        assertEq(IOracle(IAccount(_lidoAccount).ORACLE()).getPrice(), 1.1e18);
        assertEq(IAccount(_lidoAccount).totalAssets(), 11 ether);

        IAccount(_lidoAccount).sync();
        assertEq(IERC20(IAccount(_lidoAccount).TOKEN_TO_REDEEM()).balanceOf(_lidoAccount), 0);
        assertEq(LidoAccount(payable(_lidoAccount)).pendingAssets(), 11 ether);
        assertEq(IERC20(TestnetLidoQueue(payable(_lido)).stETH()).balanceOf(_lido), 11 ether);

        vm.expectRevert(TestnetLidoQueue.NotReady.selector);
        TestnetLidoQueue(payable(_lido)).finalize(1, 11 ether);
        IAccount(_lidoAccount).sync();
        assertEq(LidoAccount(payable(_lidoAccount)).requestIds(0), 1);

        vm.warp(block.timestamp + 1 days);
        TestnetLidoQueue(payable(_lido)).finalize(1, 11 ether);
        assertEq(TestnetLidoQueue(payable(_lido)).reservedAssets(), 11 ether);
        vm.prank(_attacker);
        IAccount(_lidoAccount).sync();
        assertEq(IERC20(_weth).balanceOf(_lidoAccount), 11 ether);
        assertEq(address(_lidoAccount).balance, 0);
        assertEq(TestnetLidoQueue(payable(_lido)).reservedAssets(), 0);
        assertEq(LidoAccount(payable(_lidoAccount)).pendingAssets(), 0);
        assertEq(IAccount(_lidoAccount).totalAssets(), 11 ether);
        _assertWethBacking();
    }

    function test_LidoLiquidityMustReturnBeforeFinalizationAndCannotOverpay() public {
        _fundWrapped(_lidoAccount, 3 ether);
        address stake = TestnetLidoQueue(payable(_lido)).stETH();
        TestnetNativeStake(stake).deployLiquidity(address(this), 2 ether);
        assertEq(stake.balance + TestnetNativeStake(stake).deployedAssets(), IERC20(stake).totalSupply());
        IAccount(_lidoAccount).sync();
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(TestnetLidoQueue.InvalidAmount.selector);
        TestnetLidoQueue(payable(_lido)).finalize(1, 3 ether + 1);
        vm.expectRevert(TestnetNativeStake.InsufficientLiquidity.selector);
        TestnetLidoQueue(payable(_lido)).finalize(1, 3 ether);
        assertEq(TestnetLidoQueue(payable(_lido)).reservedAssets(), 0);
        assertEq(LidoAccount(payable(_lidoAccount)).pendingAssets(), 3 ether);

        TestnetNativeStake(stake).fundLiquidity{value: 2 ether}();
        TestnetLidoQueue(payable(_lido)).finalize(1, 2.9 ether);
        assertEq(LidoAccount(payable(_lidoAccount)).pendingAssets(), 2.9 ether);
        IAccount(_lidoAccount).sync();
        assertEq(IERC20(_weth).balanceOf(_lidoAccount), 2.9 ether);
        assertEq(_lido.balance, 0.1 ether);
        assertEq(IERC20(stake).totalSupply(), 0);
        _assertWethBacking();
    }

    function test_LidoRejectsWrongOwnerClaimsDuplicateSettlementAndUnbackedRequests() public {
        _fundWrapped(_lidoAccount, 1 ether);
        IAccount(_lidoAccount).sync();
        vm.warp(block.timestamp + 1 days);
        TestnetLidoQueue(payable(_lido)).finalize(1, 1 ether);

        vm.prank(_attacker);
        vm.expectRevert(TestnetLidoQueue.InvalidCaller.selector);
        TestnetLidoQueue(payable(_lido)).claimWithdrawal(1);
        vm.expectRevert(TestnetLidoQueue.InvalidRequest.selector);
        TestnetLidoQueue(payable(_lido)).finalize(1, 1 ether);
        IAccount(_lidoAccount).sync();
        vm.expectRevert(TestnetLidoQueue.NotReady.selector);
        TestnetLidoQueue(payable(_lido)).claimWithdrawal(1);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(_attacker);
        vm.expectRevert();
        TestnetLidoQueue(payable(_lido)).requestWithdrawalsWstETH(amounts, _attacker);
        assertEq(_attacker.balance, 0);
    }

    function test_LidoSplitsRequestsAtProtocolMaximum() public {
        _fundWrapped(_lidoAccount, 1250 ether);
        IAccount(_lidoAccount).sync();
        assertEq(LidoAccount(payable(_lidoAccount)).requestIds(0), 1);
        assertEq(LidoAccount(payable(_lidoAccount)).requestIds(1), 2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            ILidoWithdrawalQueue(_lido).getWithdrawalStatus(ids);
        assertEq(statuses[0].amountOfStETH, 1000 ether);
        assertEq(statuses[1].amountOfStETH, 250 ether);
        vm.warp(block.timestamp + 1 days);
        TestnetLidoQueue(payable(_lido)).finalize(2, 250 ether);
        IAccount(_lidoAccount).sync();
        assertEq(LidoAccount(payable(_lidoAccount)).pendingAssets(), 1000 ether);
        TestnetLidoQueue(payable(_lido)).finalize(1, 1000 ether);
        IAccount(_lidoAccount).sync();
        assertEq(IERC20(_weth).balanceOf(_lidoAccount), 1250 ether);
    }

    function test_LidoAcceptsFundedStETHInventoryAlongsideWrappedInventory() public {
        _fundWrapped(_lidoAccount, 1 ether);
        TestnetNativeStake(TestnetLidoQueue(payable(_lido)).stETH()).deposit{value: 2 ether}(_lidoAccount);
        IAccount(_lidoAccount).sync();
        assertEq(LidoAccount(payable(_lidoAccount)).pendingAssets(), 3 ether);
        vm.warp(block.timestamp + 1 days);
        TestnetLidoQueue(payable(_lido)).finalize(1, 1 ether);
        TestnetLidoQueue(payable(_lido)).finalize(2, 2 ether);
        IAccount(_lidoAccount).sync();
        assertEq(IERC20(_weth).balanceOf(_lidoAccount), 3 ether);
    }

    function test_EtherFiQueuesCustodiedUnderlyingAndSyncWrapsFundedPayout() public {
        _fundWrapped(_etherfiAccount, 4 ether);
        TestnetEtherFiPool(payable(_etherfi)).setWithdrawalFee(125);
        IAccount(_etherfiAccount).sync();
        uint256 expected = 4 ether - 125 gwei;
        assertEq(EtherFiAccount(payable(_etherfiAccount)).pendingAssets(), expected);
        assertEq(IERC20(TestnetEtherFiPool(payable(_etherfi)).eETH()).balanceOf(_etherfi), 4 ether);
        IEtherFiWithdrawRequestNFT.WithdrawRequest memory request = IEtherFiWithdrawRequestNFT(_etherfi).getRequest(1);
        assertTrue(request.isValid);
        assertEq(request.feeGwei, 125);
        assertEq(TestnetEtherFiPool(payable(_etherfi)).ownerOf(1), _etherfiAccount);

        vm.expectRevert(TestnetEtherFiPool.NotReady.selector);
        TestnetEtherFiPool(payable(_etherfi)).finalize(1);
        vm.warp(block.timestamp + 1 days);
        TestnetEtherFiPool(payable(_etherfi)).finalize(1);
        assertEq(TestnetEtherFiPool(payable(_etherfi)).reservedAssets(), expected);
        vm.prank(_attacker);
        IAccount(_etherfiAccount).sync();
        assertEq(IERC20(_weth).balanceOf(_etherfiAccount), expected);
        assertEq(EtherFiAccount(payable(_etherfiAccount)).pendingAssets(), 0);
        assertEq(TestnetEtherFiPool(payable(_etherfi)).reservedAssets(), 0);
        assertEq(_etherfi.balance, 125 gwei);
        assertFalse(IEtherFiWithdrawRequestNFT(_etherfi).getRequest(1).isValid);
        _assertWethBacking();
    }

    function test_EtherFiInstantUsesNativeRateFundedCashAndNoPersistentApproval() public {
        _fundWrapped(_etherfiAccount, 2 ether);
        address wrapper = IAccount(_etherfiAccount).TOKEN_TO_REDEEM();
        TestnetNativeStake(TestnetEtherFiPool(payable(_etherfi)).eETH()).deposit{value: 0.2 ether}(wrapper);
        address manager = TestnetEtherFiPool(payable(_etherfi)).redemptionManager();
        TestnetEtherFiRedemptionManager(manager).configure(true, 0, 3_000_000_000, 0);
        assertEq(IOracle(IAccount(_etherfiAccount).ORACLE()).getPrice(), 1.1e18);

        IAccount(_etherfiAccount).sync();
        assertEq(IERC20(_weth).balanceOf(_etherfiAccount), 2.2 ether);
        assertEq(IERC20(wrapper).balanceOf(_etherfiAccount), 0);
        assertEq(IERC20(wrapper).allowance(_etherfiAccount, manager), 0);
        assertEq(EtherFiAccount(payable(_etherfiAccount)).pendingAssets(), 0);
        assertEq(TestnetEtherFiPool(payable(_etherfi)).nextRequestId(), 1);
        assertEq(IAccount(_etherfiAccount).totalAssets(), 2.2 ether);
        _assertWethBacking();
    }

    function test_EtherFiLowCashFallsBackToQueueThenRequiresCashReturn() public {
        _fundWrapped(_etherfiAccount, 2 ether);
        address stake = TestnetEtherFiPool(payable(_etherfi)).eETH();
        TestnetNativeStake(stake).deployLiquidity(address(this), 1.5 ether);
        address manager = TestnetEtherFiPool(payable(_etherfi)).redemptionManager();
        TestnetEtherFiRedemptionManager(manager).configure(true, 0, 10_000_000_000, 0);
        IAccount(_etherfiAccount).sync();
        assertEq(EtherFiAccount(payable(_etherfiAccount)).pendingAssets(), 2 ether);
        assertEq(IERC20(_weth).balanceOf(_etherfiAccount), 0);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(TestnetNativeStake.InsufficientLiquidity.selector);
        TestnetEtherFiPool(payable(_etherfi)).finalize(1);
        assertFalse(TestnetEtherFiPool(payable(_etherfi)).finalized(1));
        TestnetNativeStake(stake).fundLiquidity{value: 1.5 ether}();
        TestnetEtherFiPool(payable(_etherfi)).finalize(1);
        EtherFiAccount(payable(_etherfiAccount)).claimWithdraw(1);
        assertEq(IERC20(_weth).balanceOf(_etherfiAccount), 2 ether);
        _assertWethBacking();
    }

    function test_EtherFiFeeOrBucketCapacityFallsBackToQueue() public {
        _fundWrapped(_etherfiAccount, 2 ether);
        address manager = TestnetEtherFiPool(payable(_etherfi)).redemptionManager();
        TestnetEtherFiRedemptionManager(manager).configure(true, 25, 10_000_000_000, 0);
        IAccount(_etherfiAccount).sync();
        assertEq(EtherFiAccount(payable(_etherfiAccount)).pendingAssets(), 2 ether);
        _fundWrapped(_etherfiAccount, 1 ether);
        TestnetEtherFiRedemptionManager(manager).configure(true, 0, 500_000_000, 0);
        IAccount(_etherfiAccount).sync();
        assertEq(EtherFiAccount(payable(_etherfiAccount)).pendingAssets(), 3 ether);
        assertEq(TestnetEtherFiPool(payable(_etherfi)).nextRequestId(), 3);
    }

    function test_EtherFiBucketConsumesAndRefillsAgainstActualCash() public {
        _fundWrapped(_etherfiAccount, 1 ether);
        address manager = TestnetEtherFiPool(payable(_etherfi)).redemptionManager();
        TestnetEtherFiRedemptionManager(manager).configure(true, 0, 1_000_000_000, 1_000_000);
        IAccount(_etherfiAccount).sync();
        _fundWrapped(_etherfiAccount, 1 ether);
        address eth = TestnetEtherFiRedemptionManager(manager).ETH_ADDRESS();
        assertFalse(TestnetEtherFiRedemptionManager(manager).canRedeem(1 ether, eth));
        vm.warp(block.timestamp + 1000);
        assertTrue(TestnetEtherFiRedemptionManager(manager).canRedeem(1 ether, eth));
        IAccount(_etherfiAccount).sync();
        assertEq(IERC20(_weth).balanceOf(_etherfiAccount), 2 ether);
        assertEq(TestnetEtherFiPool(payable(_etherfi)).nextRequestId(), 1);
    }

    function test_EtherFiDirectInstantRedemptionChargesConfiguredFeeFromRealBacking() public {
        _fundWrapped(_etherfiAccount, 1 ether);
        address manager = TestnetEtherFiPool(payable(_etherfi)).redemptionManager();
        address wrapper = IAccount(_etherfiAccount).TOKEN_TO_REDEEM();
        address eth = TestnetEtherFiRedemptionManager(manager).ETH_ADDRESS();
        TestnetEtherFiRedemptionManager(manager).configure(true, 25, 1_000_000_000, 0);
        vm.startPrank(_etherfiAccount);
        IERC20(wrapper).approve(manager, 1 ether);
        TestnetEtherFiRedemptionManager(manager).redeemWeEth(1 ether, _attacker, eth);
        vm.stopPrank();
        assertEq(_attacker.balance, 0.9975 ether);
        assertEq(_etherfi.balance, 0.0025 ether);
        assertEq(IERC20(wrapper).totalSupply(), 0);
        assertEq(IERC20(TestnetEtherFiPool(payable(_etherfi)).eETH()).totalSupply(), 0);
    }

    function test_EtherFiInstantRejectsUnsupportedOutputOrUnownedShares() public {
        _fundWrapped(_etherfiAccount, 1 ether);
        address manager = TestnetEtherFiPool(payable(_etherfi)).redemptionManager();
        address eth = TestnetEtherFiRedemptionManager(manager).ETH_ADDRESS();
        TestnetEtherFiRedemptionManager(manager).configure(true, 0, 1_000_000_000, 0);
        vm.expectRevert(TestnetEtherFiRedemptionManager.RedemptionUnavailable.selector);
        TestnetEtherFiRedemptionManager(manager).redeemWeEth(1 ether, _attacker, _weth);
        vm.expectRevert();
        vm.prank(_attacker);
        TestnetEtherFiRedemptionManager(manager).redeemWeEth(1 ether, _attacker, eth);
        assertEq(_attacker.balance, 0);
        assertTrue(TestnetEtherFiRedemptionManager(manager).canRedeem(1 ether, eth));
    }

    function test_EtherFiCannotClaimOtherOwnersRequestOrPayUnfundedCaller() public {
        _fundWrapped(_etherfiAccount, 1 ether);
        address stake = TestnetEtherFiPool(payable(_etherfi)).eETH();
        IAccount(_etherfiAccount).sync();
        vm.warp(block.timestamp + 1 days);
        TestnetEtherFiPool(payable(_etherfi)).finalize(1);
        vm.prank(_attacker);
        vm.expectRevert(TestnetEtherFiPool.InvalidCaller.selector);
        TestnetEtherFiPool(payable(_etherfi)).claimWithdraw(1);
        vm.prank(_attacker);
        vm.expectRevert(TestnetEtherFiPool.InvalidCaller.selector);
        TestnetEtherFiPool(payable(_etherfi)).redeemInstant(1 ether, _attacker, 0);
        vm.prank(_attacker);
        vm.expectRevert(TestnetNativeStake.InvalidCaller.selector);
        TestnetNativeStake(stake).release(_attacker, 1 ether);
        EtherFiAccount(payable(_etherfiAccount)).claimWithdraw(1);
        vm.expectRevert(TestnetEtherFiPool.NotReady.selector);
        TestnetEtherFiPool(payable(_etherfi)).claimWithdraw(1);
        assertEq(_attacker.balance, 0);
    }

    function test_NativeStakeDepositAndFundingCannotMintUnbackedSupply() public {
        address stake = TestnetEtherFiPool(payable(_etherfi)).eETH();
        vm.expectRevert(TestnetNativeStake.InvalidAmount.selector);
        TestnetNativeStake(stake).deposit(address(this));
        vm.expectRevert(TestnetNativeStake.InvalidAmount.selector);
        TestnetNativeStake(stake).fundLiquidity{value: 1 ether}();
        vm.prank(_attacker);
        vm.expectRevert();
        TestnetNativeStake(stake).deployLiquidity(_attacker, 1 ether);
        assertEq(IERC20(stake).totalSupply(), 0);
        assertEq(stake.balance, 0);
    }

    function testFuzz_WethSupplyRemainsNativeBackedThroughDepositAndWithdraw(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        depositAmount = bound(depositAmount, 1, 100 ether);
        withdrawAmount = bound(withdrawAmount, 0, depositAmount);
        TestnetWETH(payable(_weth)).deposit{value: depositAmount}();
        TestnetWETH(payable(_weth)).withdraw(withdrawAmount);
        assertEq(IERC20(_weth).balanceOf(address(this)), depositAmount - withdrawAmount);
        _assertWethBacking();
    }

    function testFuzz_LidoFundedRequestSettlementPreservesAssets(uint256 amount) public {
        amount = bound(amount, 100, 1000 ether);
        _fundWrapped(_lidoAccount, amount);
        IAccount(_lidoAccount).sync();
        assertEq(IAccount(_lidoAccount).totalAssets(), amount);
        vm.warp(block.timestamp + 1 days);
        TestnetLidoQueue(payable(_lido)).finalize(1, amount);
        IAccount(_lidoAccount).sync();
        assertEq(IAccount(_lidoAccount).totalAssets(), amount);
        assertEq(IERC20(_weth).balanceOf(_lidoAccount), amount);
        _assertWethBacking();
    }

    function _fundWrapped(address account, uint256 nativeAmount) internal {
        address wrapper = IAccount(account).TOKEN_TO_REDEEM();
        address stake = TestnetWrappedStake(wrapper).underlying();
        TestnetNativeStake(stake).deposit{value: nativeAmount}(address(this));
        IERC20(stake).approve(wrapper, nativeAmount);
        uint256 shares = TestnetWrappedStake(wrapper).wrap(nativeAmount);
        IERC20(wrapper).transfer(account, shares);
    }

    function _assertWethBacking() internal view {
        assertEq(_weth.balance, IERC20(_weth).totalSupply());
    }

    receive() external payable {}
}

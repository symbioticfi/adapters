// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AaveHealthFactor} from "src/contracts/merkle_adapter/borrow_capability/AaveHealthFactor.sol";
import {BorrowCapability} from "src/contracts/merkle_adapter/BorrowCapability.sol";
import {CoWPositionExecutor} from "src/contracts/periphery/CoWPositionExecutor.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MorphoBlueHealthFactor} from "src/contracts/merkle_adapter/borrow_capability/MorphoBlueHealthFactor.sol";

import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {ICoWPositionExecutor} from "src/interfaces/periphery/ICoWPositionExecutor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IPositionFlashLender} from "src/interfaces/periphery/ICoWPositionDependencies.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, IMorpho, IMorphoBase, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/BorrowCapabilityMocks.sol";
import {CapabilityTestBase} from "test/adapters/merkle-adapter/CapabilityTestBase.sol";
import {IBorrowCapabilityAavePool} from "test/adapters/merkle-adapter/BorrowCapabilityMainnet.t.sol";
import {
    ICoWCapabilitySettlementMainnet,
    ICoWCapabilityAuthenticationMainnet
} from "test/adapters/merkle-adapter/CoWSwapCapabilityMainnet.t.sol";

interface IPositionForkRouter {
    struct Loan {
        uint256 amount;
        address borrower;
        address lender;
        address token;
    }

    function settlementContract() external view returns (address);
    function flashLoanAndSettle(Loan[] calldata loans, bytes calldata settlement) external;
}

interface IPositionForkAuthentication {
    function isSolver(address account) external view returns (bool);
}

interface IPositionForkAave {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
}

/// @dev The market and deterministic oracle are fixtures; Morpho custody, lending, debt and callbacks are deployed code.
contract PositionForkMorphoOracle {
    function price() external pure returns (uint256) {
        return 2000e24;
    }
}

/// @dev Uses the deployed CoW router/settlement and Aave/Morpho protocols. Only initial margin, solver buy liquidity,
///      the authorized fork solver, and a deterministic Morpho market/oracle are local fixtures. No hooks or protocol mocks.
contract CoWPositionExecutorMainnetTest is CapabilityTestBase {
    uint256 internal constant FORK_BLOCK = 25_982_370;
    address internal constant ROUTER = 0x9da8B48441583a2b93e2eF8213aAD0EC0b392C69;
    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address internal constant USDC_DEBT = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    address internal constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant PRINCIPAL = 1000e6;
    uint256 internal constant COLLATERAL = 1 ether;

    ICoWCapabilitySettlementMainnet internal settlement = ICoWCapabilitySettlementMainnet(SETTLEMENT);
    CoWPositionExecutor internal executor;
    address internal solver = makeAddr("CoW position fork solver");
    MarketParams internal market;
    MorphoBlueHealthFactor internal morphoHealth;
    AaveHealthFactor internal aaveHealth;
    uint256 internal premium;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for CoW position mainnet integration");
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("MAINNET_FORK_BLOCK", FORK_BLOCK));
        assertEq(block.chainid, 1);
        assertEq(IPositionForkRouter(ROUTER).settlementContract(), SETTLEMENT);
        assertEq(settlement.vaultRelayer(), RELAYER);
        address authentication = settlement.authenticator();
        // The deployed router must already be authorized; do not fabricate this integration prerequisite.
        assertTrue(IPositionForkAuthentication(authentication).isSolver(ROUTER));
        vm.prank(ICoWCapabilityAuthenticationMainnet(authentication).manager());
        ICoWCapabilityAuthenticationMainnet(authentication).addSolver(solver);

        _deployAdapter(USDC);
        _installCapability(adapter, address(new BorrowCapability()), _borrowSelectors());
        aaveHealth = new AaveHealthFactor();
        morphoHealth = new MorphoBlueHealthFactor();
        // Exercise the same immutable factory creation path used by the UI.
        ImmutableFactory factory = new ImmutableFactory(type(CoWPositionExecutor).creationCode);
        executor = CoWPositionExecutor(factory.create(abi.encode(address(this), address(adapter), ROUTER, POOL)));
        uint256 bps = IPositionForkAave(POOL).FLASHLOAN_PREMIUM_TOTAL();
        premium = (PRINCIPAL * bps + 5000) / 10_000;
        assertGt(premium, 0);
        deal(WETH, address(adapter), 10 ether);
    }

    function test_MainnetThirdPartyCannotInitiateExecutorFlashLoan() public {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = USDC;
        amounts[0] = PRINCIPAL;
        vm.expectRevert(ICoWPositionExecutor.InvalidCallback.selector);
        IPositionFlashLender(POOL)
            .flashLoan(address(executor), assets, amounts, new uint256[](1), address(executor), "", 0);
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0);
        _setupAave(false);
        _arm(_aaveIntent(true));
        vm.expectRevert(ICoWPositionExecutor.InvalidCallback.selector);
        IPositionFlashLender(POOL)
            .flashLoan(address(executor), assets, amounts, new uint256[](1), address(executor), "", 0);
        assertTrue(executor.active());
        assertEq(executor.lastCompletedOrderHash(), bytes32(0));
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0);
    }

    function test_MainnetAaveLeverageWithRealCoWFlashSettlement() public {
        _setupAave(false);
        uint256 collateralBefore = IERC20(A_WETH).balanceOf(address(adapter));
        ICoWPositionExecutor.Intent memory intent = _aaveIntent(true);
        bytes memory uid = _arm(intent);
        _execute(intent);
        assertApproxEqAbs(IERC20(A_WETH).balanceOf(address(adapter)), collateralBefore + COLLATERAL, 2);
        assertApproxEqAbs(IERC20(USDC_DEBT).balanceOf(address(adapter)), PRINCIPAL + premium, 2);
        _assertCompleted(intent, uid);
    }

    function test_MainnetAaveDeleverageWithRealCoWFlashSettlement() public {
        _setupAave(true);
        uint256 debtBefore = IERC20(USDC_DEBT).balanceOf(address(adapter));
        uint256 collateralBefore = IERC20(A_WETH).balanceOf(address(adapter));
        ICoWPositionExecutor.Intent memory intent = _aaveIntent(false);
        bytes memory uid = _arm(intent);
        _execute(intent);
        assertApproxEqAbs(IERC20(A_WETH).balanceOf(address(adapter)), collateralBefore - COLLATERAL, 2);
        assertApproxEqAbs(IERC20(USDC_DEBT).balanceOf(address(adapter)), debtBefore - PRINCIPAL, 2);
        _assertCompleted(intent, uid);
    }

    function test_MainnetMorphoLeverageWithRealCoWFlashSettlement() public {
        _setupMorpho(false);
        ICoWPositionExecutor.Intent memory intent = _morphoIntent(true);
        bytes memory uid = _arm(intent);
        _execute(intent);
        assertEq(IMorpho(BLUE).position(_marketId(), address(adapter)).collateral, 11 ether);
        assertEq(MorphoBalancesLib.expectedBorrowAssets(IMorpho(BLUE), market, address(adapter)), PRINCIPAL + premium);
        _assertCompleted(intent, uid);
    }

    function test_MainnetMorphoDeleverageWithRealCoWFlashSettlement() public {
        _setupMorpho(true);
        ICoWPositionExecutor.Intent memory intent = _morphoIntent(false);
        bytes memory uid = _arm(intent);
        _execute(intent);
        assertEq(IMorpho(BLUE).position(_marketId(), address(adapter)).collateral, 9 ether);
        assertApproxEqAbs(MorphoBalancesLib.expectedBorrowAssets(IMorpho(BLUE), market, address(adapter)), PRINCIPAL, 1);
        _assertCompleted(intent, uid);
    }

    function test_MainnetCapabilityHealthFailureRevertsFilledOrderLoanAndPosition() public {
        _setupAave(false);
        ICoWPositionExecutor.Intent memory intent = _aaveIntent(true);
        bytes memory uid = _arm(intent);
        _setHealthFactor(keccak256(abi.encode(_aaveHealthCall().target, _aaveHealthCall().data)), type(uint256).max);
        uint256 collateralBefore = IERC20(A_WETH).balanceOf(address(adapter));
        uint256 settlementBuyBefore = IERC20(WETH).balanceOf(SETTLEMENT);
        vm.expectRevert(IBorrowCapability.HealthFactorTooLow.selector);
        _execute(intent);
        assertEq(settlement.filledAmount(uid), 0);
        assertEq(IERC20(A_WETH).balanceOf(address(adapter)), collateralBefore);
        assertEq(IERC20(USDC_DEBT).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WETH).balanceOf(SETTLEMENT), settlementBuyBefore);
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0);
        assertTrue(executor.active());
    }

    function test_MainnetRevokedLeafRevertsDeleverageAndLoan() public {
        _setupMorpho(true);
        ICoWPositionExecutor.Intent memory intent = _morphoIntent(false);
        bytes memory uid = _arm(intent);
        adapter.revokeRole(_leaf(intent.actions[1]), address(executor));
        uint256 debtSharesBefore = IMorpho(BLUE).position(_marketId(), address(adapter)).borrowShares;
        vm.expectRevert();
        _execute(intent);
        assertEq(settlement.filledAmount(uid), 0);
        assertEq(IMorpho(BLUE).position(_marketId(), address(adapter)).borrowShares, debtSharesBefore);
        assertEq(IMorpho(BLUE).position(_marketId(), address(adapter)).collateral, 10 ether);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0);
        assertTrue(executor.active());
    }

    function _setupAave(bool borrow) internal {
        _setHealthFactor(keccak256(abi.encode(_aaveHealthCall().target, _aaveHealthCall().data)), 1.2e18);
        _manage(WETH, abi.encodeCall(IERC20.approve, (POOL, type(uint256).max)));
        _manage(USDC, abi.encodeCall(IERC20.approve, (POOL, type(uint256).max)));
        _manage(POOL, abi.encodeCall(IBorrowCapabilityAavePool.supply, (WETH, 10 ether, address(adapter), 0)));
        if (borrow) {
            _manage(
                address(adapter),
                abi.encodeCall(
                    IBorrowCapability.borrow,
                    (
                        POOL,
                        _aaveHealthCall().target,
                        abi.encodeCall(IBorrowCapabilityAavePool.borrow, (USDC, 2 * PRINCIPAL, 2, 0, address(adapter))),
                        _aaveHealthCall().data
                    )
                )
            );
            _manage(USDC, abi.encodeCall(IERC20.transfer, (address(this), 2 * PRINCIPAL)));
        }
    }

    function _setupMorpho(bool borrow) internal {
        market = MarketParams(USDC, WETH, address(new PositionForkMorphoOracle()), IRM, 0.86e18);
        IMorpho(BLUE).createMarket(market);
        _setHealthFactor(keccak256(abi.encode(_morphoHealthCall().target, _morphoHealthCall().data)), 1.2e18);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(BLUE, 100_000e6);
        IMorpho(BLUE).supply(market, 100_000e6, 0, address(this), "");
        _manage(WETH, abi.encodeCall(IERC20.approve, (BLUE, type(uint256).max)));
        _manage(USDC, abi.encodeCall(IERC20.approve, (BLUE, type(uint256).max)));
        _manage(BLUE, abi.encodeCall(IMorphoBase.supplyCollateral, (market, 10 ether, address(adapter), "")));
        if (borrow) {
            _manage(
                address(adapter),
                abi.encodeCall(
                    IBorrowCapability.borrow,
                    (
                        BLUE,
                        _morphoHealthCall().target,
                        abi.encodeCall(IMorphoBase.borrow, (market, 2 * PRINCIPAL, 0, address(adapter), address(this))),
                        _morphoHealthCall().data
                    )
                )
            );
        }
    }

    function _aaveIntent(bool leverage) internal view returns (ICoWPositionExecutor.Intent memory intent) {
        intent = _intent(leverage);
        if (leverage) {
            intent.actions = new IMerkleAdapter.Action[](3);
            intent.actions[0] = _action(
                POOL, abi.encodeCall(IBorrowCapabilityAavePool.supply, (WETH, COLLATERAL, address(adapter), 0))
            );
            intent.actions[1] = _checkedAction(
                1,
                POOL,
                abi.encodeCall(IBorrowCapabilityAavePool.borrow, (USDC, PRINCIPAL + premium, 2, 0, address(adapter))),
                _aaveHealthCall()
            );
            intent.actions[2] = _action(USDC, abi.encodeCall(IERC20.transfer, (address(executor), PRINCIPAL + premium)));
        } else {
            intent.actions = new IMerkleAdapter.Action[](3);
            intent.actions[0] =
                _action(POOL, abi.encodeCall(IPositionForkAave.repay, (USDC, PRINCIPAL, 2, address(adapter))));
            intent.actions[1] = _checkedAction(
                1,
                POOL,
                abi.encodeCall(IPositionForkAave.withdraw, (WETH, COLLATERAL, address(adapter))),
                _aaveHealthCall()
            );
            intent.actions[2] = _action(WETH, abi.encodeCall(IERC20.transfer, (address(executor), COLLATERAL)));
        }
    }

    function _morphoIntent(bool leverage) internal view returns (ICoWPositionExecutor.Intent memory intent) {
        intent = _intent(leverage);
        if (leverage) {
            intent.actions = new IMerkleAdapter.Action[](3);
            intent.actions[0] =
                _action(BLUE, abi.encodeCall(IMorphoBase.supplyCollateral, (market, COLLATERAL, address(adapter), "")));
            // Keep the funding transfer explicit through an adapter leaf, matching the Aave path.
            intent.actions[1] = _checkedAction(
                5,
                BLUE,
                abi.encodeCall(
                    IMorphoBase.borrow, (market, PRINCIPAL + premium, 0, address(adapter), address(adapter))
                ),
                _morphoHealthCall()
            );
            intent.actions[2] = _action(USDC, abi.encodeCall(IERC20.transfer, (address(executor), PRINCIPAL + premium)));
        } else {
            intent.actions = new IMerkleAdapter.Action[](3);
            intent.actions[0] =
                _action(BLUE, abi.encodeCall(IMorphoBase.repay, (market, PRINCIPAL, 0, address(adapter), "")));
            intent.actions[1] = _checkedAction(
                5,
                BLUE,
                abi.encodeCall(
                    IMorphoBase.withdrawCollateral, (market, COLLATERAL, address(adapter), address(adapter))
                ),
                _morphoHealthCall()
            );
            intent.actions[2] = _action(WETH, abi.encodeCall(IERC20.transfer, (address(executor), COLLATERAL)));
        }
    }

    function _intent(bool leverage) internal view returns (ICoWPositionExecutor.Intent memory intent) {
        intent.order = ICoWPositionExecutor.Order({
            sellToken: leverage ? USDC : WETH,
            buyToken: leverage ? WETH : USDC,
            sellAmount: leverage ? PRINCIPAL : COLLATERAL,
            buyAmount: leverage ? COLLATERAL : PRINCIPAL + premium,
            validTo: uint32(block.timestamp + 1800),
            appData: keccak256("CoW position real settlement")
        });
        intent.leverage = leverage;
        intent.loanAmount = PRINCIPAL;
        intent.maxPremium = premium;
    }

    function _arm(ICoWPositionExecutor.Intent memory intent) internal returns (bytes memory uid) {
        IMerkleAdapter.Action[] memory actions = intent.actions;
        // Three real leaves plus a duplicate padding leaf form a complete four-leaf tree.
        bytes32[] memory hashes = new bytes32[](4);
        for (uint256 i; i < actions.length; ++i) {
            hashes[i] = _leaf(actions[i]);
        }
        hashes[3] = hashes[2];
        bytes32 left = _pair(hashes[0], hashes[1]);
        bytes32 right = _pair(hashes[2], hashes[3]);
        bytes32 root = _pair(left, right);
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        for (uint256 i; i < actions.length; ++i) {
            actions[i].proof = new bytes32[](2);
            actions[i].proof[0] = hashes[i ^ 1];
            actions[i].proof[1] = i < 2 ? right : left;
            adapter.grantRole(hashes[i], address(executor));
        }
        BorrowTestCall memory healthFactor = market.loanToken == address(0) ? _aaveHealthCall() : _morphoHealthCall();
        _includeHealthFactorLeaf(actions, keccak256(abi.encode(healthFactor.target, healthFactor.data)));
        uid = executor.arm(intent);
        assertEq(IERC20(intent.order.sellToken).balanceOf(address(executor)), 0);
        assertEq(IERC20(intent.order.sellToken).allowance(address(executor), RELAYER), intent.order.sellAmount);
        assertEq(executor.isValidSignature(executor.orderHash(), ""), bytes4(0x1626ba7e));
        // Explicit solver liquidity fixture; both token transfer legs still run through deployed GPv2.
        deal(
            intent.order.buyToken,
            SETTLEMENT,
            IERC20(intent.order.buyToken).balanceOf(SETTLEMENT) + intent.order.buyAmount
        );
    }

    function _execute(ICoWPositionExecutor.Intent memory intent) internal {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(intent.order.sellToken);
        tokens[1] = IERC20(intent.order.buyToken);
        uint256[] memory prices = new uint256[](2);
        prices[0] = intent.order.buyAmount;
        prices[1] = intent.order.sellAmount;
        ICoWCapabilitySettlementMainnet.Trade[] memory trades = new ICoWCapabilitySettlementMainnet.Trade[](1);
        trades[0] = ICoWCapabilitySettlementMainnet.Trade({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: address(executor),
            sellAmount: intent.order.sellAmount,
            buyAmount: intent.order.buyAmount,
            validTo: intent.order.validTo,
            appData: intent.order.appData,
            feeAmount: 0,
            flags: 0x40,
            executedAmount: 0,
            signature: abi.encodePacked(address(executor))
        });
        ICoWCapabilitySettlementMainnet.Interaction[][3] memory interactions;
        IPositionForkRouter.Loan[] memory loans = new IPositionForkRouter.Loan[](1);
        loans[0] = IPositionForkRouter.Loan(PRINCIPAL, address(executor), POOL, USDC);
        vm.prank(solver);
        IPositionForkRouter(ROUTER)
            .flashLoanAndSettle(
                loans, abi.encodeCall(ICoWCapabilitySettlementMainnet.settle, (tokens, prices, trades, interactions))
            );
    }

    function _assertCompleted(ICoWPositionExecutor.Intent memory intent, bytes memory uid) internal view {
        assertEq(settlement.filledAmount(uid), intent.order.sellAmount);
        assertFalse(executor.active());
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0);
        assertEq(IERC20(WETH).balanceOf(address(executor)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(intent.order.sellToken).allowance(address(executor), RELAYER), 0);
        assertEq(IERC20(USDC).allowance(address(executor), POOL), 0);
    }

    function _aaveHealthCall() internal view returns (BorrowTestCall memory) {
        return
            BorrowTestCall(
                address(aaveHealth), abi.encodeCall(AaveHealthFactor.getHealthFactor, (POOL, address(adapter)))
            );
    }

    function _morphoHealthCall() internal view returns (BorrowTestCall memory) {
        return BorrowTestCall(
            address(morphoHealth),
            abi.encodeCall(MorphoBlueHealthFactor.getHealthFactor, (BLUE, Id.unwrap(_marketId()), address(adapter)))
        );
    }

    function _checkedAction(uint256 amountWord, address target, bytes memory data, BorrowTestCall memory healthFactor)
        internal
        view
        returns (IMerkleAdapter.Action memory action)
    {
        action = _action(
            address(adapter),
            abi.encodeCall(IBorrowCapability.borrow, (target, healthFactor.target, data, healthFactor.data))
        );
        // Only the nested lending amount is caller-selected.
        for (uint256 i = 168 + amountWord * 32; i < 200 + amountWord * 32; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory action) {
        bytes memory mask = new bytes(data.length);
        return IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        bytes memory maskedData = new bytes(action.data.length);
        for (uint256 i; i < maskedData.length; ++i) {
            maskedData[i] = action.data[i] & ~action.dataMask[i];
        }
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        action.target,
                        bytes1(action.value == 0 ? 0 : 0xff),
                        keccak256(action.dataMask),
                        keccak256(maskedData)
                    )
                )
            )
        );
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _marketId() internal view returns (Id) {
        return Id.wrap(keccak256(abi.encode(market)));
    }
}

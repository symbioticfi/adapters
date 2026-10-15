// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MerkleDeallocationHarness} from "./CREOracleDeallocate.t.sol";
import {CREOracleTestBase} from "./CREOracle.t.sol";

import {
    MerkleAdapterDelegatorMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";
import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";
import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";
import {Token} from "test/mocks/Token.sol";

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {ICREOracle, ORACLE_GUARD_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAaveUsdcDebtPool {
    function ADDRESSES_PROVIDER() external view returns (address);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IAaveUsdcDebtProvider {
    function getPriceOracle() external view returns (address);
}

interface IAaveUsdcDebtOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @dev The swap takes actual WETH and delivers a token whose subsequent loss is priced by the test.
contract WethForRiskAssetSwap {
    address public immutable weth;
    address public immutable riskAsset;

    constructor(address newWeth, address newRiskAsset) {
        weth = newWeth;
        riskAsset = newRiskAsset;
    }

    function swap(uint256 wethAmount, uint256 riskAssetAmount) public {
        IERC20(weth).transferFrom(msg.sender, address(this), wethAmount);
        IERC20(riskAsset).transfer(msg.sender, riskAssetAmount);
    }
}

/// @dev Real mainnet USDC, WETH and Aave V3 pool; simulated WETH and risk-asset price shocks.
contract CREOracleUsdcBaselineProofTest is CREOracleTestBase {
    using Math for uint256;

    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal aaveOracle;
    address internal riskAsset;
    address internal swap;
    uint256 internal usdcPrice;
    uint256 internal wethPrice;
    uint256 internal riskAssetPrice;

    function setUp() public override {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for the Aave mainnet example");
            return;
        }
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        super.setUp();

        // Replace the base fixture with a vault and Merkle adapter whose asset is real USDC.
        MerkleAdapterVaultRegistry vaultFactory = new MerkleAdapterVaultRegistry();
        MerkleAdapterVaultMock vault = new MerkleAdapterVaultMock(USDC);
        delegator = new MerkleAdapterDelegatorMock(address(vault));
        vault.setDelegator(address(delegator));
        vaultFactory.add(address(vault));
        AdapterFactory adapterFactory = new AdapterFactory(address(this));
        adapterFactory.whitelist(
            address(
                new MerkleAdapter(
                    address(vaultFactory),
                    address(adapterFactory),
                    address(factory),
                    createMerkleAccountFactory(
                        address(this),
                        address(adapterFactory),
                        address(new RootRegistry(address(this))),
                        address(new CapabilitiesRegistry(address(this)))
                    )
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapterFactory.create(
                    1, address(this), abi.encode(address(vault), abi.encode(merkleAdapterInitParams(address(this))))
                ))
        );
        account = adapter.account();
        oracle = CREOracle(adapter.oracle());
        _setUpAcceptedWorkflow();
        oracle.grantRole(ORACLE_GUARD_ROLE, address(this));
        aaveOracle = IAaveUsdcDebtProvider(IAaveUsdcDebtPool(POOL).ADDRESSES_PROVIDER()).getPriceOracle();
        usdcPrice = IAaveUsdcDebtOracle(aaveOracle).getAssetPrice(USDC);
        wethPrice = IAaveUsdcDebtOracle(aaveOracle).getAssetPrice(WETH);
        riskAsset = address(new Token("Risk asset"));
        swap = address(new WethForRiskAssetSwap(WETH, riskAsset));
        IERC20(riskAsset).transfer(swap, 210e18);
        riskAssetPrice = 1e6;
    }

    function _setUpReportContext() internal override {}

    function _setUpAcceptedWorkflow() internal override {
        if (address(adapter) != address(0) && MerkleAdapterVaultMock(adapter.vault()).asset() == USDC) {
            super._setUpAcceptedWorkflow();
        }
    }

    function test_FlooredAavePositionKeepsHistoricalBaselineNonnegative() public {
        _deliver(_report(0));
        deal(USDC, adapter.vault(), 1000e6);
        assertEq(delegator.allocate(address(adapter), 1000e6), 1000e6);

        // Only USDC is posted as collateral. The borrowed asset is WETH, never USDC.
        _manage(address(adapter), abi.encodeCall(adapter.push, (300e6)));
        _manage(USDC, abi.encodeCall(IERC20.approve, (POOL, 300e6)));
        _manage(POOL, abi.encodeCall(IAaveUsdcDebtPool.supply, (USDC, 300e6, account, 0)));
        uint256 wethBorrow = (210e6 * usdcPrice / 1e6) * 1e18 / wethPrice;
        _manage(POOL, abi.encodeCall(IAaveUsdcDebtPool.borrow, (WETH, wethBorrow, 2, 0, account)));
        _manage(WETH, abi.encodeCall(IERC20.approve, (swap, wethBorrow)));
        _manage(swap, abi.encodeCall(WethForRiskAssetSwap.swap, (wethBorrow, 210e18)));
        assertEq(IERC20(WETH).balanceOf(account), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 700e6);
        assertApproxEqAbs(_observedReport().totalAssets, 1000e6, 1e6);

        delegator.requestDeallocate(address(adapter), 700e6);
        assertEq(adapter.stagedLiquidity(), 700e6);
        _advanceReport();
        _deliverWithReview(_observedReport());
        assertEq(adapter.releasedLiquidity(), 700e6);

        // Report A covers the completed block with the 700 USDC still staged. Aave's debt
        // is repriced 50% higher while the acquired risk asset loses all value.
        vm.mockCall(
            aaveOracle, abi.encodeCall(IAaveUsdcDebtOracle.getAssetPrice, (WETH)), abi.encode(wethPrice * 3 / 2)
        );
        riskAssetPrice = 0;
        _advanceReport();
        ICREOracle.Report memory delayedLoss = _observedReport();
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 700e6);
        assertEq(delayedLoss.totalAssets, 700e6);
        (,,,,, uint256 underwaterHealth) = IAaveUsdcDebtPool(POOL).getUserAccountData(account);
        assertLt(underwaterHealth, 1e18);

        // The earlier accepted NAV still permits the already released USDC payout.
        address withdrawal = address(new MerkleDeallocationHarness(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(withdrawal);
        assertEq(MerkleDeallocationHarness(withdrawal).execute(address(adapter), 700e6), 700e6);
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(address(delegator));
        assertEq(adapter.netFlow(), 300e6);

        // WETH recovers before the next completed-block snapshot. The risk asset remains worthless.
        vm.clearMockedCalls();
        _advanceReport();
        ICREOracle.Report memory recovery = _observedReport();
        assertApproxEqAbs(recovery.totalAssets, 90e6, 1e6);
        (,,,,, uint256 recoveredHealth) = IAaveUsdcDebtPool(POOL).getUserAccountData(account);
        assertGt(recoveredHealth, 1e18);
        assertEq(adapter.netFlowAt(recovery.snapshotBlock), 300e6);

        // A new allocation makes both delayed reports' current-NAV checks positive.
        assertEq(delegator.allocate(address(adapter), 200e6), 200e6);
        _deliverWithReview(delayedLoss);
        assertGt(adapter.totalAssets(), 0);
        assertGt(int256(recovery.totalAssets) - adapter.netFlowAt(recovery.snapshotBlock) + adapter.netFlow(), 0);

        int256 baseline = int256(oracle.totalAssets()) - adapter.netFlowAt(oracle.snapshotBlock())
            + adapter.netFlowAt(recovery.snapshotBlock);
        assertEq(baseline, 0);
        _deliverWithReview(recovery);
        assertEq(oracle.snapshotBlock(), recovery.snapshotBlock);
        assertApproxEqAbs(adapter.totalAssets(), 290e6, 1e6);
    }

    function test_UsdcProfitWithdrawalMakesNetFlowNegativeButNotTheHistoricalBaseline() public {
        _deliver(_report(0));
        deal(USDC, adapter.vault(), 1000e6);
        assertEq(delegator.allocate(address(adapter), 1000e6), 1000e6);
        _advanceReport();
        _deliverWithReview(_observedReport());

        deal(USDC, address(this), 100e6);
        IERC20(USDC).transfer(address(adapter), 100e6);
        delegator.requestDeallocate(address(adapter), 1100e6);
        _advanceReport();
        ICREOracle.Report memory profit = _observedReport();
        assertEq(profit.totalAssets, 1100e6);
        _deliverWithReview(profit);
        assertEq(adapter.releasedLiquidity(), 1100e6);

        address withdrawal = address(new MerkleDeallocationHarness(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(withdrawal);
        assertEq(MerkleDeallocationHarness(withdrawal).execute(address(adapter), 1100e6), 1100e6);
        assertEq(adapter.netFlow(), -100e6);

        _advanceReport();
        ICREOracle.Report memory empty = _observedReport();
        assertEq(empty.totalAssets, 0);
        int256 baseline = int256(profit.totalAssets) - adapter.netFlowAt(profit.snapshotBlock)
            + adapter.netFlowAt(empty.snapshotBlock);
        assertEq(baseline, 0);
        _deliver(empty);
        assertEq(oracle.snapshotBlock(), empty.snapshotBlock);
    }

    function test_UnderstatedUsdcReportRoutesNegativeHistoricalBaselineToGuard() public {
        _deliver(_report(0));
        deal(USDC, adapter.vault(), 1000e6);
        assertEq(delegator.allocate(address(adapter), 1000e6), 1000e6);
        _advanceReport();
        _deliverWithReview(_report(1000e6));

        delegator.requestDeallocate(address(adapter), 700e6);
        _advanceReport();
        _deliver(_report(1000e6));
        assertEq(adapter.releasedLiquidity(), 700e6);

        _advanceReport();
        ICREOracle.Report memory understated = _report(600e6);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 1000e6);
        assertEq(adapter.netFlowAt(understated.snapshotBlock), 1000e6);

        address withdrawal = address(new MerkleDeallocationHarness(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(withdrawal);
        assertEq(MerkleDeallocationHarness(withdrawal).execute(address(adapter), 700e6), 700e6);
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(address(delegator));
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 300e6);

        _advanceReport();
        ICREOracle.Report memory correct = _report(300e6);
        assertEq(adapter.netFlowAt(correct.snapshotBlock), 300e6);
        assertEq(delegator.allocate(address(adapter), 200e6), 200e6);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 500e6);
        assertEq(adapter.netFlow(), 500e6);

        _deliverWithReview(understated);
        assertEq(oracle.totalAssets(), 600e6);
        assertEq(adapter.totalAssets(), 100e6);
        assertEq(
            int256(oracle.totalAssets()) - adapter.netFlowAt(oracle.snapshotBlock())
                + adapter.netFlowAt(correct.snapshotBlock),
            -100e6
        );
        assertEq(int256(correct.totalAssets) - adapter.netFlowAt(correct.snapshotBlock) + adapter.netFlow(), 500e6);

        bytes memory payload = abi.encode(correct);
        _deliver(correct);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        assertEq(oracle.snapshotBlock(), understated.snapshotBlock);
        assertEq(adapter.totalAssets(), 100e6);

        oracle.acceptReport(payload);
        adapter.syncReport();
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.snapshotBlock(), correct.snapshotBlock);
        assertEq(adapter.totalAssets(), 500e6);
    }

    function _observedReport() internal view returns (ICREOracle.Report memory) {
        (uint256 collateralBase, uint256 debtBase,,,,) = IAaveUsdcDebtPool(POOL).getUserAccountData(account);
        uint256 cash = IERC20(USDC).balanceOf(address(adapter)) + IERC20(USDC).balanceOf(account);
        uint256 riskValue = IERC20(riskAsset).balanceOf(account) * riskAssetPrice / 1e18;
        uint256 position = (collateralBase * 1e6 / usdcPrice).saturatingSub(debtBase * 1e6 / usdcPrice);
        return _report(cash + riskValue + position);
    }

    function _manage(address target, bytes memory data) internal {
        bytes memory mask = new bytes(data.length);
        bytes32 leaf = ActionMasker.mask(target, 0, data, mask);
        RootRegistry(MerkleAccount(payable(account)).ROOT_REGISTRY()).setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] =
            IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
        MerkleAccount(payable(account)).manage(actions);
    }
}

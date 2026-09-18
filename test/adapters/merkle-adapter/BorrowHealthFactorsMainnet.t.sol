// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BorrowCapability} from "src/contracts/merkle_adapter/BorrowCapability.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {EulerHealthFactor} from "src/contracts/merkle_adapter/borrow_capability/EulerHealthFactor.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MorphoBlueHealthFactor} from "src/contracts/merkle_adapter/borrow_capability/MorphoBlueHealthFactor.sol";
import {
    MorphoMidnightHealthFactor
} from "src/contracts/merkle_adapter/borrow_capability/MorphoMidnightHealthFactor.sol";

import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {IEulerHealthVault} from "src/interfaces/merkle_adapter/borrow_capability/IEulerHealthVault.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMorphoMidnight} from "src/interfaces/merkle_adapter/borrow_capability/IMorphoMidnight.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {
    Id,
    IMorpho as IMorphoBlue,
    IMorphoBase as IHealthTestBlue,
    MarketParams
} from "morpho-blue/src/interfaces/IMorpho.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/BorrowCapabilityMocks.sol";

interface IHealthTestEvc {
    function enableCollateral(address account, address vault) external;
    function enableController(address account, address vault) external;
}

interface IHealthTestEuler is IEulerHealthVault {
    function borrow(uint256 amount, address receiver) external returns (uint256);
    function debtOf(address account) external view returns (uint256);
}

interface IHealthTestMidnight is IMorphoMidnight {
    struct Offer {
        Market market;
        bool buy;
        address maker;
        uint256 start;
        uint256 expiry;
        uint256 tick;
        bytes32 group;
        address callback;
        bytes callbackData;
        address receiverIfMakerIsSeller;
        address ratifier;
        bool reduceOnly;
        uint128 maxUnits;
        uint128 maxAssets;
        uint256 continuousFeeCap;
    }
    function touchMarket(Market memory market) external returns (bytes32);
    function supplyCollateral(Market memory market, uint256 index, uint256 amount, address account) external;
    function setIsAuthorized(address authorized, bool allowed, address account) external;
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiver,
        address callback,
        bytes memory callbackData
    ) external returns (uint256, uint256);
    function isHealthy(Market memory market, bytes32 id, address account) external view returns (bool);
}

/// @dev Deterministic WETH/USDC price fixture. Borrowing and position accounting use deployed protocols.
contract HealthTestMorphoOracle {
    function price() external pure returns (uint256) {
        return 2000e24;
    }
}

/// @dev Initial token funding, the Morpho price, and Midnight offer authorization are local fixtures.
///      Protocol custody, interest, debt and collateral accounting execute against mainnet contracts.
contract BorrowHealthFactorsMainnetTest is CapabilityTestBase {
    uint256 internal constant FORK_BLOCK = 25_892_000;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // https://docs.morpho.org/developers/contracts/addresses/
    address internal constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address internal constant MIDNIGHT = 0x471686c42792F93528B000beF54bC10E3aa2045f;
    // euler-xyz/evk-periphery@816c5943, script/production/mainnet/clusters/PrimeCluster.json
    address internal constant EULER_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address internal constant EULER_WETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    // https://github.com/euler-xyz/euler-interfaces/blob/master/addresses/1/CoreAddresses.json
    address internal constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    address internal implementation;
    address internal helper;
    bytes internal borrowData;
    address internal borrowTarget;
    BorrowTestCall internal health;
    MarketParams internal blueParams;
    IMorphoMidnight.Market internal midnightMarket;
    bytes32 internal marketId;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for health helper mainnet integration");
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        _deployAdapter(USDC);
        deal(WETH, address(adapter), 10e18);
    }

    function test_MainnetBlueBorrowAndPendingInterest() public {
        _setupBlue();
        _borrow();
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 1000e6);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 17.2e18);
        vm.warp(block.timestamp + 30 days);
        uint256 preview = MorphoBlueHealthFactor(helper).getHealthFactor(BLUE, marketId, address(adapter));
        assertLt(preview, 17.2e18);
        IHealthTestBlue(BLUE).accrueInterest(blueParams);
        assertEq(MorphoBlueHealthFactor(helper).getHealthFactor(BLUE, marketId, address(adapter)), preview);
    }

    function test_MainnetBlueFloorRevertsDebtAndTransfer() public {
        _setupBlue();
        uint256 reserve = IERC20(USDC).balanceOf(BLUE);
        _rejectBorrow();
        assertEq(IMorphoBlue(BLUE).position(Id.wrap(marketId), address(adapter)).borrowShares, 0);
        assertEq(IERC20(USDC).balanceOf(BLUE), reserve);
    }

    function test_MainnetEulerBorrowThroughEvc() public {
        _setupEuler();
        _borrow();
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 1000e6);
        assertGe(IHealthTestEuler(EULER_USDC).debtOf(address(adapter)), 1000e6);
        (uint256 collateral, uint256 liability) = IHealthTestEuler(EULER_USDC).accountLiquidity(address(adapter), true);
        assertEq(
            BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data),
            collateral * 1e18 / liability
        );
        uint256 debt = IHealthTestEuler(EULER_USDC).debtOf(address(adapter));
        vm.warp(block.timestamp + 1 minutes);
        assertGt(IHealthTestEuler(EULER_USDC).debtOf(address(adapter)), debt);
        (collateral, liability) = IHealthTestEuler(EULER_USDC).accountLiquidity(address(adapter), true);
        assertEq(
            BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data),
            collateral * 1e18 / liability
        );
    }

    function test_MainnetEulerFloorRevertsDebtAndTransfer() public {
        _setupEuler();
        uint256 reserve = IERC20(USDC).balanceOf(EULER_USDC);
        _rejectBorrow();
        assertEq(IHealthTestEuler(EULER_USDC).debtOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(EULER_USDC), reserve);
    }

    function test_MainnetMidnightBorrowAndMaturity() public {
        _setupMidnight();
        _borrow();
        assertGt(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IMorphoMidnight(MIDNIGHT).debt(marketId, address(adapter)), 1000e6);
        assertTrue(IHealthTestMidnight(MIDNIGHT).isHealthy(midnightMarket, marketId, address(adapter)));
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 17.2e18);
        vm.warp(midnightMarket.maturity + 1);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 0);
    }

    function test_MainnetMidnightFloorRevertsDebtAndTransfer() public {
        _setupMidnight();
        uint256 lenderBalance = IERC20(USDC).balanceOf(address(this));
        _rejectBorrow();
        assertEq(IMorphoMidnight(MIDNIGHT).debt(marketId, address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(this)), lenderBalance);
    }

    function isRatified(IHealthTestMidnight.Offer memory offer, bytes memory, address) external view returns (bytes32) {
        require(msg.sender == MIDNIGHT && offer.maker == address(this));
        return keccak256("morpho.midnight.callbackSuccess");
    }

    function _setupBlue() internal {
        blueParams = MarketParams(USDC, WETH, address(new HealthTestMorphoOracle()), IRM, 0.86e18);
        marketId = keccak256(abi.encode(blueParams));
        IHealthTestBlue(BLUE).createMarket(blueParams);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(BLUE, 100_000e6);
        IHealthTestBlue(BLUE).supply(blueParams, 100_000e6, 0, address(this), "");
        _manage(WETH, abi.encodeCall(IERC20.approve, (BLUE, 10e18)));
        _manage(BLUE, abi.encodeCall(IHealthTestBlue.supplyCollateral, (blueParams, 10e18, address(adapter), "")));
        helper = address(new MorphoBlueHealthFactor());
        borrowData = abi.encodeCall(
            IHealthTestBlue.borrow, (blueParams, uint256(1000e6), 0, address(adapter), address(adapter))
        );
        _installBorrow(BLUE, abi.encodeCall(MorphoBlueHealthFactor.getHealthFactor, (BLUE, marketId, address(adapter))));
    }

    function _setupEuler() internal {
        assertEq(IERC4626(EULER_WETH).asset(), WETH);
        assertEq(IERC4626(EULER_USDC).asset(), USDC);
        _manage(WETH, abi.encodeCall(IERC20.approve, (EULER_WETH, 10e18)));
        _manage(EULER_WETH, abi.encodeCall(IERC4626.deposit, (10e18, address(adapter))));
        _manage(EVC, abi.encodeCall(IHealthTestEvc.enableCollateral, (address(adapter), EULER_WETH)));
        _manage(EVC, abi.encodeCall(IHealthTestEvc.enableController, (address(adapter), EULER_USDC)));
        helper = address(new EulerHealthFactor());
        borrowData = abi.encodeCall(IHealthTestEuler.borrow, (uint256(1000e6), address(adapter)));
        _installBorrow(EULER_USDC, abi.encodeCall(EulerHealthFactor.getHealthFactor, (EULER_USDC, address(adapter))));
    }

    function _setupMidnight() internal {
        midnightMarket.chainId = block.chainid;
        midnightMarket.midnight = MIDNIGHT;
        midnightMarket.loanToken = USDC;
        midnightMarket.maturity = block.timestamp + 30 days;
        midnightMarket.rcfThreshold = 1e18;
        midnightMarket.collateralParams
            .push(IMorphoMidnight.CollateralParams(WETH, 0.86e18, 0.3e18, address(new HealthTestMorphoOracle())));
        marketId = IHealthTestMidnight(MIDNIGHT).touchMarket(midnightMarket);
        _manage(WETH, abi.encodeCall(IERC20.approve, (MIDNIGHT, 10e18)));
        _manage(
            MIDNIGHT, abi.encodeCall(IHealthTestMidnight.supplyCollateral, (midnightMarket, 0, 10e18, address(adapter)))
        );
        deal(USDC, address(this), 1000e6);
        IERC20(USDC).approve(MIDNIGHT, 1000e6);
        IHealthTestMidnight(MIDNIGHT).setIsAuthorized(address(this), true, address(this));
        IHealthTestMidnight.Offer memory offer;
        offer.market = midnightMarket;
        offer.buy = true;
        offer.maker = address(this);
        offer.expiry = midnightMarket.maturity;
        offer.tick = 4000;
        offer.ratifier = address(this);
        offer.maxUnits = 1000e6;
        offer.continuousFeeCap = type(uint256).max;
        borrowData = abi.encodeCall(
            IHealthTestMidnight.take, (offer, "", uint256(1000e6), address(adapter), address(adapter), address(0), "")
        );
        helper = address(new MorphoMidnightHealthFactor());
        _installBorrow(
            MIDNIGHT, abi.encodeCall(MorphoMidnightHealthFactor.getHealthFactor, (MIDNIGHT, marketId, address(adapter)))
        );
    }

    function _installBorrow(address target, bytes memory query) internal {
        implementation =
            IImmutableFactory(address(new ImmutableFactory(type(BorrowCapability).creationCode))).create("");
        borrowTarget = target;
        health = BorrowTestCall(helper, query);
        _installCapability(adapter, implementation, _borrowSelectors());
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 1.2e18);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), type(uint256).max);
    }

    function _borrow() internal {
        _manage(
            address(adapter),
            abi.encodeCall(IBorrowCapability.borrow, (borrowTarget, health.target, borrowData, health.data))
        );
        assertEq(IERC20(USDC).balanceOf(implementation), 0);
        assertEq(IERC20(USDC).balanceOf(helper), 0);
        assertGe(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), 1.2e18);
    }

    function _rejectBorrow() internal {
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), type(uint256).max);
        IMerkleAdapter.Action[] memory actions = _publishCall(
            address(adapter),
            abi.encodeCall(IBorrowCapability.borrow, (borrowTarget, health.target, borrowData, health.data))
        );
        vm.expectRevert(IBorrowCapability.HealthFactorTooLow.selector);
        adapter.manage(actions);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(health.target, health.data), type(uint256).max);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {EulerHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/EulerHealthFactor.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {
    MorphoBlueHealthFactor
} from "src/contracts/merkle-adapter/automations/health-factors/MorphoBlueHealthFactor.sol";
import {
    MorphoMidnightHealthFactor
} from "src/contracts/merkle-adapter/automations/health-factors/MorphoMidnightHealthFactor.sol";

import {IEulerHealthVault} from "src/interfaces/merkle-adapter/automations/health-factors/IEulerHealthVault.sol";
import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMorphoMidnight} from "src/interfaces/merkle-adapter/automations/health-factors/IMorphoMidnight.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {
    Id,
    IMorpho as IMorphoBlue,
    IMorphoBase as IHealthTestBlue,
    MarketParams
} from "morpho-blue/src/interfaces/IMorpho.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/GuardedCallsMocks.sol";

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
        vm.createSelectFork(rpc, vm.envOr("MAINNET_FORK_BLOCK", FORK_BLOCK));
        _deployAdapter(USDC);
        deal(WETH, account, 10e18);
    }

    function test_MainnetBlueBorrowAndPendingInterest() public {
        _setupBlue();
        _borrow();
        assertEq(IERC20(USDC).balanceOf(account), 1000e6);
        assertEq(_healthValue(health.target, health.data), 17.2e18);
        vm.warp(block.timestamp + 30 days);
        uint256 preview = MorphoBlueHealthFactor(helper).getHealthFactor(BLUE, marketId, account);
        assertLt(preview, 17.2e18);
        IHealthTestBlue(BLUE).accrueInterest(blueParams);
        assertEq(MorphoBlueHealthFactor(helper).getHealthFactor(BLUE, marketId, account), preview);
    }

    function test_MainnetBlueFloorRevertsDebtAndTransfer() public {
        _setupBlue();
        uint256 reserve = IERC20(USDC).balanceOf(BLUE);
        _rejectBorrow();
        assertEq(IMorphoBlue(BLUE).position(Id.wrap(marketId), account).borrowShares, 0);
        assertEq(IERC20(USDC).balanceOf(BLUE), reserve);
    }

    function test_MainnetEulerBorrowThroughEvc() public {
        _setupEuler();
        _borrow();
        assertEq(IERC20(USDC).balanceOf(account), 1000e6);
        assertGe(IHealthTestEuler(EULER_USDC).debtOf(account), 1000e6);
        (uint256 collateral, uint256 liability) = IHealthTestEuler(EULER_USDC).accountLiquidity(account, true);
        assertEq(_healthValue(health.target, health.data), collateral * 1e18 / liability);
        uint256 debt = IHealthTestEuler(EULER_USDC).debtOf(account);
        vm.warp(block.timestamp + 1 minutes);
        assertGt(IHealthTestEuler(EULER_USDC).debtOf(account), debt);
        (collateral, liability) = IHealthTestEuler(EULER_USDC).accountLiquidity(account, true);
        assertEq(_healthValue(health.target, health.data), collateral * 1e18 / liability);
    }

    function test_MainnetEulerFloorRevertsDebtAndTransfer() public {
        _setupEuler();
        uint256 reserve = IERC20(USDC).balanceOf(EULER_USDC);
        _rejectBorrow();
        assertEq(IHealthTestEuler(EULER_USDC).debtOf(account), 0);
        assertEq(IERC20(USDC).balanceOf(EULER_USDC), reserve);
    }

    function test_MainnetMidnightBorrowAndMaturity() public {
        _setupMidnight();
        _borrow();
        assertGt(IERC20(USDC).balanceOf(account), 0);
        assertEq(IMorphoMidnight(MIDNIGHT).debt(marketId, account), 1000e6);
        assertTrue(IHealthTestMidnight(MIDNIGHT).isHealthy(midnightMarket, marketId, account));
        assertEq(_healthValue(health.target, health.data), 17.2e18);
        vm.warp(midnightMarket.maturity + 1);
        assertEq(_healthValue(health.target, health.data), 0);
    }

    function test_MainnetMidnightFloorRevertsDebtAndTransfer() public {
        _setupMidnight();
        uint256 lenderBalance = IERC20(USDC).balanceOf(address(this));
        _rejectBorrow();
        assertEq(IMorphoMidnight(MIDNIGHT).debt(marketId, account), 0);
        assertEq(IERC20(USDC).balanceOf(address(this)), lenderBalance);
    }

    function isRatified(IHealthTestMidnight.Offer memory offer, bytes memory, address) external view returns (bytes32) {
        require(msg.sender == MIDNIGHT && offer.maker == address(this));
        return keccak256("morpho.midnight.callbackSuccess");
    }

    function _setupBlue() internal {
        blueParams = MarketParams({
            loanToken: USDC,
            collateralToken: WETH,
            oracle: address(new HealthTestMorphoOracle()),
            irm: IRM,
            lltv: 0.86e18
        });
        marketId = keccak256(abi.encode(blueParams));
        IHealthTestBlue(BLUE).createMarket(blueParams);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(BLUE, 100_000e6);
        IHealthTestBlue(BLUE).supply(blueParams, 100_000e6, 0, address(this), "");
        _manage(WETH, abi.encodeCall(IERC20.approve, (BLUE, 10e18)));
        _manage(BLUE, abi.encodeCall(IHealthTestBlue.supplyCollateral, (blueParams, 10e18, account, "")));
        helper = address(new MorphoBlueHealthFactor());
        borrowData = abi.encodeCall(IHealthTestBlue.borrow, (blueParams, uint256(1000e6), 0, account, account));
        _installBorrow(BLUE, abi.encodeCall(MorphoBlueHealthFactor.getHealthFactor, (BLUE, marketId, account)));
    }

    function _setupEuler() internal {
        assertEq(IERC4626(EULER_WETH).asset(), WETH);
        assertEq(IERC4626(EULER_USDC).asset(), USDC);
        _manage(WETH, abi.encodeCall(IERC20.approve, (EULER_WETH, 10e18)));
        _manage(EULER_WETH, abi.encodeCall(IERC4626.deposit, (10e18, account)));
        _manage(EVC, abi.encodeCall(IHealthTestEvc.enableCollateral, (account, EULER_WETH)));
        _manage(EVC, abi.encodeCall(IHealthTestEvc.enableController, (account, EULER_USDC)));
        helper = address(new EulerHealthFactor());
        borrowData = abi.encodeCall(IHealthTestEuler.borrow, (uint256(1000e6), account));
        _installBorrow(EULER_USDC, abi.encodeCall(EulerHealthFactor.getHealthFactor, (EULER_USDC, account)));
    }

    function _setupMidnight() internal {
        midnightMarket.chainId = block.chainid;
        midnightMarket.midnight = MIDNIGHT;
        midnightMarket.loanToken = USDC;
        midnightMarket.maturity = block.timestamp + 30 days;
        midnightMarket.rcfThreshold = 1e18;
        midnightMarket.collateralParams
            .push(
                IMorphoMidnight.CollateralParams({
                    token: WETH, lltv: 0.86e18, liquidationCursor: 0.3e18, oracle: address(new HealthTestMorphoOracle())
                })
            );
        marketId = IHealthTestMidnight(MIDNIGHT).touchMarket(midnightMarket);
        _manage(WETH, abi.encodeCall(IERC20.approve, (MIDNIGHT, 10e18)));
        _manage(MIDNIGHT, abi.encodeCall(IHealthTestMidnight.supplyCollateral, (midnightMarket, 0, 10e18, account)));
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
        borrowData =
            abi.encodeCall(IHealthTestMidnight.take, (offer, "", uint256(1000e6), account, account, address(0), ""));
        helper = address(new MorphoMidnightHealthFactor());
        _installBorrow(
            MIDNIGHT, abi.encodeCall(MorphoMidnightHealthFactor.getHealthFactor, (MIDNIGHT, marketId, account))
        );
    }

    function _installBorrow(address target, bytes memory query) internal {
        implementation =
            IImmutableFactory(address(new ImmutableFactory(type(GuardedCallsCapability).creationCode))).create("");
        borrowTarget = target;
        health = BorrowTestCall({target: helper, data: query});
        _installCapability(adapter, implementation, _guardedSelectors());
        _minimum = 1.2e18;
        assertEq(_healthValue(health.target, health.data), type(uint256).max);
    }

    function _borrow() internal {
        _manage(account, _guardedData(borrowTarget, health.target, borrowData, health.data));
        assertEq(IERC20(USDC).balanceOf(implementation), 0);
        assertEq(IERC20(USDC).balanceOf(helper), 0);
        assertGe(_healthValue(health.target, health.data), 1.2e18);
    }

    function _rejectBorrow() internal {
        _minimum = type(uint256).max;
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, _guardedData(borrowTarget, health.target, borrowData, health.data));
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(IERC20(USDC).balanceOf(account), 0);
        assertEq(_healthValue(health.target, health.data), type(uint256).max);
    }
}

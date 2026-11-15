// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams, Market, Position, Id} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "morpho-blue/src/libraries/SharesMathLib.sol";
import {IIrm} from "morpho-blue/src/interfaces/IIrm.sol";

contract MorphoBlueLiquidityTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    address internal constant BLUE = address(0xB10E);
    address internal constant ACCOUNT = address(0xACC);
    MorphoLiquidity internal helper;
    MarketParams internal params;

    function setUp() public {
        vm.warp(10 days);
        helper = new MorphoLiquidity();
        params = MarketParams(address(0xA55E7), address(0xC011), address(0x0123), address(0x1212), 0.86e18);
    }

    function _state(uint256 shares, uint128 supply, uint128 borrowed, uint256 cash, uint128 fee) internal {
        vm.mockCall(BLUE, abi.encodeCall(IMorpho.position, (params.id(), ACCOUNT)), abi.encode(Position(shares, 0, 0)));
        Market memory market =
            Market(supply, uint128(uint256(supply) * 1e6), borrowed, borrowed, uint128(block.timestamp - 1 days), fee);
        vm.mockCall(BLUE, abi.encodeCall(IMorpho.market, (params.id())), abi.encode(market));
        vm.mockCall(params.irm, abi.encodeCall(IIrm.borrowRateView, (params, market)), abi.encode(uint256(1e10)));
        vm.mockCall(params.loanToken, abi.encodeCall(IERC20.balanceOf, (BLUE)), abi.encode(cash));
    }

    function test_ZeroPositionDoesNotReadMarketOrCash() public {
        vm.mockCall(BLUE, abi.encodeCall(IMorpho.position, (params.id(), ACCOUNT)), abi.encode(Position(0, 0, 0)));
        vm.mockCallRevert(BLUE, abi.encodeCall(IMorpho.market, (params.id())), "unused market");
        assertEq(helper.liquidity(BLUE, params, ACCOUNT), 0);
    }

    function test_ReadsMarketOnceAndUsesExplicitAccount() public {
        _state(100e12, 1000e6, 600e6, 400e6, 0);
        vm.expectCall(BLUE, abi.encodeCall(IMorpho.position, (params.id(), ACCOUNT)), 1);
        vm.expectCall(BLUE, abi.encodeCall(IMorpho.market, (params.id())), 1);
        assertGt(helper.liquidity(BLUE, params, ACCOUNT), 100e6);
    }

    function test_CapsAtMarketLiquidity() public {
        _state(1000e12, 1000e6, 999e6, 500e6, 0);
        assertEq(helper.liquidity(BLUE, params, ACCOUNT), 1e6);
    }

    function test_CapsAtActualTokenCash() public {
        _state(1000e12, 1000e6, 600e6, 7e6, 0);
        assertEq(helper.liquidity(BLUE, params, ACCOUNT), 7e6);
    }

    function test_NoMarketLiquidity() public {
        _state(1000e12, 1000e6, 1000e6, 500e6, 0);
        assertEq(helper.liquidity(BLUE, params, ACCOUNT), 0);
    }

    function test_FailedReadReverts() public {
        _state(1000e12, 1000e6, 600e6, 400e6, 0);
        vm.mockCallRevert(params.loanToken, abi.encodeCall(IERC20.balanceOf, (BLUE)), "unavailable cash");
        vm.expectRevert("unavailable cash");
        helper.liquidity(BLUE, params, ACCOUNT);
    }

    function testFuzz_MatchesUpstreamAccrualRoundingAndBounds(
        uint128 supplySeed,
        uint128 borrowSeed,
        uint128 shareSeed,
        uint128 cashSeed,
        uint64 feeSeed
    ) public {
        uint128 supply = uint128(bound(supplySeed, 1, 1e24));
        uint128 borrowed = uint128(bound(borrowSeed, 0, supply));
        uint256 shares = bound(shareSeed, 0, uint256(supply) * 1e6);
        uint256 cash = bound(cashSeed, 0, supply);
        _state(shares, supply, borrowed, cash, uint128(bound(feeSeed, 0, 1e18)));
        (uint256 assets, uint256 totalShares, uint256 debt,) = IMorpho(BLUE).expectedMarketBalances(params);
        uint256 expected = shares.toAssetsDown(assets, totalShares);
        expected = expected < assets - debt ? expected : assets - debt;
        expected = expected < cash ? expected : cash;
        assertEq(helper.liquidity(BLUE, params, ACCOUNT), expected);
    }
}

contract MorphoBlueLiquidityMainnetTest is Test {
    using MarketParamsLib for MarketParams;

    function test_MainnetExistingVaultCapacityMatchesOldHelperAndWithdraws() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("MORPHO_FORK_BLOCK", uint256(26_418_208)));
        address account = 0xDDaab343f8317cbFed6797D29Dec953444716d51;
        address vault = 0x355A1c6A3f1946d4DbD7cE932492925AB9F261a7;
        MorphoLiquidity helper = new MorphoLiquidity();
        uint256 capacity = helper.liquidity(vault, account);
        assertGt(capacity, 0);
        assertEq(capacity, MorphoLiquidity(0xdF417AeC7db5d2A1A2AdCFcc73E058aC1835608f).liquidity(vault, account));
        IERC4626 source = IERC4626(vault);
        IERC20 asset = IERC20(source.asset());
        uint256 beforeBalance = asset.balanceOf(account);
        vm.prank(account);
        source.withdraw(capacity, account, account);
        assertEq(asset.balanceOf(account) - beforeBalance, capacity);
    }

    function test_MainnetAccruedSupplyCanBeWithdrawn() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 26_355_543);
        IMorpho morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
        MarketParams memory params =
            morpho.idToMarketParams(Id.wrap(0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64));
        MorphoLiquidity helper = new MorphoLiquidity();
        deal(params.loanToken, address(this), 1000e6);
        IERC20(params.loanToken).approve(address(morpho), 1000e6);
        morpho.supply(params, 1000e6, 0, address(this), "");
        vm.warp(block.timestamp + 1 days);
        uint256 capacity = helper.liquidity(address(morpho), params, address(this));
        assertGe(capacity, 1000e6 - 1);
        (uint256 received,) = morpho.withdraw(params, capacity, 0, address(this), address(this));
        assertEq(received, capacity);
        assertEq(IERC20(params.loanToken).balanceOf(address(this)), capacity);
        assertLe(helper.liquidity(address(morpho), params, address(this)), 1);
    }
}

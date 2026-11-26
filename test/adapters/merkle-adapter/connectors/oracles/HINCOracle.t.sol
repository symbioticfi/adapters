// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HINC_Oracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/tokens/HINC_Oracle.sol";
import {
    IAggregatorV3
} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/libraries/ChainlinkPriceFeed.sol";
import {IOracle} from "../../../../../src/interfaces/ll-adapter/IOracle.sol";
import {Test} from "forge-std/Test.sol";

contract HINCOracleTest is Test {
    HINC_Oracle internal oracle;

    function setUp() public {
        vm.warp(7 days);
        oracle = new HINC_Oracle();
        vm.mockCall(oracle.NAV_FEED(), abi.encodeCall(IAggregatorV3.decimals, ()), abi.encode(uint8(8)));
    }

    function testScalesIssuerNAV() public {
        _round(97_402_372_100, block.timestamp - 48 hours, 1);
        assertEq(oracle.getPrice(), 974.023_721 ether);
    }

    function testRejectsStaleNAV() public {
        _round(97_402_372_100, block.timestamp - 48 hours - 1, 1);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testRejectsWrongFeedPrecision() public {
        _round(97_402_372_100, block.timestamp, 1);
        vm.mockCall(oracle.NAV_FEED(), abi.encodeCall(IAggregatorV3.decimals, ()), abi.encode(uint8(18)));
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testRejectsUnansweredRound() public {
        _round(97_402_372_100, block.timestamp, 0);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testRejectsOutOfRangeNAV() public {
        _round(1, block.timestamp, 1);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function _round(int256 answer, uint256 updatedAt, uint80 answeredInRound) private {
        vm.mockCall(
            oracle.NAV_FEED(),
            abi.encodeCall(IAggregatorV3.latestRoundData, ()),
            abi.encode(uint80(1), answer, updatedAt, updatedAt, answeredInRound)
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LiquidLaneAction} from "src/contracts/merkle_adapter/LiquidLaneAction.sol";
import {IOracle} from "src/interfaces/ll-adapter/IOracle.sol";

/// @dev Deployment-style override: every binding is a constructor immutable, shared by all proxies.
contract FixedOracleLiquidLaneAction is LiquidLaneAction {
    address internal immutable _token;
    address internal immutable _oracle;

    constructor(address factory, address asset, address token, address oracle_) LiquidLaneAction(factory, asset) {
        _token = token;
        _oracle = oracle_;
    }

    function oracle(address token) public view virtual override returns (address) {
        return token == _token ? _oracle : address(0);
    }
}

contract TwoAssetLiquidLaneAction is FixedOracleLiquidLaneAction {
    address private immutable _secondToken;
    address private immutable _secondOracle;

    constructor(
        address factory,
        address asset,
        address token,
        address oracle_,
        address secondToken,
        address secondOracle
    ) FixedOracleLiquidLaneAction(factory, asset, token, oracle_) {
        _secondToken = secondToken;
        _secondOracle = secondOracle;
    }

    function oracle(address token) public view override returns (address) {
        return token == _secondToken ? _secondOracle : super.oracle(token);
    }
}

contract ActionOracleMock is IOracle {
    uint256 public immutable price;
    bool public revertGetPrice;

    constructor(uint256 price_) {
        price = price_;
    }

    function getPrice() external view returns (uint256) {
        if (revertGetPrice) {
            revert("oracle failure");
        }
        return price;
    }

    function setRevertGetPrice(bool status) external {
        revertGetPrice = status;
    }
}

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IAdapter} from "../../interfaces/IAdapter.sol";
import {ILiquidLaneAction} from "../../interfaces/merkle_adapter/ILiquidLaneAction.sol";
import {IOracleRegistry} from "../../interfaces/merkle_adapter/IOracleRegistry.sol";
import {IOracle} from "../../interfaces/ll-adapter/IOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneAction
/// @notice Adapter-bound configuration and pricing action for RWA inventory swaps.
contract LiquidLaneAction is MigratableEntity, ILiquidLaneAction {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @inheritdoc ILiquidLaneAction
    address public adapter;

    /// @inheritdoc ILiquidLaneAction
    address public immutable ORACLE_REGISTRY;

    /// @inheritdoc ILiquidLaneAction
    address[] public tokensToRedeem;

    /// @inheritdoc ILiquidLaneAction
    mapping(address tokenToRedeem => address oracle) public oracles;

    /// @dev Tracks whether an RWA token is configured.
    mapping(address tokenToRedeem => bool exists) internal _isTokenToRedeem;

    /// @inheritdoc ILiquidLaneAction
    address public inputAsset;

    /// @dev Restricts a function to the bound adapter.
    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert InvalidCaller();
        }
        _;
    }

    /// @dev Initializes the immutable factory and oracle registry dependencies.
    constructor(address factory, address oracleRegistry) MigratableEntity(factory) {
        ORACLE_REGISTRY = oracleRegistry;
    }

    /// @inheritdoc ILiquidLaneAction
    function getTokensToRedeemLength() public view returns (uint256) {
        return tokensToRedeem.length;
    }

    /// @inheritdoc ILiquidLaneAction
    function getAmountOut(address tokenToRedeem, uint256 amountIn) public view returns (uint256) {
        return amountIn.mulDiv(
            IOracle(oracles[tokenToRedeem]).getPrice() * 10 ** IERC20Metadata(inputAsset).decimals(),
            1e18 * 10 ** IERC20Metadata(tokenToRedeem).decimals()
        );
    }

    /// @inheritdoc ILiquidLaneAction
    function swap(Swap calldata swap_) public onlyAdapter {
        if (!_isTokenToRedeem[swap_.tokenIn]) {
            revert InvalidTokenToRedeem();
        }
        if (swap_.amountIn > IERC20(swap_.tokenIn).balanceOf(address(this))) {
            revert InsufficientRwaBalance();
        }
        if (swap_.amountOut > getAmountOut(swap_.tokenIn, swap_.amountIn)) {
            revert InvalidSwapRate();
        }

        IERC20(swap_.tokenIn).safeTransfer(adapter, swap_.amountIn);
        IERC20(inputAsset).safeTransferFrom(msg.sender, swap_.recipient, swap_.amountOut);

        emit DoSwap(swap_);
    }

    /// @dev Binds the action proxy to its adapter and immutable asset configuration.
    function _initialize(uint64, address, bytes memory data) internal override {
        (address adapter_, address inputAsset_, address[] memory tokensToRedeem_) =
            abi.decode(data, (address, address, address[]));
        if (adapter_ == address(0)) {
            revert InvalidAdapter();
        }
        if (inputAsset_ == address(0)) {
            revert InvalidInputAsset();
        }
        if (tokensToRedeem_.length == 0) {
            revert EmptyTokensToRedeem();
        }

        adapter = adapter_;
        inputAsset = inputAsset_;

        for (uint256 i; i < tokensToRedeem_.length; ++i) {
            address tokenToRedeem = tokensToRedeem_[i];
            if (tokenToRedeem == address(0) || tokenToRedeem == inputAsset_ || _isTokenToRedeem[tokenToRedeem]) {
                revert InvalidTokenToRedeem();
            }

            address oracleFactory = IOracleRegistry(ORACLE_REGISTRY).oracleFactories(inputAsset_, tokenToRedeem);
            if (oracleFactory == address(0)) {
                revert InvalidOracleFactory();
            }
            address oracle = IMigratablesFactory(oracleFactory)
                .create(
                    IMigratablesFactory(oracleFactory).lastVersion(), owner(), abi.encode(inputAsset_, address(this))
                );

            oracles[tokenToRedeem] = oracle;
            _isTokenToRedeem[tokenToRedeem] = true;
            tokensToRedeem.push(tokenToRedeem);
        }
    }

    /// @dev Allows state-preserving implementation upgrades without reconfiguration.
    function _migrate(uint64, uint64, bytes calldata data) internal override {
        if (data.length != 0) {
            revert InvalidMigrationData();
        }
        if (inputAsset == address(0)) {
            inputAsset = IERC4626(IAdapter(adapter).vault()).asset();
        }
    }
}
